import Foundation

/// MySQL 메타데이터 읽기: information_schema · SHOW (1.x 에서 여러 곳에 있던 쿼리와 결과 풀기를 그대로 모았다)
struct MySQLMeta: SQLMeta {
	/// MariaDB 서버 (information_schema 의 기본값 모양 등이 다르다)
	var mariadb = false
	var dialect: MySQLDialect { MySQLDialect(mariadb: mariadb) }

	var systemSchemas: Set<String> { ["information_schema", "mysql", "performance_schema", "sys"] }

	private func lit(_ s: String) -> String { dialect.literal(.text(s)) }
	private func one(_ run: DBRun, _ sql: String) async throws -> QueryResult { try await run(sql).last ?? QueryResult() }
	private var excluded: String { systemSchemas.map { "'\($0)'" }.joined(separator: ",") }

	func schema(_ run: DBRun) async throws -> SchemaSnapshot? {
		let results = try await run("""
			SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN (\(excluded)) ORDER BY SCHEMA_NAME;
			SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_COMMENT, TABLE_ROWS, ENGINE FROM information_schema.TABLES
			 WHERE TABLE_SCHEMA NOT IN (\(excluded)) ORDER BY TABLE_SCHEMA, TABLE_NAME;
			SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
			  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN (\(excluded)) ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
			""")
		guard results.count >= 3 else { return nil }
		var s = SchemaSnapshot()
		s.databases = results[0].rows.compactMap { $0.first?.string }
		s.tables = results[1].rows.map { r in
			let isView = r[2].string == "VIEW"
			return TableInfo(schema: r[0].string ?? "", name: r[1].string ?? "", isView: isView,
			                 // MySQL 은 뷰의 코멘트에 "VIEW" 라고 넣는다
			                 comment: isView ? "" : (r[3].string ?? ""),
			                 rows: r[4].string.flatMap { Int64($0) }, engine: r[safe: 5]?.string ?? "")
		}
		for r in results[2].rows {
			let id = (r[0].string ?? "") + "." + (r[1].string ?? "")
			var def = r[6].string, extra = r[7].string ?? ""
			if mariadb { (def, extra) = Self.mysqlStyleDefault(def, extra: extra) }
			s.columns[id, default: []].append(ColumnInfo(name: r[2].string ?? "", type: r[3].string ?? "", nullable: r[4].string == "YES",
			                                             key: r[5].string ?? "", defaultValue: def, extra: extra,
			                                             comment: r[8].string ?? ""))
		}
		return s
	}

	func routines(_ run: DBRun) async throws -> [RoutineInfo] {
		let r = try await run("""
			SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, ROUTINE_COMMENT FROM information_schema.ROUTINES
			 WHERE ROUTINE_SCHEMA NOT IN (\(excluded)) ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME;
			SELECT TRIGGER_SCHEMA, TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS
			 WHERE TRIGGER_SCHEMA NOT IN (\(excluded)) ORDER BY TRIGGER_SCHEMA, TRIGGER_NAME;
			SELECT EVENT_SCHEMA, EVENT_NAME, STATUS, EVENT_TYPE, INTERVAL_VALUE, INTERVAL_FIELD, EXECUTE_AT, EVENT_COMMENT FROM information_schema.EVENTS
			 WHERE EVENT_SCHEMA NOT IN (\(excluded)) ORDER BY EVENT_SCHEMA, EVENT_NAME
			""")
		guard r.count >= 3 else { throw DBError.message("루틴 목록을 읽지 못했습니다.") }
		var list: [RoutineInfo] = []
		for row in r[0].rows {
			let kind: RoutineKind = row[safe: 2]?.string == "FUNCTION" ? .function : .procedure
			list.append(RoutineInfo(schema: row[0].string ?? "", name: row[1].string ?? "", kind: kind, comment: row[safe: 3]?.string ?? ""))
		}
		for row in r[1].rows {
			list.append(RoutineInfo(schema: row[0].string ?? "", name: row[1].string ?? "", kind: .trigger,
			                        detail: "\(row[safe: 2]?.string ?? "") \(row[safe: 3]?.string ?? "") · \(row[safe: 4]?.string ?? "")"))
		}
		for row in r[2].rows {
			let recurring = row[safe: 3]?.string == "RECURRING"
			let when = recurring ? "매 \(row[safe: 4]?.string ?? "") \(row[safe: 5]?.string ?? "")" : "한 번 · \(row[safe: 6]?.string ?? "")"
			list.append(RoutineInfo(schema: row[0].string ?? "", name: row[1].string ?? "", kind: .event, detail: when,
			                        enabled: row[safe: 2]?.string == "ENABLED", comment: row[safe: 7]?.string ?? ""))
		}
		return list
	}

	func serverCatalog(_ run: DBRun) async throws -> ServerCatalog {
		var c = ServerCatalog()
		let e = try await one(run, "SHOW ENGINES")
		let iSupport = e.columns.firstIndex { $0.name.caseInsensitiveCompare("Support") == .orderedSame } ?? 1
		c.engines = e.rows.filter { ["YES", "DEFAULT"].contains($0[safe: iSupport]?.string?.uppercased() ?? "") }
			.compactMap { $0.first?.string }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
		let cs = try await one(run, "SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS ORDER BY CHARACTER_SET_NAME")
		c.charsets = cs.rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
		let co = try await one(run, "SELECT COLLATION_NAME, CHARACTER_SET_NAME FROM information_schema.COLLATIONS ORDER BY COLLATION_NAME")
		c.collations = co.rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
		// 전문 검색 파서·n-gram 조각 크기 (없는 서버면 비워 둔다)
		c.fulltextParsers = (try? await one(run, "SELECT PLUGIN_NAME FROM information_schema.PLUGINS WHERE PLUGIN_TYPE = 'FTPARSER' AND PLUGIN_STATUS = 'ACTIVE'"))?
			.rows.compactMap { $0.first?.string } ?? []
		if c.fulltextParsers.contains("ngram") {
			c.ngramTokenSize = (try? await one(run, "SELECT @@ngram_token_size"))?.rows.first?.first?.string.flatMap { Int($0) }
		}
		return c
	}

	func tableStats(_ run: DBRun, schema: String) async throws -> [TableStat] {
		let r = try await one(run, """
			SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT,
			       TABLE_COLLATION, TABLE_COMMENT, COALESCE(UPDATE_TIME, CREATE_TIME)
			  FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(lit(schema)) ORDER BY TABLE_NAME
			""")
		return r.rows.map { v in
			func i(_ k: Int) -> Int64? { v[safe: k]?.string.flatMap { Int64($0) } }
			let isView = v[safe: 1]?.string == "VIEW"
			return TableStat(name: v[0].string ?? "", isView: isView, engine: v[safe: 2]?.string ?? "",
			                 rows: i(3), dataLength: i(4) ?? 0, indexLength: i(5) ?? 0, dataFree: i(6) ?? 0,
			                 autoIncrement: i(7), collation: v[safe: 8]?.string ?? "",
			                 comment: isView ? "" : (v[safe: 9]?.string ?? ""), updated: v[safe: 10]?.string ?? "")
		}
	}

	func tableStatus(_ run: DBRun, _ table: TableInfo) async throws -> TableStatus? {
		let r = try await one(run, """
			SELECT ENGINE, TABLE_COLLATION, TABLE_COMMENT, TABLE_ROWS, AVG_ROW_LENGTH, DATA_LENGTH, INDEX_LENGTH, DATA_FREE,
			       AUTO_INCREMENT, ROW_FORMAT, CREATE_TIME, UPDATE_TIME
			  FROM information_schema.TABLES WHERE TABLE_NAME = \(lit(table.name)) AND TABLE_SCHEMA = \(lit(table.schema))
			""")
		guard let v = r.rows.first else { return nil }
		func s(_ i: Int) -> String { v[safe: i]?.string ?? "" }
		func n(_ i: Int) -> Int64? { v[safe: i]?.string.flatMap { Int64($0) } }
		return TableStatus(engine: s(0), collation: s(1), comment: s(2), approxRows: n(3), avgRowLength: n(4) ?? 0,
		                   dataLength: n(5) ?? 0, indexLength: n(6) ?? 0, dataFree: n(7) ?? 0,
		                   autoIncrement: n(8), rowFormat: s(9), created: s(10), updated: s(11))
	}

	func createStatement(_ run: DBRun, _ object: DBObject, schema: String, name: String) async throws -> String? {
		let target = schema.isEmpty ? dialect.quote(name) : dialect.quote(schema: schema, table: name)
		switch object {
		case .table:
			// 뷰도 SHOW CREATE TABLE 이 CREATE VIEW 를 준다
			return try await one(run, "SHOW CREATE TABLE \(target)").rows.first.flatMap { $0.count > 1 ? $0[1].string : nil }
		case .view:
			return try await one(run, "SHOW CREATE VIEW \(target)").rows.first?[safe: 1]?.string
		case .routine(let kind):
			let r = try await one(run, "SHOW CREATE \(kind.sqlWord) \(target)")
			return r.rows.isEmpty ? nil : r.string(0, kind.createColumn)
		}
	}

	func indexes(_ run: DBRun, _ table: TableInfo, createSQL: String) async throws -> [IndexInfo] {
		let r = try await one(run, "SHOW INDEX FROM \(dialect.quote(table: table))")
		func col(_ name: String) -> Int? { r.columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
		guard let iName = col("Key_name"), let iCol = col("Column_name") else { return [] }
		let iNonUnique = col("Non_unique"), iSub = col("Sub_part"), iType = col("Index_type"), iCard = col("Cardinality")
		var list: [IndexInfo] = []
		for row in r.rows {
			let name = row[iName].string ?? ""
			var column = row[iCol].string ?? "(식)"
			if let iSub, let sub = row[iSub].string { column += "(\(sub))" }
			if let k = list.firstIndex(where: { $0.name == name }) {
				list[k].columns.append(column)
				continue
			}
			let method = iType.flatMap { row[$0].string } ?? ""
			let kind: IndexInfo.Kind = name == "PRIMARY" ? .primary
				: method == "FULLTEXT" ? .fulltext
				: method == "SPATIAL" ? .spatial
				: (iNonUnique.flatMap { row[$0].string } == "0" ? .unique : .index)
			list.append(IndexInfo(name: name, kind: kind, columns: [column], method: method,
			                      cardinality: iCard.flatMap { row[$0].string }.flatMap { Int64($0) }))
		}
		// FULLTEXT 파서: SHOW CREATE TABLE 의 "FULLTEXT KEY `이름` (…) /*!50100 WITH PARSER `ngram` */"
		if list.contains(where: { $0.kind == .fulltext }), !createSQL.isEmpty {
			for line in createSQL.split(separator: "\n") where line.contains("WITH PARSER") {
				guard let name = Self.firstQuoted(line.drop { $0 != "`" }),
				      let r = line.range(of: "WITH PARSER "),
				      let parser = Self.firstQuoted(line[r.upperBound...].drop { $0 != "`" }) else { continue }
				if let k = list.firstIndex(where: { $0.name == name }) { list[k].parser = parser }
			}
		}
		// 기본 키가 맨 위
		return list.filter { $0.kind == .primary } + list.filter { $0.kind != .primary }
	}

	func foreignKeys(_ run: DBRun, schema: String, table: String, incoming: Bool) async throws -> [ForeignKeyInfo] {
		let whereSQL = incoming
			? "k.REFERENCED_TABLE_SCHEMA = \(lit(schema)) AND k.REFERENCED_TABLE_NAME = \(lit(table))"
			: "k.TABLE_SCHEMA = \(lit(schema)) AND k.TABLE_NAME = \(lit(table))"
		let r = try await one(run, """
			SELECT k.CONSTRAINT_NAME, k.TABLE_SCHEMA, k.TABLE_NAME, k.COLUMN_NAME,
			       k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.DELETE_RULE, r.UPDATE_RULE
			  FROM information_schema.KEY_COLUMN_USAGE k
			  JOIN information_schema.REFERENTIAL_CONSTRAINTS r
			    ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
			 WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND \(whereSQL)
			 ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
			""")
		var list: [ForeignKeyInfo] = []
		for row in r.rows {
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			if let k = list.indices.last, list[k].name == s(0), list[k].schema == s(1), list[k].table == s(2) {
				list[k].columns.append(s(3)); list[k].refColumns.append(s(6))
			} else {
				list.append(ForeignKeyInfo(name: s(0), schema: s(1), table: s(2), columns: [s(3)], refSchema: s(4), refTable: s(5),
				                           refColumns: [s(6)], onDelete: s(7), onUpdate: s(8)))
			}
		}
		return list
	}

	func structure(_ run: DBRun, _ table: TableInfo) async throws -> (columns: [StructColumn], definitions: [String: String])? {
		let rs = try await run("""
			SELECT * FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(lit(table.schema)) AND TABLE_NAME = \(lit(table.name)) ORDER BY ORDINAL_POSITION;
			SHOW CREATE TABLE \(dialect.quote(table: table))
			""")
		guard let cols = rs.first else { return nil }
		var list = cols.rows.indices.map { StructColumn(row: cols, $0) }
		guard !list.isEmpty else { return nil }
		if mariadb {
			// 기본값·EXTRA 를 MySQL 모양으로 다시 읽는다
			for i in list.indices {
				let (def, extra) = Self.mysqlStyleDefault(cols.string(i, "COLUMN_DEFAULT"), extra: cols.string(i, "EXTRA") ?? "")
				list[i].defaultValue = def
				let low = extra.lowercased()
				list[i].defaultExpr = low.contains("default_generated")
				list[i].onUpdate = low.range(of: "on update").map { String(extra[$0.lowerBound...]) } ?? ""
			}
		}
		return (list, Self.parseCreate(rs.last?.rows.first?[safe: 1]?.string ?? ""))
	}

	func schemaDefaults(_ run: DBRun, schema: String) async throws -> (charset: String, collation: String)? {
		let r = try await one(run, """
			SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(lit(schema))
			""")
		return (r.rows.first?[safe: 0]?.string ?? "", r.rows.first?[safe: 1]?.string ?? "")
	}

	func serverDefaults(_ run: DBRun) async throws -> (charset: String, collation: String)? {
		let r = try await one(run, "SELECT @@character_set_server, @@collation_server")
		return (r.rows.first?[safe: 0]?.string ?? "", r.rows.first?[safe: 1]?.string ?? "")
	}

	func defaultEngine(_ run: DBRun) async throws -> String? {
		try await one(run, "SELECT @@default_storage_engine").rows.first?.first?.string
	}

	func copyTables(_ run: DBRun, schema: String) async throws -> [CopyTableInfo] {
		let s = lit(schema)
		let t = try await one(run, """
			SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME
			""")
		var metas = t.rows.map { r in
			CopyTableInfo(name: r[0].string ?? "", isView: r[safe: 1]?.string == "VIEW", approxRows: r[safe: 3]?.string.flatMap { Int64($0) } ?? 0)
		}
		let c = try await one(run, """
			SELECT TABLE_NAME, COLUMN_NAME, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME, ORDINAL_POSITION
			""")
		let k = try await one(run, """
			SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(s) AND INDEX_NAME = 'PRIMARY' ORDER BY TABLE_NAME, SEQ_IN_INDEX
			""")
		var cols: [String: [String]] = [:], keys: [String: [String]] = [:]
		for r in c.rows where !(r[safe: 2]?.string?.uppercased().contains("GENERATED") ?? false) {
			cols[r[0].string ?? "", default: []].append(r[1].string ?? "")
		}
		for r in k.rows { keys[r[0].string ?? "", default: []].append(r[1].string ?? "") }
		for i in metas.indices {
			metas[i].columns = cols[metas[i].name] ?? []
			metas[i].primaryKey = keys[metas[i].name] ?? []
		}
		return metas.filter { !$0.isView } + metas.filter(\.isView)
	}

	func routineNames(_ run: DBRun, schema: String) async throws -> [(kind: RoutineKind, name: String)] {
		let s = lit(schema)
		var items: [(kind: RoutineKind, name: String)] = []
		for r in try await one(run, "SELECT ROUTINE_TYPE, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s)").rows {
			items.append((r[safe: 0]?.string == "FUNCTION" ? .function : .procedure, r[safe: 1]?.string ?? ""))
		}
		for r in try await one(run, "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(s)").rows {
			items.append((.trigger, r[safe: 0]?.string ?? ""))
		}
		for r in try await one(run, "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(s)").rows {
			items.append((.event, r[safe: 0]?.string ?? ""))
		}
		return items
	}

	func contents(_ run: DBRun, schema: String) async -> SchemaContents {
		let s = lit(schema)
		var c = SchemaContents()
		let t = (try? await one(run, "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME"))?.rows ?? []
		c.tables = t.filter { $0[safe: 1]?.string != "VIEW" }.compactMap { $0[safe: 0]?.string }
		c.views = t.filter { $0[safe: 1]?.string == "VIEW" }.compactMap { $0[safe: 0]?.string }
		func count(_ sql: String) async -> Int {
			Int((try? await one(run, sql))?.rows.first?.first?.string ?? "") ?? 0
		}
		c.triggers = await count("SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = \(s) OR TRIGGER_SCHEMA = \(s)")
		c.routines = await count("SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s)")
		c.events = await count("SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(s)")
		return c
	}

	func tableCount(_ run: DBRun, schema: String) async throws -> Int? {
		Int(try await one(run, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(lit(schema))").rows.first?.first?.string ?? "")
	}

	func viewDefinition(_ run: DBRun, schema: String, name: String) async throws -> String? {
		try await one(run, "SELECT VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(lit(schema)) AND TABLE_NAME = \(lit(name))").rows.first?.first?.string
	}

	/// 바이너리 로그가 켜져 있고 STATEMENT 형식이면 앱을 거쳐 옮긴다
	func needsClientCopy(_ run: DBRun) async -> Bool {
		let r = try? await one(run, "SELECT @@log_bin, @@binlog_format")
		let logBin = r?.rows.first?[safe: 0]?.string ?? "0"
		let format = (r?.rows.first?[safe: 1]?.string ?? "").uppercased()
		return (logBin == "1" || logBin.uppercased() == "ON") && format == "STATEMENT"
	}

	func connectionInfo(_ run: DBRun) async throws -> (version: String?, user: String?, databases: String?) {
		let row = try await one(run, "SELECT VERSION(), CURRENT_USER(), (SELECT COUNT(*) FROM information_schema.SCHEMATA)").rows.first ?? []
		return (row[safe: 0]?.string, row[safe: 1]?.string, row[safe: 2]?.string)
	}

	func databaseNames(_ run: DBRun) async throws -> [String] {
		try await one(run, "SHOW DATABASES").rows.compactMap { $0.first?.string }
	}

	func tableList(_ run: DBRun, schema: String) async throws -> [(name: String, isView: Bool, approxRows: Int?, comment: String)] {
		let r = try await one(run, """
			SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT FROM information_schema.TABLES
			 WHERE TABLE_SCHEMA = \(lit(schema)) ORDER BY TABLE_NAME
			""")
		return r.rows.map { row in (row[0].string ?? "", row[1].string == "VIEW", row[2].string.flatMap { Int($0) }, row[3].string ?? "") }
	}

	// MARK: MariaDB

	/// MariaDB 의 information_schema 기본값을 MySQL 모양으로:
	/// 글자는 따옴표째('abc') → abc, DEFAULT NULL 은 글자 'NULL' → nil, current_timestamp() → CURRENT_TIMESTAMP,
	/// 식 기본값은 EXTRA 에 DEFAULT_GENERATED (MySQL 8 처럼), on update current_timestamp() → on update CURRENT_TIMESTAMP
	static func mysqlStyleDefault(_ d: String?, extra: String) -> (String?, String) {
		var extra = extra.replacingOccurrences(of: #"(?i)current_timestamp\(\)"#, with: "CURRENT_TIMESTAMP", options: .regularExpression)
		guard let d else { return (nil, extra) }
		if d == "NULL" { return (nil, extra) }
		if d.count >= 2, d.hasPrefix("'"), d.hasSuffix("'") {
			return (String(d.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"), extra)
		}
		if Double(d) != nil { return (d, extra) }
		// 그 밖은 식
		let expr = d.replacingOccurrences(of: #"(?i)^current_timestamp\(\)$"#, with: "CURRENT_TIMESTAMP", options: .regularExpression)
		if !extra.lowercased().contains("default_generated") { extra = extra.isEmpty ? "DEFAULT_GENERATED" : "DEFAULT_GENERATED " + extra }
		return (expr, extra)
	}

	// MARK: SHOW CREATE 글 읽기

	/// "`a``b` …" → a`b (맨 앞 백틱 이름)
	static func firstQuoted(_ s: Substring) -> String? {
		guard s.first == "`" else { return nil }
		var out = ""
		var i = s.index(after: s.startIndex)
		while i < s.endIndex {
			if s[i] == "`" {
				let n = s.index(after: i)
				if n < s.endIndex, s[n] == "`" { out.append("`"); i = s.index(after: n); continue }
				return out
			}
			out.append(s[i])
			i = s.index(after: i)
		}
		return nil
	}

	/// "  `name` int unsigned NOT NULL," 줄들에서 이름 → 정의
	static func parseCreate(_ ddl: String) -> [String: String] {
		var out: [String: String] = [:]
		for line in ddl.split(separator: "\n") {
			let t = line.drop { $0 == " " }
			guard t.first == "`" else { continue }
			var name = ""
			var i = t.index(after: t.startIndex)
			var closed = false
			while i < t.endIndex {
				let ch = t[i]
				if ch == "`" {
					let next = t.index(after: i)
					if next < t.endIndex, t[next] == "`" { name.append("`"); i = t.index(after: next); continue }
					i = next; closed = true; break
				}
				name.append(ch)
				i = t.index(after: i)
			}
			guard closed else { continue }
			var rest = t[i...].trimmingCharacters(in: .whitespaces)
			if rest.hasSuffix(",") { rest.removeLast() }
			out[name] = rest
		}
		return out
	}
}
