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

	private func moduleDefinition(_ run: DBRun, _ db: String, _ name: String) async throws -> String? {
		try await one(run, "SELECT definition FROM \(sys(db))sql_modules WHERE object_id = \(objectID(db, name))").rows.first?.first?.string?
			.trimmingCharacters(in: .whitespacesAndNewlines)
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

	/// 내보내기 끝: 외래 키 (CREATE TABLE 에는 넣지 않아 테이블 순서와 상관없이 넣어진다). 내보낸 테이블끼리만
	func dumpTrailer(_ run: DBRun, schema db: String, tables: [String]) async throws -> [String] {
		var out: [String] = []
		let names = Set(tables)
		for t in tables {
			for fk in try await foreignKeys(run, schema: db, table: t, incoming: false) where names.contains(fk.refTable) {
				out.append("ALTER TABLE \(dialect.quoteLocal(t)) " + dialect.addForeignKeyClause(fk, schema: db))
			}
		}
		return out
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
	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]] { throw unsupported }
	func currentUser(_ run: DBRun) async throws -> String? { try await one(run, "SELECT SUSER_NAME()").rows.first?.first?.string }
	func grantStatements(_ run: DBRun, account: String) async throws -> [String] { throw unsupported }
	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary { throw unsupported }
	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process] { throw unsupported }
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest] { throw unsupported }
	/// 서버 설정 (sys.configurations, 지금 쓰는 값)
	func variables(_ run: DBRun) async throws -> [(String, String)] {
		try await one(run, "SELECT name, CAST(value_in_use AS NVARCHAR(100)) FROM sys.configurations ORDER BY name").rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
	}
	func connectionID(_ run: DBRun) async throws -> Int64? {
		try await one(run, "SELECT @@SPID").rows.first?.first?.string.flatMap { Int64($0) }
	}
}
