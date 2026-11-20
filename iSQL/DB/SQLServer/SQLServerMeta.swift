import Foundation

/// SQL Server 메타데이터 읽기: 데이터베이스마다 [DB].sys.* 카탈로그 뷰. 시스템 DB(master · tempdb · model · msdb)와 들어갈 수 없는 DB 는 뺀다.
/// 테이블 이름은 dbo 면 이름만, 다른 스키마면 "스키마.이름" (SQLServerDialect.split · displayName)
struct SQLServerMeta: SQLMeta {
	var dialect: SQLServerDialect { SQLServerDialect() }
	var systemSchemas: Set<String> { [] }

	private func lit(_ s: String) -> String { dialect.literal(.text(s)) }
	private func one(_ run: DBRun, _ sql: String) async throws -> QueryResult { try await run(sql).last(where: \.isResultSet) ?? QueryResult() }
	private func q(_ s: String) -> String { dialect.quote(s) }
	/// [DB].sys.
	private func sys(_ db: String) -> String { q(db) + ".sys." }
	/// 앱 이름 → OBJECT_ID 식 (DB 를 붙여서)
	private func objectID(_ db: String, _ name: String) -> String { "OBJECT_ID(\(lit(dialect.quote(schema: db, table: name))))" }

	private let userDatabases = "SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1"

	/// 컬럼 쿼리 (스키마, 테이블, 컬럼, 형식, max_length, precision, scale, nullable, identity, 기본값, 설명, 기본 키, 계산식, 콜레이션)
	private func columnsSQL(_ db: String, _ where: String) -> String {
		let s = sys(db)
		return """
		SELECT sc.name, o.name, c.name, t.name, c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity,
		       dc.definition, CAST(ep.value AS NVARCHAR(4000)),
		       CASE WHEN EXISTS (SELECT 1 FROM \(s)indexes i JOIN \(s)index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
		                         WHERE i.object_id = o.object_id AND i.is_primary_key = 1 AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
		       cc.definition, c.collation_name
		FROM \(s)columns c
		JOIN \(s)objects o ON o.object_id = c.object_id
		JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
		JOIN \(s)types t ON t.user_type_id = c.user_type_id
		LEFT JOIN \(s)default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
		LEFT JOIN \(s)computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
		LEFT JOIN \(s)extended_properties ep ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.name = 'MS_Description'
		WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0 AND \(`where`)
		ORDER BY sc.name, o.name, c.column_id
		"""
	}

	/// 형식 글자 (nvarchar(50) · varchar(max) · decimal(10,2) · datetime2(3) …). nchar·nvarchar 의 max_length 는 바이트라 2로 나눈다
	static func typeString(_ t: String, maxLength: Int?, precision: Int?, scale: Int?) -> String {
		let n = t.lowercased()
		switch n {
		case "varchar", "char", "varbinary", "binary":
			guard let m = maxLength else { return n }
			return m == -1 ? "\(n)(max)" : "\(n)(\(m))"
		case "nvarchar", "nchar":
			guard let m = maxLength else { return n }
			return m == -1 ? "\(n)(max)" : "\(n)(\(m / 2))"
		case "decimal", "numeric":
			return "\(n)(\(precision ?? 18),\(scale ?? 0))"
		case "datetime2", "time", "datetimeoffset":
			return (scale ?? 7) == 7 ? n : "\(n)(\(scale ?? 7))"
		default:
			return n
		}
	}

	/// 기본값 정의 "((0))" · "(getdate())" · "(N'abc')" → 값과 EXTRA (글자 값은 글자, 숫자는 그대로, 그 밖은 식)
	static func normalizedDefault(_ raw: String?) -> (String?, String) {
		guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return (nil, "") }
		while t.hasPrefix("("), t.hasSuffix(")"), Self.wrapsAll(t) { t = String(t.dropFirst().dropLast()) }
		if t.uppercased() == "NULL" { return (nil, "") }
		if t.hasPrefix("N'") { t.removeFirst() }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") {
			return (String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"), "")
		}
		if Double(t) != nil { return (t, "") }
		return (t, "DEFAULT_GENERATED")
	}
	/// 맨 앞 ( 가 맨 끝 ) 와 짝인지
	private static func wrapsAll(_ s: String) -> Bool {
		var depth = 0
		for (i, ch) in s.enumerated() {
			if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 && i < s.count - 1 { return false } }
		}
		return depth == 0
	}

	private func column(_ r: [Value]) -> ColumnInfo {
		func s(_ i: Int) -> String? { r[safe: i]?.string }
		let type = Self.typeString(s(3) ?? "", maxLength: s(4).flatMap { Int($0) }, precision: s(5).flatMap { Int($0) }, scale: s(6).flatMap { Int($0) })
		let identity = s(8) == "1"
		var (def, extra) = identity ? (nil, "auto_increment") : Self.normalizedDefault(s(9))
		if let expr = s(12) { def = nil; extra = "VIRTUAL GENERATED"; _ = expr }
		return ColumnInfo(name: s(2) ?? "", type: type, nullable: s(7) == "1", key: s(11) == "1" ? "PRI" : "",
		                  defaultValue: def, extra: extra, comment: s(10) ?? "")
	}

	func databaseList(_ run: DBRun) async throws -> [String] {
		try await one(run, userDatabases + " ORDER BY name").rows.compactMap { $0.first?.string }
	}

	func schema(_ run: DBRun) async throws -> SchemaSnapshot? {
		var snap = SchemaSnapshot()
		snap.databases = try await databaseList(run)
		for db in snap.databases {
			let s = sys(db)
			let tables = try? await one(run, """
				SELECT sc.name, o.name, o.type, CAST(ep.value AS NVARCHAR(4000)),
				       (SELECT SUM(p.rows) FROM \(s)partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1))
				FROM \(s)objects o JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
				LEFT JOIN \(s)extended_properties ep ON ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
				WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0
				ORDER BY sc.name, o.name
				""")
			for r in tables?.rows ?? [] {
				let name = SQLServerDialect.displayName(schema: r[0].string ?? "", table: r[safe: 1]?.string ?? "")
				var t = TableInfo(schema: db, name: name, isView: r[safe: 2]?.string?.trimmingCharacters(in: .whitespaces) == "V",
				                  comment: r[safe: 3]?.string ?? "", rows: r[safe: 4]?.string.flatMap { Int64($0) })
				// 파티션의 행 수는 메타데이터라 정확하다 (InnoDB 처럼 어림값이 아니다)
				t.engine = "SQLSERVER"
				snap.tables.append(t)
			}
			let cols = try? await one(run, columnsSQL(db, "1 = 1"))
			for r in cols?.rows ?? [] {
				let id = db + "." + SQLServerDialect.displayName(schema: r[0].string ?? "", table: r[safe: 1]?.string ?? "")
				snap.columns[id, default: []].append(column(r))
			}
		}
		return snap
	}

	func routines(_ run: DBRun) async throws -> [RoutineInfo] {
		var out: [RoutineInfo] = []
		for db in try await databaseList(run) {
			let s = sys(db)
			let rows = (try? await one(run, """
				SELECT sc.name, o.name, o.type, ISNULL(OBJECT_NAME(tr.parent_id, DB_ID(\(lit(db)))), ''), tr.is_disabled, tr.is_instead_of_trigger,
				       (SELECT STRING_AGG(te.type_desc, ',') FROM \(s)trigger_events te WHERE te.object_id = o.object_id),
				       ISNULL(SCHEMA_NAME(po.schema_id), '')
				FROM \(s)objects o JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
				LEFT JOIN \(s)triggers tr ON tr.object_id = o.object_id
				LEFT JOIN \(s)objects po ON po.object_id = tr.parent_id
				WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'TR') AND o.is_ms_shipped = 0
				ORDER BY sc.name, o.name
				"""))?.rows ?? []
			for r in rows {
				let name = SQLServerDialect.displayName(schema: r[0].string ?? "", table: r[safe: 1]?.string ?? "")
				switch r[safe: 2]?.string?.trimmingCharacters(in: .whitespaces) {
				case "P": out.append(RoutineInfo(schema: db, name: name, kind: .procedure))
				case "TR":
					let when = r[safe: 5]?.string == "1" ? "INSTEAD OF" : "AFTER"
					let table = SQLServerDialect.displayName(schema: r[safe: 7]?.string ?? "dbo", table: r[safe: 3]?.string ?? "")
					out.append(RoutineInfo(schema: db, name: name, kind: .trigger,
					                       detail: "\(when) \((r[safe: 6]?.string ?? "").replacingOccurrences(of: ",", with: " · ")) · \(table)",
					                       enabled: r[safe: 4]?.string != "1"))
				default: out.append(RoutineInfo(schema: db, name: name, kind: .function))
				}
			}
		}
		return out
	}

	func serverCatalog(_ run: DBRun) async throws -> ServerCatalog { ServerCatalog() }

	/// DB 개요: 행 수(파티션 메타데이터, 정확), 데이터·인덱스 크기(사용 중 페이지 × 8KB), IDENTITY 다음 값, 수정 시각
	func tableStats(_ run: DBRun, schema db: String) async throws -> [TableStat] {
		let s = sys(db)
		let base = """
			SELECT sc.name, o.name, o.type, CAST(ep.value AS NVARCHAR(4000)), CONVERT(VARCHAR(19), o.modify_date, 120),
			       (SELECT SUM(p.rows) FROM \(s)partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)),
			       %SIZES%,
			       (SELECT CAST(ISNULL(ic.last_value, ic.seed_value) AS BIGINT) + CAST(ic.increment_value AS BIGINT) FROM \(s)identity_columns ic WHERE ic.object_id = o.object_id)
			FROM \(s)objects o JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
			LEFT JOIN \(s)extended_properties ep ON ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
			WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0
			ORDER BY sc.name, o.name
			"""
		// 크기는 sys.dm_db_partition_stats (VIEW DATABASE STATE 권한) → 안 되면 sys.allocation_units 로
		let withStats = base.replacingOccurrences(of: "%SIZES%", with: """
			(SELECT SUM(ps.used_page_count) * 8192 FROM \(s)dm_db_partition_stats ps WHERE ps.object_id = o.object_id AND ps.index_id IN (0, 1)),
			(SELECT SUM(ps.used_page_count) * 8192 FROM \(s)dm_db_partition_stats ps WHERE ps.object_id = o.object_id AND ps.index_id > 1)
			""")
		let withAlloc = base.replacingOccurrences(of: "%SIZES%", with: """
			(SELECT SUM(a.used_pages) * 8192 FROM \(s)partitions p JOIN \(s)allocation_units a ON a.container_id = p.partition_id WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)),
			(SELECT SUM(a.used_pages) * 8192 FROM \(s)partitions p JOIN \(s)allocation_units a ON a.container_id = p.partition_id WHERE p.object_id = o.object_id AND p.index_id > 1)
			""")
		let r: QueryResult
		do { r = try await one(run, withStats) } catch { r = try await one(run, withAlloc) }
		return r.rows.map { v in
			var st = TableStat(name: SQLServerDialect.displayName(schema: v[0].string ?? "", table: v[safe: 1]?.string ?? ""),
			                   isView: v[safe: 2]?.string?.trimmingCharacters(in: .whitespaces) == "V", engine: "",
			                   rows: v[safe: 5]?.string.flatMap { Int64($0) },
			                   dataLength: v[safe: 6]?.string.flatMap { Int64($0) } ?? 0, indexLength: v[safe: 7]?.string.flatMap { Int64($0) } ?? 0,
			                   dataFree: 0, autoIncrement: v[safe: 8]?.string.flatMap { Int64($0) }, collation: "",
			                   comment: v[safe: 3]?.string ?? "", updated: v[safe: 4]?.string ?? "")
			st.exact = true
			return st
		}
	}

	func tableStatus(_ run: DBRun, _ table: TableInfo) async throws -> TableStatus? {
		guard let st = try await tableStats(run, schema: table.schema).first(where: { $0.name == table.name }) else { return nil }
		let s = sys(table.schema)
		let created = try? await one(run, "SELECT CONVERT(VARCHAR(19), create_date, 120) FROM \(s)objects WHERE object_id = \(objectID(table.schema, table.name))")
		var t = TableStatus()
		t.approxRows = st.rows
		t.dataLength = st.dataLength
		t.indexLength = st.indexLength
		t.autoIncrement = st.autoIncrement
		t.comment = st.comment
		t.updated = st.updated
		t.created = created?.rows.first?.first?.string ?? ""
		return t
	}

	/// 뷰·루틴은 정의 글(sys.sql_modules), 테이블은 컬럼·기본 키로 만든 CREATE TABLE + 인덱스 (SQL Server 에는 SHOW CREATE TABLE 이 없다)
	func createStatement(_ run: DBRun, _ object: DBObject, schema db: String, name: String) async throws -> String? {
		switch object {
		case .table:
			if let def = try await moduleDefinition(run, db, name) { return def }   // 뷰를 테이블로 물은 경우
			return try await tableDDL(run, db, name)
		case .view, .routine:
			if let def = try await moduleDefinition(run, db, name) { return def }
			return (try? await one(run, "SELECT OBJECT_DEFINITION(\(objectID(db, name)))"))?.rows.first?.first?.string
		}
	}

	/// 끝의 ; 는 뺀다 (배치째 보낸 정의는 ; 까지 저장되어, 내보내기가 ; 를 또 붙이면 넣을 때마다 ;; ;;; 로 늘었다)
	private func moduleDefinition(_ run: DBRun, _ db: String, _ name: String) async throws -> String? {
		guard var def = try await one(run, "SELECT definition FROM \(sys(db))sql_modules WHERE object_id = \(objectID(db, name))").rows.first?.first?.string?
			.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
		while def.hasSuffix(";") { def = String(def.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
		return def
	}

	/// 컬럼 정의 + 기본 키 (+ 인덱스는 따로 선 CREATE INDEX). 외래 키는 표에 따로 보인다
	private func tableDDL(_ run: DBRun, _ db: String, _ name: String) async throws -> String? {
		let (sch, tbl) = SQLServerDialect.split(name)
		let rows = try await one(run, columnsSQL(db, "sc.name = \(lit(sch)) AND o.name = \(lit(tbl))")).rows
		guard !rows.isEmpty else { return nil }
		var lines: [String] = []
		for r in rows {
			func s(_ i: Int) -> String? { r[safe: i]?.string }
			if let expr = s(12) { lines.append("\(q(s(2) ?? "")) AS \(expr)"); continue }
			var l = q(s(2) ?? "") + " " + Self.typeString(s(3) ?? "", maxLength: s(4).flatMap { Int($0) }, precision: s(5).flatMap { Int($0) }, scale: s(6).flatMap { Int($0) })
			if s(8) == "1" { l += " IDENTITY(1,1)" }
			l += s(7) == "1" ? " NULL" : " NOT NULL"
			if let d = s(9) { l += " DEFAULT \(d)" }
			lines.append(l)
		}
		let idx = try await indexes(run, TableInfo(schema: db, name: name, isView: false, comment: ""), createSQL: "")
		if let pk = idx.first(where: { $0.kind == .primary }) {
			lines.append("CONSTRAINT \(q(pk.name)) PRIMARY KEY (\(pk.columns.map(q).joined(separator: ", ")))")
		}
		let target = dialect.quote(schema: "", table: name)
		var out = "CREATE TABLE \(target) (\n  " + lines.joined(separator: ",\n  ") + "\n)"
		for i in idx where i.kind != .primary {
			out += ";\nCREATE \(i.kind == .unique ? "UNIQUE " : "")INDEX \(q(i.name)) ON \(target) (\(i.columns.map(q).joined(separator: ", ")))"
		}
		return out
	}

	/// 내보내기 끝: 외래 키 (CREATE TABLE 에는 넣지 않아 테이블 순서와 상관없이 넣어진다). 내보낸 테이블끼리만.
	/// 테이블·컬럼 설명(MS_Description)도 다시 붙인다 (CREATE TABLE 에 넣을 수 없어서).
	/// 그리고 IDENTITY 마지막 값을 원래대로 (IDENTITY_INSERT 로 넣으면 넣은 최댓값이 되어, 지운 행 번호를 다시 쓰게 된다 — MySQL 의 AUTO_INCREMENT= 처럼)
	func dumpTrailer(_ run: DBRun, schema db: String, tables: [String]) async throws -> [String] {
		var out: [String] = []
		let names = Set(tables)
		for t in tables {
			for fk in try await foreignKeys(run, schema: db, table: t, incoming: false) where names.contains(fk.refTable) {
				out.append("ALTER TABLE \(dialect.quoteLocal(t)) " + dialect.addForeignKeyClause(fk, schema: db))
			}
		}
		let s = sys(db)
		let notes = try await one(run, """
			SELECT sc.name, o.name, c.name, CAST(ep.value AS NVARCHAR(4000)) FROM \(s)extended_properties ep
			JOIN \(s)objects o ON o.object_id = ep.major_id AND o.type = 'U' JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
			LEFT JOIN \(s)columns c ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
			WHERE ep.class = 1 AND ep.name = N'MS_Description' AND ep.value IS NOT NULL
			ORDER BY o.name, ep.minor_id
			""")
		for r in notes.rows {
			let schema = r[safe: 0]?.string ?? "dbo", table = r[safe: 1]?.string ?? ""
			guard names.contains(schema == "dbo" ? table : schema + "." + table), let text = r[safe: 3]?.string else { continue }
			func lit(_ v: String) -> String { dialect.literal(.text(v)) }
			var e = "EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = \(lit(text)), @level0type = N'SCHEMA', @level0name = \(lit(schema)), @level1type = N'TABLE', @level1name = \(lit(table))"
			if let col = r[safe: 2]?.string { e += ", @level2type = N'COLUMN', @level2name = \(lit(col))" }
			out.append(e)
		}
		let ids = try await one(run, """
			SELECT sc.name, o.name, CAST(ic.last_value AS BIGINT), CAST(ic.increment_value AS BIGINT) FROM \(s)identity_columns ic
			JOIN \(s)objects o ON o.object_id = ic.object_id AND o.type = 'U' JOIN \(s)schemas sc ON sc.schema_id = o.schema_id
			WHERE ic.last_value IS NOT NULL
			""")
		for r in ids.rows {
			let schema = r[safe: 0]?.string ?? "dbo", table = r[safe: 1]?.string ?? ""
			let local = schema == "dbo" ? table : schema + "." + table
			guard names.contains(local), let v = r[safe: 2]?.string.flatMap({ Int64($0) }) else { continue }
			// 만든 뒤 행을 한 번도 안 넣은 테이블은 다음 값이 RESEED 값 그대로라 (넣었으면 + 증가값) 비었을 때는 한 칸 더
			let step = r[safe: 3]?.string.flatMap { Int64($0) } ?? 1
			let name = dialect.quoteLocal(local), lit = name.replacingOccurrences(of: "'", with: "''")
			out.append("IF EXISTS (SELECT 1 FROM \(name)) DBCC CHECKIDENT (N'\(lit)', RESEED, \(v)) WITH NO_INFOMSGS ELSE DBCC CHECKIDENT (N'\(lit)', RESEED, \(v + step)) WITH NO_INFOMSGS")
		}
		return out
	}

	/// 내보내기 맨 앞 (있으면 지우기): 내보낸 테이블끼리의 외래 키를 이름과 상관없이 지운다 (넣을 DB 에서 찾아서).
	/// 다른 테이블이 가리키는 외래 키는 두므로 그런 테이블은 DROP TABLE 이 오류로 알려 준다
	func dumpPreamble(schema db: String, tables: [String]) -> [String] {
		guard !tables.isEmpty else { return [] }
		let ids = tables.map { "OBJECT_ID(N'" + dialect.quoteLocal($0).replacingOccurrences(of: "'", with: "''") + "')" }.joined(separator: ", ")
		return ["""
			DECLARE @isql_fk NVARCHAR(MAX) = N'';
			SELECT @isql_fk += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(parent_object_id))
			     + N' DROP CONSTRAINT ' + QUOTENAME(name) + N'; '
			  FROM sys.foreign_keys WHERE parent_object_id IN (\(ids)) AND referenced_object_id IN (\(ids));
			EXEC sys.sp_executesql @isql_fk
			"""]
	}

	func indexes(_ run: DBRun, _ table: TableInfo, createSQL: String) async throws -> [IndexInfo] {
		let s = sys(table.schema)
		let r = try await one(run, """
			SELECT i.name, i.is_primary_key, i.is_unique, i.type_desc, c.name
			FROM \(s)indexes i
			JOIN \(s)index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
			JOIN \(s)columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
			WHERE i.object_id = \(objectID(table.schema, table.name)) AND i.type > 0 AND i.is_hypothetical = 0
			ORDER BY i.is_primary_key DESC, i.name, ic.key_ordinal
			""")
		var list: [IndexInfo] = []
		for row in r.rows {
			let name = row[0].string ?? ""
			let col = row[safe: 4]?.string ?? ""
			if let k = list.firstIndex(where: { $0.name == name }) { list[k].columns.append(col); continue }
			let kind: IndexInfo.Kind = row[safe: 1]?.string == "1" ? .primary : row[safe: 2]?.string == "1" ? .unique : .index
			list.append(IndexInfo(name: name, kind: kind, columns: [col], method: row[safe: 3]?.string ?? "", cardinality: nil))
		}
		return list
	}

	func foreignKeys(_ run: DBRun, schema db: String, table: String, incoming: Bool) async throws -> [ForeignKeyInfo] {
		let s = sys(db)
		let filter = incoming ? "fk.referenced_object_id = \(objectID(db, table))" : "fk.parent_object_id = \(objectID(db, table))"
		let r = try await one(run, """
			SELECT fk.name, SCHEMA_NAME(po.schema_id), po.name, pc.name, SCHEMA_NAME(ro.schema_id), ro.name, rc.name,
			       fk.delete_referential_action_desc, fk.update_referential_action_desc
			FROM \(s)foreign_keys fk
			JOIN \(s)foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
			JOIN \(s)objects po ON po.object_id = fk.parent_object_id
			JOIN \(s)columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
			JOIN \(s)objects ro ON ro.object_id = fk.referenced_object_id
			JOIN \(s)columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
			WHERE \(filter)
			ORDER BY po.name, fk.name, fkc.constraint_column_id
			""")
		func rule(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }
		var list: [ForeignKeyInfo] = []
		for row in r.rows {
			func v(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			let tbl = SQLServerDialect.displayName(schema: v(1), table: v(2))
			let ref = SQLServerDialect.displayName(schema: v(4), table: v(5))
			if let k = list.indices.last, list[k].name == v(0), list[k].table == tbl {
				list[k].columns.append(v(3)); list[k].refColumns.append(v(6))
			} else {
				list.append(ForeignKeyInfo(name: v(0), schema: db, table: tbl, columns: [v(3)], refSchema: db, refTable: ref,
				                           refColumns: [v(6)], onDelete: rule(v(7)), onUpdate: rule(v(8))))
			}
		}
		return list
	}

	func structure(_ run: DBRun, _ table: TableInfo) async throws -> (columns: [StructColumn], definitions: [String: String])? {
		let (sch, tbl) = SQLServerDialect.split(table.name)
		let r = try await one(run, columnsSQL(table.schema, "sc.name = \(lit(sch)) AND o.name = \(lit(tbl))"))
		guard !r.rows.isEmpty else { return nil }
		let list = r.rows.map { row -> StructColumn in
			let info = column(row)
			var s = StructColumn(info: info)
			s.unsigned = false; s.zerofill = false
			s.defaultExpr = info.extra.contains("DEFAULT_GENERATED")
			s.onUpdate = ""
			s.charset = nil
			s.collation = row[safe: 13]?.string
			if let expr = row[safe: 12]?.string { s.generated = "VIRTUAL"; s.generationExpr = expr }
			return s
		}
		return (list, [:])
	}

	func schemaDefaults(_ run: DBRun, schema: String) async throws -> (charset: String, collation: String)? {
		guard let c = try await one(run, "SELECT CAST(DATABASEPROPERTYEX(\(lit(schema)), 'Collation') AS NVARCHAR(128))").rows.first?.first?.string else { return nil }
		return ("", c)
	}
	func serverDefaults(_ run: DBRun) async throws -> (charset: String, collation: String)? {
		guard let c = try await one(run, "SELECT CAST(SERVERPROPERTY('Collation') AS NVARCHAR(128))").rows.first?.first?.string else { return nil }
		return ("", c)
	}
	func defaultEngine(_ run: DBRun) async throws -> String? { nil }

	/// DB 복제는 아직 없다 (capabilities 로 숨긴다)
	func copyTables(_ run: DBRun, schema: String) async throws -> [CopyTableInfo] { [] }
	func routineNames(_ run: DBRun, schema: String) async throws -> [(kind: RoutineKind, name: String)] {
		try await routines(run).filter { $0.schema == schema }.map { ($0.kind, $0.name) }
	}

	func contents(_ run: DBRun, schema db: String) async -> SchemaContents {
		var c = SchemaContents()
		let rows = (try? await one(run, """
			SELECT o.type, sc.name, o.name FROM \(sys(db))objects o JOIN \(sys(db))schemas sc ON sc.schema_id = o.schema_id
			WHERE o.is_ms_shipped = 0 AND o.type IN ('U', 'V', 'TR', 'P', 'FN', 'IF', 'TF')
			"""))?.rows ?? []
		func name(_ r: [Value]) -> String { SQLServerDialect.displayName(schema: r[safe: 1]?.string ?? "", table: r[safe: 2]?.string ?? "") }
		func type(_ r: [Value]) -> String { r[0].string?.trimmingCharacters(in: .whitespaces) ?? "" }
		c.tables = rows.filter { type($0) == "U" }.map(name)
		c.views = rows.filter { type($0) == "V" }.map(name)
		c.triggers = rows.filter { type($0) == "TR" }.count
		c.routines = rows.filter { ["P", "FN", "IF", "TF"].contains(type($0)) }.count
		return c
	}

	func tableCount(_ run: DBRun, schema db: String) async throws -> Int? {
		Int(try await one(run, "SELECT COUNT(*) FROM \(sys(db))objects WHERE type IN ('U', 'V') AND is_ms_shipped = 0").rows.first?.first?.string ?? "")
	}

	func viewDefinition(_ run: DBRun, schema: String, name: String) async throws -> String? {
		guard let def = try await moduleDefinition(run, schema, name) else { return nil }
		// CREATE VIEW … AS 뒤의 SELECT 만
		if let r = def.range(of: #"(?is)^.*?\bAS\b\s*"#, options: .regularExpression) { return String(def[r.upperBound...]) }
		return def
	}

	func needsClientCopy(_ run: DBRun) async -> Bool { false }

	func connectionInfo(_ run: DBRun) async throws -> (version: String?, user: String?, databases: String?) {
		let v = try await one(run, "SELECT @@VERSION, SUSER_NAME(), (SELECT COUNT(*) FROM (\(userDatabases)) d)").rows.first
		let version = v?[safe: 0]?.string?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
		return (version, v?[safe: 1]?.string, v?[safe: 2]?.string)
	}

	func databaseNames(_ run: DBRun) async throws -> [String] {
		try await one(run, "SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY name").rows.compactMap { $0.first?.string }
	}

	func tableList(_ run: DBRun, schema: String) async throws -> [(name: String, isView: Bool, approxRows: Int?, comment: String)] {
		try await tableStats(run, schema: schema).map { ($0.name, $0.isView, $0.rows.map { Int($0) }, $0.comment) }
	}

	// MARK: 루틴·계정·서버 상태

	private var unsupported: DBError { .message("SQL Server 에서는 아직 지원하지 않는 기능입니다.") }

	func routineParameters(_ run: DBRun, schema db: String, name: String) async throws -> [(mode: String, name: String, type: String)] {
		let s = sys(db)
		return try await one(run, """
			SELECT p.is_output, p.name, t.name, p.max_length, p.precision, p.scale FROM \(s)parameters p
			JOIN \(s)types t ON t.user_type_id = p.user_type_id
			WHERE p.object_id = \(objectID(db, name)) AND p.parameter_id > 0 ORDER BY p.parameter_id
			""").rows.map { r in
			let type = Self.typeString(r[safe: 2]?.string ?? "", maxLength: r[safe: 3]?.string.flatMap { Int($0) },
			                           precision: r[safe: 4]?.string.flatMap { Int($0) }, scale: r[safe: 5]?.string.flatMap { Int($0) })
			return (r[0].string == "1" ? "OUT" : "IN", String((r[safe: 1]?.string ?? "").drop(while: { $0 == "@" })), type)
		}
	}
	func eventSchedulerOff(_ run: DBRun) async -> Bool { false }
	func accounts(_ run: DBRun) async throws -> [DBAccount] { throw unsupported }

	/// 사용자 계정 보기만: 로그인(sys.server_principals) · 서버 역할 · 서버 권한, 그리고 DB 마다 그 로그인에 이어진 사용자와 DB 역할.
	/// 남의 로그인은 VIEW ANY DEFINITION(또는 sysadmin) 이 있어야 보인다. 없으면 자기 것과 sa 정도만
	func accountOverview(_ run: DBRun) async throws -> AccountOverview {
		var o = AccountOverview()
		o.current = try await one(run, "SELECT SUSER_NAME()").rows.first?.first?.string ?? ""
		let kinds = ["S": "SQL 로그인", "U": "Windows 로그인", "G": "Windows 그룹", "E": "Entra ID 사용자", "X": "Entra ID 그룹", "C": "인증서", "K": "비대칭 키"]
		let logins = try await one(run, """
			SELECT sp.name, sp.type, sp.is_disabled, CONVERT(VARCHAR(19), sp.create_date, 120), CONVERT(VARCHAR(19), sp.modify_date, 120),
			       sp.default_database_name, sp.default_language_name, sl.is_policy_checked, sl.is_expiration_checked,
			       CAST(LOGINPROPERTY(sp.name, 'IsLocked') AS INT), CAST(LOGINPROPERTY(sp.name, 'IsExpired') AS INT),
			       CONVERT(VARCHAR(19), CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS DATETIME), 120),
			       CAST(LOGINPROPERTY(sp.name, 'BadPasswordCount') AS INT)
			  FROM sys.server_principals sp LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
			 WHERE sp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
			 ORDER BY CASE WHEN sp.name LIKE '##%' OR sp.name LIKE 'NT %' OR sp.name LIKE 'BUILTIN\\%' THEN 1 ELSE 0 END, sp.name
			""")
		let roles = try await one(run, """
			SELECT m.name, r.name FROM sys.server_role_members rm
			JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
			JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id ORDER BY r.name
			""")
		let perms = try await one(run, """
			SELECT p.name, sp.state_desc, sp.permission_name FROM sys.server_permissions sp
			JOIN sys.server_principals p ON p.principal_id = sp.grantee_principal_id
			WHERE sp.class = 100 ORDER BY sp.permission_name
			""")
		var roleMap: [String: [String]] = [:], permMap: [String: [String]] = [:]
		for r in roles.rows { if let m = r[safe: 0]?.string, let n = r[safe: 1]?.string { roleMap[m, default: []].append(n) } }
		for r in perms.rows {
			guard let m = r[safe: 0]?.string else { continue }
			// 모든 로그인이 기본으로 받는 CONNECT SQL 은 빼고 (막은 DENY 만 보인다)
			if r[safe: 2]?.string == "CONNECT SQL", r[safe: 1]?.string == "GRANT" { continue }
			let state = (r[safe: 1]?.string ?? "").replacingOccurrences(of: "_WITH_GRANT_OPTION", with: "")
			let withGrant = (r[safe: 1]?.string ?? "").hasSuffix("WITH_GRANT_OPTION")
			permMap[m, default: []].append("\(state) \(r[safe: 2]?.string ?? "")" + (withGrant ? " (WITH GRANT OPTION)" : ""))
		}
		// DB 마다: 로그인과 sid 로 이어진 사용자 · 기본 스키마 · DB 역할 (역할은 줄마다, 여기서 묶는다 — STRING_AGG 는 2017 부터)
		var access: [String: [AccountInfo.Access]] = [:]
		var unreadable: [String] = []
		for db in try await databaseNames(run) where !["tempdb", "model"].contains(db) {
			let s = sys(db)
			do {
				let r = try await one(run, """
					SELECT sp.name, dp.name, ISNULL(dp.default_schema_name, N''), r.name
					  FROM \(s)database_principals dp
					  JOIN sys.server_principals sp ON sp.sid = dp.sid
					  LEFT JOIN \(s)database_role_members rm ON rm.member_principal_id = dp.principal_id
					  LEFT JOIN \(s)database_principals r ON r.principal_id = rm.role_principal_id
					 WHERE dp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
					 ORDER BY sp.name, r.name
					""")
				var byLogin: [String: (user: String, schema: String, roles: [String])] = [:]
				var order: [String] = []
				for row in r.rows {
					guard let login = row[safe: 0]?.string else { continue }
					if byLogin[login] == nil { order.append(login); byLogin[login] = (row[safe: 1]?.string ?? "", row[safe: 2]?.string ?? "", []) }
					if let role = row[safe: 3]?.string { byLogin[login]?.roles.append(role) }
				}
				for login in order { if let a = byLogin[login] { access[login, default: []].append(.init(database: db, user: a.user, schema: a.schema, roles: a.roles)) } }
			} catch {
				unreadable.append(db)
			}
		}
		for row in logins.rows {
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			let name = s(0), type = s(1)
			var a = AccountInfo(name: name, kind: kinds[type] ?? type)
			a.system = name.hasPrefix("##") || name.hasPrefix("NT ") || name.hasPrefix("BUILTIN\\")
			let locked = s(9) == "1", expired = s(10) == "1", disabled = s(2) == "1"
			a.disabled = locked || expired || disabled
			a.fields.append(.init(label: "상태", value: [disabled ? "사용 안 함" : nil, locked ? "잠김" : nil, expired ? "비밀번호 만료" : nil].compactMap { $0 }.joined(separator: " · ").ifEmpty("사용 중")))
			a.fields.append(.init(label: "종류", value: a.kind))
			if type == "S" {
				a.fields.append(.init(label: "암호 정책", value: s(7) == "1" ? "검사" : "검사 안 함"))
				a.fields.append(.init(label: "만료 검사", value: s(8) == "1" ? "검사" : "검사 안 함"))
				if !s(11).isEmpty { a.fields.append(.init(label: "비밀번호 바꾼 때", value: s(11))) }
				if let bad = Int(s(12)), bad > 0 { a.fields.append(.init(label: "틀린 비밀번호", value: "\(bad)번")) }
			}
			a.fields.append(.init(label: "기본 DB", value: s(5).ifEmpty("—")))
			a.fields.append(.init(label: "기본 언어", value: s(6).ifEmpty("—")))
			a.fields.append(.init(label: "만든 때", value: s(3)))
			a.fields.append(.init(label: "바꾼 때", value: s(4)))
			a.roles = roleMap[name] ?? []
			a.permissions = permMap[name] ?? []
			a.databases = access[name] ?? []
			o.accounts.append(a)
		}
		var notes: [String] = []
		let seeAll = try await one(run, "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')").rows.first?.first?.string == "1"
		if !seeAll {
			notes.append("다른 로그인을 보려면 VIEW ANY DEFINITION 권한이 있어야 합니다.")
		}
		if !unreadable.isEmpty { notes.append("읽지 못한 DB: \(unreadable.joined(separator: ", "))") }
		o.note = notes.isEmpty ? nil : notes.joined(separator: " ")
		o.databaseTitle = "DB 사용자 · 역할"
		return o
	}
	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]] { throw unsupported }
	func currentUser(_ run: DBRun) async throws -> String? { try await one(run, "SELECT SUSER_NAME()").rows.first?.first?.string }
	func grantStatements(_ run: DBRun, account: String) async throws -> [String] { throw unsupported }
	/// 상태 요약 (한 번에 읽는다). 다른 세션까지 보려면 VIEW SERVER STATE 권한이 있어야 한다.
	/// questions = Batch Requests/sec 누적값, received·sent = 패킷 수 (@@PACK_*),
	/// 느린 쿼리 = 계획 캐시에서 평균 1초 넘는 쿼리의 실행 횟수, 버퍼 풀 = Buffer Manager 의 데이터 페이지 / 목표 서버 메모리
	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary {
		let r = try await one(run, """
			SET NOCOUNT ON;
			DECLARE @pc TABLE (name NVARCHAR(128), v BIGINT);
			INSERT INTO @pc SELECT RTRIM(counter_name), cntr_value FROM sys.dm_os_performance_counters
			 WHERE (object_name LIKE N'%Buffer Manager%' AND counter_name IN (N'Buffer cache hit ratio', N'Buffer cache hit ratio base', N'Database pages'))
			    OR (object_name LIKE N'%SQL Statistics%' AND counter_name = N'Batch Requests/sec')
			    OR (object_name LIKE N'%Memory Manager%' AND counter_name = N'Target Server Memory (KB)');
			SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)),
			       (SELECT DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) FROM sys.dm_os_sys_info),
			       (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1),
			       (SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.is_user_process = 1),
			       @@MAX_CONNECTIONS,
			       (SELECT SUM(v) FROM @pc WHERE name = N'Batch Requests/sec'),
			       (SELECT SUM(execution_count) FROM sys.dm_exec_query_stats WHERE total_elapsed_time >= execution_count * 1000000),
			       (SELECT SUM(v) FROM @pc WHERE name = N'Buffer cache hit ratio'),
			       (SELECT SUM(v) FROM @pc WHERE name = N'Buffer cache hit ratio base'),
			       (SELECT SUM(v) FROM @pc WHERE name = N'Database pages'),
			       (SELECT SUM(v) FROM @pc WHERE name = N'Target Server Memory (KB)'),
			       CAST(@@PACK_RECEIVED AS BIGINT), CAST(@@PACK_SENT AS BIGINT)
			""")
		guard let row = r.rows.first else { throw DBError.message("서버 상태를 읽지 못했습니다.") }
		func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
		func i(_ i: Int) -> Int64 { Int64(s(i)) ?? 0 }
		var out = ServerDiagnostics.Summary()
		out.version = [s(0), s(1)].filter { !$0.isEmpty }.joined(separator: " · ")
		out.uptime = Int(i(2))
		out.connected = Int(i(3))
		out.running = Int(i(4))
		out.maxConnections = Int(i(5))
		out.questions = Int(i(6))
		out.slowQueries = Int(i(7))
		out.longQueryTime = "1"
		if i(9) > 0 { out.bufferHit = min(1, Double(i(8)) / Double(i(9))) }
		out.bufferUsed = i(10) * 8192
		out.bufferSize = i(11) * 1024
		out.received = i(12)
		out.sent = i(13)
		return out
	}

	/// 사용자 세션 목록. 실행 중이면 명령 "Query"·시간은 시작한 뒤, 쉬는 중이면 "Sleep"·마지막 요청 뒤 (MySQL 프로세스 목록처럼).
	/// 잠금 대기(LCK_*)는 상태에 "lock" 과 막고 있는 세션을 적는다
	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process] {
		let r = try await one(run, """
			SELECT s.session_id, s.login_name, COALESCE(c.client_net_address + ':' + CAST(c.client_tcp_port AS NVARCHAR(10)), s.host_name, N''),
			       DB_NAME(COALESCE(r.database_id, s.database_id)),
			       CASE WHEN r.session_id IS NULL THEN N'Sleep' ELSE N'Query' END,
			       CASE WHEN r.session_id IS NULL THEN DATEDIFF(SECOND, s.last_request_end_time, GETDATE())
			            ELSE DATEDIFF(SECOND, r.start_time, GETDATE()) END,
			       r.status, r.wait_type, r.blocking_session_id, r.command,
			       CASE WHEN r.session_id IS NULL THEN N'' ELSE COALESCE(
			         SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
			           (CASE WHEN r.statement_end_offset <= 0 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1), t.text, N'') END,
			       s.program_name
			  FROM sys.dm_exec_sessions s
			  LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
			  LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id AND c.parent_connection_id IS NULL
			  OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
			 WHERE s.is_user_process = 1
			 ORDER BY s.session_id
			""")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			var state = [s(6), s(9)].filter { !$0.isEmpty }.joined(separator: " · ")
			let wait = s(7)
			if wait.hasPrefix("LCK_") {
				state = ((Int64(s(8)) ?? 0) > 0 ? "\(s(8)) 이 막음 · " : "") + "\(wait) lock"
			} else if !wait.isEmpty {
				state += " · \(wait)"
			}
			if s(4) == "Sleep" { state = s(11) }
			return ServerDiagnostics.Process(id: Int64(s(0)) ?? 0, user: s(1), host: s(2), db: s(3), command: s(4),
			                                 time: max(0, Int(s(5)) ?? 0), state: state, info: s(10).trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	/// 계획 캐시의 쿼리별 통계 (query_hash 로 묶음, 총 시간 순). 값을 ? 로 바꾸지 않고 한 문장을 보기로 보여 준다.
	/// rowsExamined = 논리 읽기(페이지), rowsSent = 돌려준 행
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest] {
		let r = try await one(run, """
			SELECT TOP (\(max(1, min(limit, 200)))) MAX(x.sql), MAX(x.db), SUM(x.execution_count), SUM(x.total_elapsed_time) / 1e6,
			       SUM(x.total_elapsed_time) / 1e6 / NULLIF(SUM(x.execution_count), 0), SUM(x.total_logical_reads), SUM(x.total_rows)
			  FROM (SELECT q.query_hash, q.execution_count, q.total_elapsed_time, q.total_logical_reads, q.total_rows,
			               SUBSTRING(t.text, q.statement_start_offset / 2 + 1,
			                 (CASE WHEN q.statement_end_offset <= 0 THEN DATALENGTH(t.text) ELSE q.statement_end_offset END - q.statement_start_offset) / 2 + 1) AS sql,
			               DB_NAME(CONVERT(INT, a.value)) AS db
			          FROM sys.dm_exec_query_stats q
			          CROSS APPLY sys.dm_exec_sql_text(q.sql_handle) t
			          OUTER APPLY (SELECT value FROM sys.dm_exec_plan_attributes(q.plan_handle) WHERE attribute = N'dbid') a) x
			 GROUP BY x.query_hash
			 ORDER BY SUM(x.total_elapsed_time) DESC
			""")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			return ServerDiagnostics.Digest(sql: s(0).trimmingCharacters(in: .whitespacesAndNewlines), schema: s(1), count: Int64(s(2)) ?? 0,
			                                totalSeconds: Double(s(3)) ?? 0, avgSeconds: Double(s(4)) ?? 0,
			                                rowsExamined: Int64(s(5)) ?? 0, rowsSent: Int64(s(6)) ?? 0)
		}
	}
	/// 서버 설정 (sys.configurations, 지금 쓰는 값)
	func variables(_ run: DBRun) async throws -> [(String, String)] {
		try await one(run, "SELECT name, CAST(value_in_use AS NVARCHAR(100)) FROM sys.configurations ORDER BY name").rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
	}
	func connectionID(_ run: DBRun) async throws -> Int64? {
		try await one(run, "SELECT @@SPID").rows.first?.first?.string.flatMap { Int64($0) }
	}
}
