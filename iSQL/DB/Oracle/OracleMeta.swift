import Foundation

/// Oracle 메타데이터 읽기: ALL_* 사전 뷰. "데이터베이스" = 스키마(사용자). Oracle 이 관리하는 스키마(SYS · SYSTEM …)는 뺀다 (12c 이상의 ORACLE_MAINTAINED)
struct OracleMeta: SQLMeta {
	var dialect: OracleDialect { OracleDialect() }
	var systemSchemas: Set<String> { [] }

	private func lit(_ s: String) -> String { dialect.literal(.text(s)) }
	private func one(_ run: DBRun, _ sql: String) async throws -> QueryResult { try await run(sql).last ?? QueryResult() }
	/// 목록에 보일 스키마 (Oracle 이 관리하지 않는 사용자 + 지금 사용자)
	private let userSchemas = "SELECT username FROM all_users WHERE oracle_maintained = 'N' UNION SELECT USER FROM dual"
	/// 테이블 (휴지통 · 중첩 · 보조 테이블 빼고)
	private let realTables = "dropped = 'NO' AND nested = 'NO' AND secondary = 'N'"

	/// 컬럼 정보 쿼리 (owner, table, column, data_type, data_length, precision, scale, char_length, nullable, data_default, identity, comment)
	private func columnsSQL(_ where: String) -> String {
		"""
		SELECT c.owner, c.table_name, c.column_name, c.data_type, c.data_length, c.data_precision, c.data_scale, c.char_length,
		       c.nullable, c.data_default, c.identity_column, cc.comments
		FROM all_tab_columns c
		LEFT JOIN all_col_comments cc ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
		WHERE \(`where`)
		ORDER BY c.owner, c.table_name, c.column_id
		"""
	}

	/// 기본 키 컬럼 (owner, table, column)
	private func primaryKeysSQL(_ where: String) -> String {
		"""
		SELECT k.owner, k.table_name, kc.column_name FROM all_constraints k
		JOIN all_cons_columns kc ON kc.owner = k.owner AND kc.constraint_name = k.constraint_name
		WHERE k.constraint_type = 'P' AND \(`where`) ORDER BY k.owner, k.table_name, kc.position
		"""
	}

	/// 컬럼 한 줄 → ColumnInfo
	private func column(_ r: [Value], primary: Set<String>) -> ColumnInfo {
		func s(_ i: Int) -> String? { r[safe: i]?.string }
		let type = Self.typeString(s(3) ?? "", length: Int(s(4) ?? ""), precision: Int(s(5) ?? ""), scale: Int(s(6) ?? ""), charLength: Int(s(7) ?? ""))
		let identity = s(10) == "YES"
		let (def, extra) = identity ? (nil, "auto_increment") : Self.normalizedDefault(s(9))
		let key = primary.contains((s(0) ?? "") + "." + (s(1) ?? "") + "." + (s(2) ?? "")) ? "PRI" : ""
		return ColumnInfo(name: s(2) ?? "", type: type, nullable: s(8) != "N", key: key, defaultValue: def, extra: extra, comment: s(11) ?? "")
	}

	/// Oracle 형식 글자 (VARCHAR2(50), NUMBER(12,2), RAW(16) …). TIMESTAMP(6) · INTERVAL … 은 DATA_TYPE 에 이미 들어 있다
	static func typeString(_ dt: String, length: Int?, precision: Int?, scale: Int?, charLength: Int?) -> String {
		switch dt {
		case "VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "VARCHAR":
			return "\(dt)(\(charLength ?? length ?? 0))"
		case "NUMBER":
			if let p = precision {
				if let s = scale, s != 0 { return "NUMBER(\(p),\(s))" }
				return "NUMBER(\(p))"
			}
			return scale == 0 ? "INTEGER" : "NUMBER"
		case "RAW": return "RAW(\(length ?? 0))"
		case "FLOAT": return precision.map { "FLOAT(\($0))" } ?? "FLOAT"
		default: return dt
		}
	}

	/// DATA_DEFAULT('abc ', SYSDATE …) → 값과 EXTRA. 따옴표 값은 글자, NULL 은 nil, 숫자는 그대로, 그 밖은 식
	static func normalizedDefault(_ raw: String?) -> (String?, String) {
		guard let raw else { return (nil, "") }
		let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty || t.uppercased() == "NULL" { return (nil, "") }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") {
			return (String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"), "")
		}
		if Double(t) != nil { return (t, "") }
		return (t, "DEFAULT_GENERATED")
	}

	func schema(_ run: DBRun) async throws -> SchemaSnapshot? {
		let users = try await one(run, "SELECT username FROM (\(userSchemas)) ORDER BY username")
		let tables = try await one(run, """
			SELECT t.owner, t.table_name, 'TABLE', c.comments, t.num_rows FROM all_tables t
			LEFT JOIN all_tab_comments c ON c.owner = t.owner AND c.table_name = t.table_name
			WHERE t.owner IN (\(userSchemas)) AND t.\(realTables.replacingOccurrences(of: " AND ", with: " AND t."))
			UNION ALL
			SELECT v.owner, v.view_name, 'VIEW', c.comments, NULL FROM all_views v
			LEFT JOIN all_tab_comments c ON c.owner = v.owner AND c.table_name = v.view_name
			WHERE v.owner IN (\(userSchemas))
			ORDER BY 1, 2
			""")
		let cols = try await one(run, columnsSQL("c.owner IN (\(userSchemas)) AND c.table_name NOT LIKE 'BIN$%'"))
		let pks = try await one(run, primaryKeysSQL("k.owner IN (\(userSchemas))"))
		let primary = Set(pks.rows.map { ($0[0].string ?? "") + "." + ($0[safe: 1]?.string ?? "") + "." + ($0[safe: 2]?.string ?? "") })

		var s = SchemaSnapshot()
		s.databases = users.rows.compactMap { $0.first?.string }
		s.tables = tables.rows.map { r in
			TableInfo(schema: r[0].string ?? "", name: r[safe: 1]?.string ?? "", isView: r[safe: 2]?.string == "VIEW",
			          comment: r[safe: 3]?.string ?? "", rows: r[safe: 4]?.string.flatMap { Int64($0) })
		}
		let known = Set(s.tables.map(\.id))
		let views = Set(s.tables.filter(\.isView).map(\.id))
		for r in cols.rows {
			let id = (r[0].string ?? "") + "." + (r[safe: 1]?.string ?? "")
			guard known.contains(id) else { continue }
			var c = column(r, primary: primary)
			// 뷰 컬럼도 원래 테이블의 IDENTITY 를 물려받아 보이지만 뷰에는 자동 증가가 없다
			if views.contains(id) { c.extra = "" }
			s.columns[id, default: []].append(c)
		}
		return s
	}

	func routines(_ run: DBRun) async throws -> [RoutineInfo] {
		let objs = try await one(run, """
			SELECT owner, object_name, object_type, status FROM all_objects
			WHERE object_type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE') AND owner IN (\(userSchemas)) ORDER BY owner, object_name
			""")
		let trig = try await one(run, """
			SELECT owner, trigger_name, trigger_type, triggering_event, table_name, status FROM all_triggers
			WHERE owner IN (\(userSchemas)) ORDER BY owner, trigger_name
			""")
		var out = objs.rows.map { r in
			RoutineInfo(schema: r[0].string ?? "", name: r[safe: 1]?.string ?? "",
			            kind: r[safe: 2]?.string == "FUNCTION" ? .function : r[safe: 2]?.string == "PACKAGE" ? .package : .procedure,
			            detail: r[safe: 3]?.string == "INVALID" ? "INVALID" : "")
		}
		out += trig.rows.map { r in
			let type = (r[safe: 2]?.string ?? "").uppercased()
			let when = type.hasPrefix("INSTEAD OF") ? "INSTEAD OF" : type.hasPrefix("AFTER") ? "AFTER" : type.hasPrefix("BEFORE") ? "BEFORE" : type
			return RoutineInfo(schema: r[0].string ?? "", name: r[safe: 1]?.string ?? "", kind: .trigger,
			                   detail: "\(when) \(r[safe: 3]?.string ?? "") · \(r[safe: 4]?.string ?? "")", enabled: r[safe: 5]?.string == "ENABLED")
		}
		return out
	}

	func serverCatalog(_ run: DBRun) async throws -> ServerCatalog { ServerCatalog() }

	/// DB 개요: 행 수는 통계(NUM_ROWS, 마지막 분석 때), 크기는 행 수 × 평균 행 길이 (세그먼트 크기는 권한이 있어야 읽혀서)
	func tableStats(_ run: DBRun, schema: String) async throws -> [TableStat] {
		let r = try await one(run, """
			SELECT t.table_name, 'TABLE', t.num_rows, t.avg_row_len, TO_CHAR(t.last_analyzed, 'YYYY-MM-DD HH24:MI:SS'), c.comments
			FROM all_tables t LEFT JOIN all_tab_comments c ON c.owner = t.owner AND c.table_name = t.table_name
			WHERE t.owner = \(lit(schema)) AND t.dropped = 'NO' AND t.nested = 'NO' AND t.secondary = 'N'
			UNION ALL
			SELECT v.view_name, 'VIEW', NULL, NULL, NULL, c.comments
			FROM all_views v LEFT JOIN all_tab_comments c ON c.owner = v.owner AND c.table_name = v.view_name
			WHERE v.owner = \(lit(schema))
			ORDER BY 1
			""")
		return r.rows.map { v in
			let rows = v[safe: 2]?.string.flatMap { Int64($0) }
			let avg = v[safe: 3]?.string.flatMap { Int64($0) } ?? 0
			return TableStat(name: v[0].string ?? "", isView: v[safe: 1]?.string == "VIEW", engine: "", rows: rows,
			                 dataLength: (rows ?? 0) * avg, indexLength: 0, dataFree: 0, autoIncrement: nil, collation: "",
			                 comment: v[safe: 5]?.string ?? "", updated: v[safe: 4]?.string ?? "")
		}
	}

	func tableStatus(_ run: DBRun, _ table: TableInfo) async throws -> TableStatus? {
		guard let v = try await one(run, """
			SELECT t.num_rows, t.avg_row_len, TO_CHAR(t.last_analyzed, 'YYYY-MM-DD HH24:MI:SS'), c.comments,
			       TO_CHAR(o.created, 'YYYY-MM-DD HH24:MI:SS'), TO_CHAR(o.last_ddl_time, 'YYYY-MM-DD HH24:MI:SS')
			FROM all_tables t
			LEFT JOIN all_tab_comments c ON c.owner = t.owner AND c.table_name = t.table_name
			LEFT JOIN all_objects o ON o.owner = t.owner AND o.object_name = t.table_name AND o.object_type = 'TABLE'
			WHERE t.owner = \(lit(table.schema)) AND t.table_name = \(lit(table.name))
			""").rows.first else { return nil }
		var s = TableStatus()
		s.approxRows = v[0].string.flatMap { Int64($0) }
		s.avgRowLength = v[safe: 1]?.string.flatMap { Int64($0) } ?? 0
		s.dataLength = (s.approxRows ?? 0) * s.avgRowLength
		s.comment = v[safe: 3]?.string ?? ""
		s.created = v[safe: 4]?.string ?? ""
		s.updated = v[safe: 5]?.string ?? v[safe: 2]?.string ?? ""
		return s
	}

	/// DBMS_METADATA.GET_DDL (저장소 · 세그먼트 절은 빼고, 끝에 ; 없이)
	func createStatement(_ run: DBRun, _ object: DBObject, schema: String, name: String) async throws -> String? {
		let type: String
		switch object {
		case .table: type = "TABLE"
		case .view: type = "VIEW"
		case .routine(let k):
			switch k {
			case .procedure: type = "PROCEDURE"
			case .function: type = "FUNCTION"
			case .trigger: type = "TRIGGER"
			case .view: type = "VIEW"
			case .event: return nil
			case .package: return try await packageSource(run, schema: schema, name: name)
			}
		}
		await setTransforms(run, forDump: false)
		let owner = schema.isEmpty ? "SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')" : lit(schema)
		// 다른 객체가 같은 이름이면(뷰를 테이블로 물으면) 오류 → 뷰로 다시
		var ddl = try? await one(run, "SELECT DBMS_METADATA.GET_DDL('\(type)', \(lit(name)), \(owner)) FROM dual").rows.first?.first?.string
		if ddl == nil, case .table = object {
			ddl = try? await one(run, "SELECT DBMS_METADATA.GET_DDL('VIEW', \(lit(name)), \(owner)) FROM dual").rows.first?.first?.string
		}
		// 남의 스키마 테이블은 GET_DDL 권한(SELECT_CATALOG_ROLE)이 없으면 실패 → 컬럼 · 제약 · 인덱스로 만들어 보여 준다
		if ddl == nil, case .table = object {
			ddl = try await builtCreateTable(run, owner: owner, name: name)
		}
		// 남의 스키마 프로시저 · 함수 · 트리거는 GET_DDL 권한이 없어도 실행 권한이 있으면 ALL_SOURCE 로 읽힌다
		if ddl == nil, case .routine = object, ["PROCEDURE", "FUNCTION", "TRIGGER"].contains(type), !schema.isEmpty {
			ddl = try await source(run, schema: schema, name: name, type: type)
		}
		return ddl?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// GET_DDL 을 못 쓸 때의 CREATE TABLE: ALL_TAB_COLUMNS(형식 · 기본값 · NULL · IDENTITY) + 기본 키 · 유일 제약 + 제약이 아닌 인덱스.
	/// 외래 키 · 검사 제약 · 파티션 · 저장소는 빠진다 (맨 위 주석으로 알림). 컬럼이 안 보이면 nil
	private func builtCreateTable(_ run: DBRun, owner: String, name: String) async throws -> String? {
		let cols = try await one(run, columnsSQL("c.owner = \(owner) AND c.table_name = \(lit(name)) AND EXISTS (SELECT 1 FROM all_tables t WHERE t.owner = c.owner AND t.table_name = c.table_name)")).rows
		guard let first = cols.first, let realOwner = first[safe: 0]?.string else { return nil }
		let q = dialect.quote(_:)
		let target = q(realOwner) + "." + q(name)
		var lines: [String] = cols.map { r in
			func s(_ i: Int) -> String? { r[safe: i]?.string }
			var l = q(s(2) ?? "") + " " + Self.typeString(s(3) ?? "", length: Int(s(4) ?? ""), precision: Int(s(5) ?? ""), scale: Int(s(6) ?? ""), charLength: Int(s(7) ?? ""))
			if s(10) == "YES" {
				l += " GENERATED BY DEFAULT AS IDENTITY"
			} else if let d = s(9)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
				l += " DEFAULT " + d
			}
			if s(8) == "N" { l += " NOT NULL" }
			return l
		}
		// 기본 키 · 유일 제약 (이름, 종류, 컬럼 순서대로)
		let cons = try await one(run, """
			SELECT k.constraint_name, k.constraint_type, kc.column_name FROM all_constraints k
			JOIN all_cons_columns kc ON kc.owner = k.owner AND kc.constraint_name = k.constraint_name
			WHERE k.owner = \(lit(realOwner)) AND k.table_name = \(lit(name)) AND k.constraint_type IN ('P', 'U')
			ORDER BY k.constraint_type, k.constraint_name, kc.position
			""").rows
		var order: [String] = []
		var parts: [String: (type: String, cols: [String])] = [:]
		for r in cons {
			guard let n = r[safe: 0]?.string, let c = r[safe: 2]?.string else { continue }
			if parts[n] == nil { order.append(n); parts[n] = (r[safe: 1]?.string ?? "", []) }
			parts[n]?.cols.append(q(c))
		}
		for n in order {
			guard let p = parts[n] else { continue }
			// 시스템이 지은 SYS_C… 이름은 빼고
			lines.append((n.hasPrefix("SYS_C") ? "" : "CONSTRAINT \(q(n)) ") + (p.type == "P" ? "PRIMARY KEY" : "UNIQUE") + " (\(p.cols.joined(separator: ", ")))")
		}
		var out = "-- 이 테이블 정의(DBMS_METADATA)를 읽을 권한이 없어 컬럼 · 키 · 인덱스 정보로 만든 것입니다 (외래 키 · 검사 제약 · 저장소는 빠짐)\n"
		out += "CREATE TABLE \(target) (\n  " + lines.joined(separator: ",\n  ") + "\n)"
		// 제약이 만든 인덱스(이름이 같은 것)는 빼고
		let idx = try await one(run, """
			SELECT i.index_name, i.uniqueness, ic.column_name FROM all_indexes i
			JOIN all_ind_columns ic ON ic.index_owner = i.owner AND ic.index_name = i.index_name
			WHERE i.table_owner = \(lit(realOwner)) AND i.table_name = \(lit(name)) AND i.index_type IN ('NORMAL', 'NORMAL/REV')
			ORDER BY i.index_name, ic.column_position
			""").rows
		var iorder: [String] = []
		var icols: [String: (unique: Bool, cols: [String])] = [:]
		for r in idx {
			guard let n = r[safe: 0]?.string, parts[n] == nil, let c = r[safe: 2]?.string else { continue }
			if icols[n] == nil { iorder.append(n); icols[n] = (r[safe: 1]?.string == "UNIQUE", []) }
			icols[n]?.cols.append(q(c))
		}
		for n in iorder {
			guard let i = icols[n], !n.hasPrefix("SYS_") else { continue }
			out += ";\nCREATE \(i.unique ? "UNIQUE " : "")INDEX \(q(n)) ON \(target) (\(i.cols.joined(separator: ", ")))"
		}
		return out
	}

	/// ALL_SOURCE 의 줄들 → "CREATE OR REPLACE " + 원본 (없으면 nil)
	private func source(_ run: DBRun, schema: String, name: String, type: String) async throws -> String? {
		let rows = try await one(run, "SELECT text FROM all_source WHERE owner = \(lit(schema)) AND name = \(lit(name)) AND type = \(lit(type)) ORDER BY line").rows
		guard !rows.isEmpty else { return nil }
		return "CREATE OR REPLACE " + rows.map { $0.first?.string ?? "" }.joined()
	}

	/// 패키지: 명세 + 본문 (본문은 주인이거나 권한이 있을 때만 보인다)
	private func packageSource(_ run: DBRun, schema: String, name: String) async throws -> String? {
		guard let spec = try await source(run, schema: schema, name: name, type: "PACKAGE") else { return nil }
		let body = try await source(run, schema: schema, name: name, type: "PACKAGE BODY")
		return spec.trimmingCharacters(in: .whitespacesAndNewlines) + "\n/\n\n"
			+ (body?.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n/") ?? "-- 패키지 본문이 없거나 볼 권한이 없습니다")
	}

	/// DBMS_METADATA 세션 설정: 저장소 · 세그먼트 절과 끝 ; 은 늘 빼고, 내보내기면 외래 키와 스키마 이름도 뺀다
	/// (EMIT_SCHEMA 는 오래된 서버에 없을 수 있어 하나씩 따로)
	private func setTransforms(_ run: DBRun, forDump: Bool) async {
		var params = ["'STORAGE', FALSE", "'SEGMENT_ATTRIBUTES', FALSE", "'SQLTERMINATOR', FALSE",
		              "'REF_CONSTRAINTS', \(forDump ? "FALSE" : "TRUE")", "'EMIT_SCHEMA', \(forDump ? "FALSE" : "TRUE")"]
		params = params.map { "BEGIN DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, \($0)); EXCEPTION WHEN OTHERS THEN NULL; END;" }
		_ = try? await run(params.joined(separator: "\n/\n"))
	}

	/// 내보내기: 외래 키 · 스키마 이름 없이 (외래 키는 dumpTrailer 가 맨 끝에)
	func dumpCreate(_ run: DBRun, schema: String, name: String) async throws -> String? {
		// 끝나고 되돌리지 않는다: createStatement 가 부를 때마다 전체 꼴로 다시 맞춘다
		await setTransforms(run, forDump: true)
		var ddl = try? await one(run, "SELECT DBMS_METADATA.GET_DDL('TABLE', \(lit(name)), \(lit(schema))) FROM dual").rows.first?.first?.string
		if ddl == nil { ddl = try? await one(run, "SELECT DBMS_METADATA.GET_DDL('VIEW', \(lit(name)), \(lit(schema))) FROM dual").rows.first?.first?.string }
		return ddl?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// 내보내기 끝: 외래 키(시스템이 지은 SYS_C… 이름은 빼서 새 스키마에서 겹치지 않게)와 IDENTITY 다음 값을 지금 최댓값 뒤로
	func dumpTrailer(_ run: DBRun, schema: String, tables: [String]) async throws -> [String] {
		var out: [String] = []
		let names = Set(tables)
		for t in tables {
			for fk in try await foreignKeys(run, schema: schema, table: t, incoming: false) where names.contains(fk.refTable) && fk.refSchema == schema {
				let cols = fk.columns.map(dialect.quote).joined(separator: ", ")
				let refs = fk.refColumns.map(dialect.quote).joined(separator: ", ")
				let named = fk.name.hasPrefix("SYS_C") ? "" : "CONSTRAINT \(dialect.quote(fk.name)) "
				var s = "ALTER TABLE \(dialect.quote(t)) ADD \(named)FOREIGN KEY (\(cols)) REFERENCES \(dialect.quote(fk.refTable)) (\(refs))"
				if ["CASCADE", "SET NULL"].contains(fk.onDelete.uppercased()) { s += " ON DELETE \(fk.onDelete.uppercased())" }
				out.append(s)
			}
		}
		let ids = try await one(run, "SELECT table_name, column_name, generation_type FROM all_tab_identity_cols WHERE owner = \(lit(schema)) ORDER BY table_name")
		for r in ids.rows where names.contains(r[0].string ?? "") {
			let how = r[safe: 2]?.string == "ALWAYS" ? "ALWAYS" : "BY DEFAULT"
			out.append("ALTER TABLE \(dialect.quote(r[0].string ?? "")) MODIFY \(dialect.quote(r[safe: 1]?.string ?? "")) GENERATED \(how) AS IDENTITY (START WITH LIMIT VALUE)")
		}
		return out
	}

	func indexes(_ run: DBRun, _ table: TableInfo, createSQL: String) async throws -> [IndexInfo] {
		let r = try await one(run, """
			SELECT i.index_name, i.uniqueness, i.index_type, c.column_name, i.distinct_keys,
			       (SELECT 'P' FROM all_constraints k WHERE k.owner = i.table_owner AND k.table_name = i.table_name
			          AND k.index_name = i.index_name AND k.constraint_type = 'P' AND ROWNUM = 1)
			FROM all_indexes i JOIN all_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
			WHERE i.table_owner = \(lit(table.schema)) AND i.table_name = \(lit(table.name))
			ORDER BY i.index_name, c.column_position
			""")
		var list: [IndexInfo] = []
		for row in r.rows {
			let name = row[0].string ?? ""
			let column = row[safe: 3]?.string ?? ""
			if let k = list.firstIndex(where: { $0.name == name }) { list[k].columns.append(column); continue }
			let kind: IndexInfo.Kind = row[safe: 5]?.string == "P" ? .primary : row[safe: 1]?.string == "UNIQUE" ? .unique : .index
			list.append(IndexInfo(name: name, kind: kind, columns: [column], method: row[safe: 2]?.string ?? "",
			                      cardinality: row[safe: 4]?.string.flatMap { Int64($0) }))
		}
		return list.filter { $0.kind == .primary } + list.filter { $0.kind != .primary }
	}

	func foreignKeys(_ run: DBRun, schema: String, table: String, incoming: Bool) async throws -> [ForeignKeyInfo] {
		let filter = incoming ? "r.owner = \(lit(schema)) AND r.table_name = \(lit(table))" : "c.owner = \(lit(schema)) AND c.table_name = \(lit(table))"
		let r = try await one(run, """
			SELECT c.constraint_name, c.owner, c.table_name, cc.column_name, r.owner, r.table_name, rc.column_name, c.delete_rule
			FROM all_constraints c
			JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
			JOIN all_constraints r ON r.owner = c.r_owner AND r.constraint_name = c.r_constraint_name
			JOIN all_cons_columns rc ON rc.owner = r.owner AND rc.constraint_name = r.constraint_name AND rc.position = cc.position
			WHERE c.constraint_type = 'R' AND \(filter)
			ORDER BY c.owner, c.table_name, c.constraint_name, cc.position
			""")
		var list: [ForeignKeyInfo] = []
		for row in r.rows {
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			if let k = list.indices.last, list[k].name == s(0), list[k].table == s(2), list[k].schema == s(1) {
				list[k].columns.append(s(3)); list[k].refColumns.append(s(6))
			} else {
				list.append(ForeignKeyInfo(name: s(0), schema: s(1), table: s(2), columns: [s(3)], refSchema: s(4), refTable: s(5),
				                           refColumns: [s(6)], onDelete: s(7), onUpdate: "NO ACTION"))
			}
		}
		return list
	}

	func structure(_ run: DBRun, _ table: TableInfo) async throws -> (columns: [StructColumn], definitions: [String: String])? {
		let w = "c.owner = \(lit(table.schema)) AND c.table_name = \(lit(table.name))"
		let r = try await one(run, columnsSQL(w))
		guard !r.rows.isEmpty else { return nil }
		let pks = try await one(run, primaryKeysSQL("k.owner = \(lit(table.schema)) AND k.table_name = \(lit(table.name))"))
		let primary = Set(pks.rows.map { ($0[0].string ?? "") + "." + ($0[safe: 1]?.string ?? "") + "." + ($0[safe: 2]?.string ?? "") })
		let list = r.rows.map { row -> StructColumn in
			let info = column(row, primary: primary)
			var s = StructColumn(info: info)
			s.unsigned = false; s.zerofill = false
			s.defaultExpr = info.extra.contains("DEFAULT_GENERATED")
			s.onUpdate = ""
			s.charset = nil; s.collation = nil
			return s
		}
		return (list, [:])
	}

	func schemaDefaults(_ run: DBRun, schema: String) async throws -> (charset: String, collation: String)? { nil }
	func serverDefaults(_ run: DBRun) async throws -> (charset: String, collation: String)? { nil }
	func defaultEngine(_ run: DBRun) async throws -> String? { nil }

	/// 스키마 복제는 아직 없다 (capabilities 로 숨긴다)
	func copyTables(_ run: DBRun, schema: String) async throws -> [CopyTableInfo] { [] }
	func routineNames(_ run: DBRun, schema: String) async throws -> [(kind: RoutineKind, name: String)] {
		try await one(run, """
			SELECT object_type, object_name FROM all_objects
			WHERE owner = \(lit(schema)) AND object_type IN ('PROCEDURE', 'FUNCTION', 'TRIGGER', 'PACKAGE') ORDER BY object_type, object_name
			""").rows.map { r in
			let k: RoutineKind = r[0].string == "FUNCTION" ? .function : r[0].string == "TRIGGER" ? .trigger : r[0].string == "PACKAGE" ? .package : .procedure
			return (k, r[safe: 1]?.string ?? "")
		}
	}

	func contents(_ run: DBRun, schema: String) async -> SchemaContents {
		var c = SchemaContents()
		let rows = (try? await one(run, """
			SELECT object_type, object_name FROM all_objects
			WHERE owner = \(lit(schema)) AND object_type IN ('TABLE', 'VIEW', 'TRIGGER', 'PROCEDURE', 'FUNCTION', 'PACKAGE')
			  AND object_name NOT LIKE 'BIN$%'
			"""))?.rows ?? []
		c.tables = rows.filter { $0[0].string == "TABLE" }.compactMap { $0[safe: 1]?.string }
		c.views = rows.filter { $0[0].string == "VIEW" }.compactMap { $0[safe: 1]?.string }
		c.triggers = rows.filter { $0[0].string == "TRIGGER" }.count
		c.routines = rows.filter { ["PROCEDURE", "FUNCTION", "PACKAGE"].contains($0[0].string ?? "") }.count
		return c
	}

	func tableCount(_ run: DBRun, schema: String) async throws -> Int? {
		Int(try await one(run, """
			SELECT (SELECT COUNT(*) FROM all_tables WHERE owner = \(lit(schema)) AND \(realTables))
			     + (SELECT COUNT(*) FROM all_views WHERE owner = \(lit(schema))) FROM dual
			""").rows.first?.first?.string ?? "")
	}

	func viewDefinition(_ run: DBRun, schema: String, name: String) async throws -> String? {
		try await one(run, "SELECT text FROM all_views WHERE owner = \(lit(schema)) AND view_name = \(lit(name))").rows.first?.first?.string
	}

	func needsClientCopy(_ run: DBRun) async -> Bool { false }

	func connectionInfo(_ run: DBRun) async throws -> (version: String?, user: String?, databases: String?) {
		let v = try await one(run, "SELECT USER, (SELECT COUNT(*) FROM (\(userSchemas))) FROM dual").rows.first
		let banner = (try? await one(run, "SELECT banner FROM v$version WHERE ROWNUM = 1"))?.rows.first?.first?.string
		return (banner, v?[safe: 0]?.string, v?[safe: 1]?.string)
	}

	func databaseNames(_ run: DBRun) async throws -> [String] {
		try await one(run, "SELECT username FROM all_users ORDER BY username").rows.compactMap { $0.first?.string }
	}

	func tableList(_ run: DBRun, schema: String) async throws -> [(name: String, isView: Bool, approxRows: Int?, comment: String)] {
		try await tableStats(run, schema: schema).map { ($0.name, $0.isView, $0.rows.map { Int($0) }, $0.comment) }
	}

	// MARK: 루틴·계정·서버 상태

	private var unsupported: DBError { .message("Oracle 에서는 아직 지원하지 않는 기능입니다.") }

	func routineParameters(_ run: DBRun, schema: String, name: String) async throws -> [(mode: String, name: String, type: String)] {
		try await one(run, """
			SELECT in_out, argument_name, data_type FROM all_arguments
			WHERE owner = \(lit(schema)) AND object_name = \(lit(name)) AND package_name IS NULL AND argument_name IS NOT NULL
			ORDER BY position
			""").rows.map { r in
			let mode = (r[0].string ?? "IN").replacingOccurrences(of: "/", with: "")
			return (mode, r[safe: 1]?.string ?? "", r[safe: 2]?.string ?? "")
		}
	}
	func eventSchedulerOff(_ run: DBRun) async -> Bool { false }
	func accounts(_ run: DBRun) async throws -> [DBAccount] { throw unsupported }

	/// 사용자 계정 보기만: DBA_USERS · DBA_ROLE_PRIVS · DBA_SYS_PRIVS · DBA_TAB_PRIVS.
	/// DBA 뷰를 못 읽으면(SELECT_CATALOG_ROLE 등 없음) ALL_USERS 이름 목록 + 내 계정(USER_*)만
	func accountOverview(_ run: DBRun) async throws -> AccountOverview {
		var o = AccountOverview()
		o.current = try await one(run, "SELECT USER FROM dual").rows.first?.first?.string ?? ""
		o.roleTitle = "역할"; o.databaseTitle = "객체 권한"; o.permissionTitle = "시스템 권한"
		o.roleEmpty = "받은 역할 없음"; o.databaseEmpty = "받은 객체 권한 없음 (자기 스키마 객체는 권한 없이 씀)"; o.permissionEmpty = "받은 시스템 권한 없음"
		let date = "'YYYY-MM-DD HH24:MI:SS'"
		func status(_ s: String) -> String {
			s.replacingOccurrences(of: "EXPIRED(GRACE)", with: "비밀번호 만료 유예").replacingOccurrences(of: "LOCKED(TIMED)", with: "잠김(시간)")
				.replacingOccurrences(of: "EXPIRED", with: "비밀번호 만료").replacingOccurrences(of: "LOCKED", with: "잠김")
				.replacingOccurrences(of: "OPEN", with: "사용 중").replacingOccurrences(of: " & ", with: " · ")
		}
		let auth = ["PASSWORD": "비밀번호", "EXTERNAL": "외부 인증", "GLOBAL": "글로벌 (디렉터리)", "NONE": "스키마 전용 (로그인 없음)"]
		func roleText(_ r: [Value]) -> String {
			(r[safe: 1]?.string ?? "") + (r[safe: 2]?.string == "YES" ? " (ADMIN OPTION)" : "") + (r[safe: 3]?.string == "NO" ? " · 기본 역할 아님" : "")
		}
		do {
			let users = try await one(run, """
				SELECT username, account_status, authentication_type, default_tablespace, temporary_tablespace, profile,
				       TO_CHAR(created, \(date)), TO_CHAR(lock_date, \(date)), TO_CHAR(expiry_date, \(date)), oracle_maintained,
				       TO_CHAR(CAST(last_login AS DATE), \(date))
				  FROM dba_users ORDER BY oracle_maintained, username
				""")
			var roles: [String: [String]] = [:], sys: [String: [String]] = [:], objs: [String: [String: [String]]] = [:]
			for r in try await one(run, "SELECT grantee, granted_role, admin_option, default_role FROM dba_role_privs ORDER BY granted_role").rows {
				if let g = r[safe: 0]?.string { roles[g, default: []].append(roleText(r)) }
			}
			for r in try await one(run, "SELECT grantee, privilege, admin_option FROM dba_sys_privs ORDER BY privilege").rows {
				if let g = r[safe: 0]?.string { sys[g, default: []].append((r[safe: 1]?.string ?? "") + (r[safe: 2]?.string == "YES" ? " (ADMIN OPTION)" : "")) }
			}
			// 객체 권한은 Oracle 이 만든 사용자(SYS 등 수만 줄)는 빼고
			for r in try await one(run, """
				SELECT p.grantee, p.owner, p.table_name, p.privilege, p.grantable FROM dba_tab_privs p
				JOIN dba_users u ON u.username = p.grantee AND u.oracle_maintained = 'N'
				ORDER BY p.owner, p.table_name, p.privilege
				""").rows {
				guard let g = r[safe: 0]?.string, let owner = r[safe: 1]?.string else { continue }
				objs[g, default: [:]][owner, default: []].append("\(r[safe: 3]?.string ?? "") ON \(r[safe: 2]?.string ?? "")" + (r[safe: 4]?.string == "YES" ? " (GRANT OPTION)" : ""))
			}
			for r in users.rows {
				func s(_ i: Int) -> String { r[safe: i]?.string ?? "" }
				var a = AccountInfo(name: s(0), kind: auth[s(2)] ?? s(2))
				a.system = s(9) == "Y"
				a.disabled = s(1) != "OPEN" && !s(1).contains("GRACE")
				a.fields = [.init(label: "상태", value: status(s(1))), .init(label: "인증", value: a.kind),
				            .init(label: "기본 테이블스페이스", value: s(3).ifEmpty("—")), .init(label: "임시 테이블스페이스", value: s(4).ifEmpty("—")),
				            .init(label: "프로파일", value: s(5).ifEmpty("—")), .init(label: "만든 때", value: s(6))]
				if !s(7).isEmpty { a.fields.append(.init(label: "잠긴 때", value: s(7))) }
				if !s(8).isEmpty { a.fields.append(.init(label: "비밀번호 만료", value: s(8))) }
				a.fields.append(.init(label: "마지막 로그인", value: s(10).ifEmpty("—")))
				if a.system { a.fields.append(.init(label: "만든 곳", value: "Oracle (기본 계정)")) }
				a.roles = roles[a.name] ?? []
				a.permissions = sys[a.name] ?? []
				a.databases = (objs[a.name] ?? [:]).sorted { $0.key < $1.key }.map { .init(database: $0.key, user: "", schema: "", roles: $0.value) }
				o.accounts.append(a)
			}
			return o
		} catch {
			// DBA 뷰를 못 읽음: 이름 목록(ALL_USERS) + 내 계정만
			o.note = "다른 사용자의 상태 · 권한을 보려면 DBA 뷰를 읽을 권한(SELECT_CATALOG_ROLE 등)이 있어야 합니다. 지금은 이름과 내 계정만 보입니다."
		}
		let me = try await one(run, """
			SELECT username, account_status, default_tablespace, temporary_tablespace, TO_CHAR(created, \(date)), TO_CHAR(lock_date, \(date)), TO_CHAR(expiry_date, \(date))
			  FROM user_users
			""").rows.first
		let myRoles = try await one(run, "SELECT username, granted_role, admin_option, default_role FROM user_role_privs ORDER BY granted_role").rows.map(roleText)
		let mySys = try await one(run, "SELECT privilege, admin_option FROM user_sys_privs ORDER BY privilege").rows.map { ($0[safe: 0]?.string ?? "") + ($0[safe: 1]?.string == "YES" ? " (ADMIN OPTION)" : "") }
		var myObjs: [String: [String]] = [:]
		for r in try await one(run, "SELECT owner, table_name, privilege, grantable FROM user_tab_privs WHERE grantee = USER ORDER BY owner, table_name, privilege").rows {
			myObjs[r[safe: 0]?.string ?? "", default: []].append("\(r[safe: 2]?.string ?? "") ON \(r[safe: 1]?.string ?? "")" + (r[safe: 3]?.string == "YES" ? " (GRANT OPTION)" : ""))
		}
		for r in try await one(run, "SELECT username, TO_CHAR(created, \(date)), oracle_maintained FROM all_users ORDER BY oracle_maintained, username").rows {
			let name = r[safe: 0]?.string ?? ""
			var a = AccountInfo(name: name, kind: "")
			a.system = r[safe: 2]?.string == "Y"
			if name == o.current, let me {
				func s(_ i: Int) -> String { me[safe: i]?.string ?? "" }
				a.kind = "내 계정"
				a.disabled = s(1) != "OPEN" && !s(1).contains("GRACE")
				a.fields = [.init(label: "상태", value: status(s(1))), .init(label: "기본 테이블스페이스", value: s(2).ifEmpty("—")),
				            .init(label: "임시 테이블스페이스", value: s(3).ifEmpty("—")), .init(label: "만든 때", value: s(4))]
				if !s(5).isEmpty { a.fields.append(.init(label: "잠긴 때", value: s(5))) }
				if !s(6).isEmpty { a.fields.append(.init(label: "비밀번호 만료", value: s(6))) }
				a.roles = myRoles
				a.permissions = mySys
				a.databases = myObjs.sorted { $0.key < $1.key }.map { .init(database: $0.key, user: "", schema: "", roles: $0.value) }
			} else {
				a.kind = a.system ? "Oracle 기본 계정" : "사용자"
				a.fields = [.init(label: "만든 때", value: r[safe: 1]?.string ?? ""), .init(label: "자세히", value: "권한이 없어 볼 수 없음")]
			}
			o.accounts.append(a)
		}
		return o
	}
	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]] { throw unsupported }
	func currentUser(_ run: DBRun) async throws -> String? { try await one(run, "SELECT USER FROM dual").rows.first?.first?.string }
	func grantStatements(_ run: DBRun, account: String) async throws -> [String] { throw unsupported }
	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary { throw unsupported }
	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process] { throw unsupported }
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest] { throw unsupported }
	/// 세션 NLS 설정 (서버 변수 탭은 숨기지만 MCP 같은 곳에서 부를 수 있다)
	func variables(_ run: DBRun) async throws -> [(String, String)] {
		try await one(run, "SELECT parameter, value FROM nls_session_parameters ORDER BY parameter").rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
	}
	func connectionID(_ run: DBRun) async throws -> Int64? {
		try await one(run, "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual").rows.first?.first?.string.flatMap { Int64($0) }
	}
}
