import Foundation

/// SQLite 메타데이터 읽기: sqlite_master 와 pragma_* 표 함수. DB 는 하나(main)
struct SQLiteMeta: SQLMeta {
	static let schemaName = "main"
	var dialect: SQLiteDialect { SQLiteDialect() }
	var systemSchemas: Set<String> { [] }

	private func lit(_ s: String) -> String { dialect.literal(.text(s)) }
	private func one(_ run: DBRun, _ sql: String) async throws -> QueryResult { try await run(sql).last ?? QueryResult() }
	/// 사용자 테이블·뷰 (sqlite_ 로 시작하는 내부 표는 뺀다)
	private var userObjects: String { userObjects("") }
	private func userObjects(_ p: String) -> String { "\(p)type IN ('table','view') AND \(p)name NOT LIKE 'sqlite\\_%' ESCAPE '\\'" }
	private let columnsSQL = "SELECT m.name, p.name, p.type, p.\"notnull\", p.dflt_value, p.pk, p.hidden, m.sql FROM sqlite_master m JOIN pragma_table_xinfo(m.name) p"

	/// 한 줄의 컬럼 정보 (m.name, p.name, type, notnull, dflt, pk, hidden, 테이블 sql)
	private struct Col {
		var table, name, type: String
		var notNull: Bool, defaultValue: String?, pk: Int, hidden: Int, tableSQL: String
		init(_ r: [Value]) {
			table = r[0].string ?? ""; name = r[1].string ?? ""; type = r[2].string ?? ""
			notNull = r[3].string == "1"; defaultValue = r[4].string; pk = Int(r[5].string ?? "") ?? 0
			hidden = Int(r[6].string ?? "") ?? 0; tableSQL = r[safe: 7]?.string ?? ""
		}
		/// INTEGER PRIMARY KEY AUTOINCREMENT
		var autoIncrement: Bool { pk > 0 && type.uppercased() == "INTEGER" && tableSQL.uppercased().contains("AUTOINCREMENT") }
		/// 기본값을 MySQL 모양으로: 'abc' → abc, NULL → nil, 숫자 그대로, 그 밖은 식 (EXTRA 에 DEFAULT_GENERATED)
		var normalizedDefault: (String?, String) {
			var (d, extra) = MySQLMeta.mysqlStyleDefault(defaultValue, extra: "")
			if autoIncrement { extra = extra.isEmpty ? "auto_increment" : extra + " auto_increment" }
			if hidden == 2 { extra += (extra.isEmpty ? "" : " ") + "VIRTUAL GENERATED" }
			if hidden == 3 { extra += (extra.isEmpty ? "" : " ") + "STORED GENERATED" }
			if d == "CURRENT_TIMESTAMP" || d == "CURRENT_DATE" || d == "CURRENT_TIME" { d = d?.uppercased() }
			return (d, extra)
		}
	}

	func schema(_ run: DBRun) async throws -> SchemaSnapshot? {
		let rs = try await run("""
			SELECT name, type FROM sqlite_master WHERE \(userObjects) ORDER BY name;
			\(columnsSQL) WHERE \(userObjects("m.")) ORDER BY m.name, p.cid
			""")
		guard rs.count >= 2 else { return nil }
		var s = SchemaSnapshot()
		s.databases = [Self.schemaName]
		s.tables = rs[0].rows.map { r in
			TableInfo(schema: Self.schemaName, name: r[0].string ?? "", isView: r[safe: 1]?.string == "view", comment: "", rows: nil)
		}
		for r in rs[1].rows {
			let c = Col(r)
			let (def, extra) = c.normalizedDefault
			s.columns[Self.schemaName + "." + c.table, default: []].append(
				ColumnInfo(name: c.name, type: c.type.lowercased(), nullable: !c.notNull && c.pk == 0, key: c.pk > 0 ? "PRI" : "",
				           defaultValue: def, extra: extra, comment: ""))
		}
		return s
	}

	/// 트리거만 (프로시저·함수·이벤트가 없다)
	func routines(_ run: DBRun) async throws -> [RoutineInfo] {
		let r = try await one(run, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
		return r.rows.map { row in
			RoutineInfo(schema: Self.schemaName, name: row[0].string ?? "", kind: .trigger,
			            detail: Self.triggerTiming(row[safe: 2]?.string ?? "") + " · " + (row[safe: 1]?.string ?? ""))
		}
	}

	/// "CREATE TRIGGER x BEFORE UPDATE OF a ON t" → "BEFORE UPDATE"
	static func triggerTiming(_ sql: String) -> String {
		guard let m = sql.firstMatch(of: /(?i)\b(BEFORE|AFTER|INSTEAD\s+OF)?\s*(INSERT|UPDATE|DELETE)\b/) else { return "" }
		let when = m.1.map { String($0).uppercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) } ?? "BEFORE"
		return when + " " + String(m.2).uppercased()
	}

	func serverCatalog(_ run: DBRun) async throws -> ServerCatalog { ServerCatalog() }

	/// 행 수·크기는 읽지 않는다 (COUNT 는 큰 파일에서 느리다)
	func tableStats(_ run: DBRun, schema: String) async throws -> [TableStat] {
		try await one(run, "SELECT name, type FROM sqlite_master WHERE \(userObjects) ORDER BY name").rows.map { v in
			TableStat(name: v[0].string ?? "", isView: v[safe: 1]?.string == "view", engine: "", rows: nil, dataLength: 0, indexLength: 0,
			          dataFree: 0, autoIncrement: nil, collation: "", comment: "", updated: "")
		}
	}

	func tableStatus(_ run: DBRun, _ table: TableInfo) async throws -> TableStatus? {
		var s = TableStatus()
		// 자동 증가 다음 값 (AUTOINCREMENT 테이블만 sqlite_sequence 에 있다)
		if let seq = (try? await one(run, "SELECT seq FROM sqlite_sequence WHERE name = \(lit(table.name))"))?.rows.first?.first?.string,
		   let n = Int64(seq) { s.autoIncrement = n + 1 }
		return s
	}

	func createStatement(_ run: DBRun, _ object: DBObject, schema: String, name: String) async throws -> String? {
		let type: String
		switch object {
		case .table: type = "type IN ('table','view')"
		case .view: type = "type = 'view'"
		case .routine(let k): guard k == .trigger || k == .view else { return nil }; type = "type = '\(k == .view ? "view" : "trigger")'"
		}
		guard let sql = try await one(run, "SELECT sql FROM sqlite_master WHERE \(type) AND name = \(lit(name))").rows.first?.first?.string else { return nil }
		guard case .table = object else { return sql }
		// 인덱스는 따로 선 문장 → 테이블 CREATE 뒤에 붙인다 (MySQL 의 SHOW CREATE TABLE 처럼 내보내기·CREATE 보기에 같이)
		let idx = (try? await one(run, "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = \(lit(name)) AND sql IS NOT NULL ORDER BY name"))?
			.rows.compactMap { $0.first?.string } ?? []
		return ([sql] + idx).joined(separator: ";\n")
	}

	func indexes(_ run: DBRun, _ table: TableInfo, createSQL: String) async throws -> [IndexInfo] {
		let t = lit(table.name)
		let rs = try await run("""
			SELECT il.name, il."unique", il.origin, ii.name FROM pragma_index_list(\(t)) il JOIN pragma_index_info(il.name) ii ORDER BY il.seq DESC, ii.seqno;
			SELECT name FROM pragma_table_info(\(t)) WHERE pk > 0 ORDER BY pk
			""")
		var list: [IndexInfo] = []
		for row in rs.first?.rows ?? [] {
			let origin = row[safe: 2]?.string ?? ""
			let name = origin == "pk" ? "PRIMARY" : (row[0].string ?? "")
			let column = row[safe: 3]?.string ?? "(식)"
			if let k = list.firstIndex(where: { $0.name == name }) { list[k].columns.append(column); continue }
			let kind: IndexInfo.Kind = origin == "pk" ? .primary : (row[safe: 1]?.string == "1" ? .unique : .index)
			list.append(IndexInfo(name: name, kind: kind, columns: [column], method: "", cardinality: nil))
		}
		// INTEGER PRIMARY KEY 는 rowid 라 인덱스 목록에 없다 → 만들어 넣는다
		let pk = rs.count > 1 ? rs[1].rows.compactMap { $0.first?.string } : []
		if !pk.isEmpty, !list.contains(where: { $0.kind == .primary }) {
			list.append(IndexInfo(name: "PRIMARY", kind: .primary, columns: pk, method: "", cardinality: nil))
		}
		return list.filter { $0.kind == .primary } + list.filter { $0.kind != .primary }
	}

	func foreignKeys(_ run: DBRun, schema: String, table: String, incoming: Bool) async throws -> [ForeignKeyInfo] {
		let sql = incoming
			? "SELECT m.name, f.id, f.\"table\", f.\"from\", f.\"to\", f.on_delete, f.on_update FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f WHERE m.type = 'table' AND f.\"table\" = \(lit(table)) COLLATE NOCASE ORDER BY m.name, f.id, f.seq"
			: "SELECT \(lit(table)), f.id, f.\"table\", f.\"from\", f.\"to\", f.on_delete, f.on_update FROM pragma_foreign_key_list(\(lit(table))) f ORDER BY f.id, f.seq"
		let r = try await one(run, sql)
		var list: [ForeignKeyInfo] = []
		for row in r.rows {
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			let name = "fk_\(s(1))"
			if let k = list.indices.last, list[k].name == name, list[k].table == s(0) {
				list[k].columns.append(s(3)); list[k].refColumns.append(s(4))
			} else {
				list.append(ForeignKeyInfo(name: name, schema: Self.schemaName, table: s(0), columns: [s(3)], refSchema: Self.schemaName,
				                           refTable: s(2), refColumns: [s(4)], onDelete: s(5), onUpdate: s(6)))
			}
		}
		return list
	}

	func structure(_ run: DBRun, _ table: TableInfo) async throws -> (columns: [StructColumn], definitions: [String: String])? {
		let r = try await one(run, "\(columnsSQL) WHERE m.name = \(lit(table.name)) ORDER BY p.cid")
		guard !r.rows.isEmpty else { return nil }
		let defs = Self.parseCreate(r.rows.first?[safe: 7]?.string ?? "")
		let list = r.rows.map { row -> StructColumn in
			let c = Col(row)
			let (def, extra) = c.normalizedDefault
			var s = StructColumn(info: ColumnInfo(name: c.name, type: c.type, nullable: !c.notNull, key: c.pk > 0 ? "PRI" : "",
			                                      defaultValue: def, extra: extra, comment: ""))
			s.unsigned = false; s.zerofill = false
			s.nullable = !c.notNull
			s.defaultValue = def
			s.defaultExpr = extra.contains("DEFAULT_GENERATED")
			s.autoIncrement = c.autoIncrement
			s.onUpdate = ""
			s.generated = c.hidden == 2 ? "VIRTUAL" : c.hidden == 3 ? "STORED" : nil
			if s.generated != nil, let d = defs[c.name] { s.generationExpr = Self.generationExpr(d) }
			s.comment = ""; s.charset = nil
			s.collation = defs[c.name].flatMap { $0.firstMatch(of: /(?i)\bCOLLATE\s+(\w+)/).map { String($0.1) } }
			s.key = c.pk > 0 ? "PRI" : ""
			return s
		}
		return (list, defs)
	}

	func schemaDefaults(_ run: DBRun, schema: String) async throws -> (charset: String, collation: String)? { nil }
	func serverDefaults(_ run: DBRun) async throws -> (charset: String, collation: String)? { nil }
	func defaultEngine(_ run: DBRun) async throws -> String? { nil }

	func copyTables(_ run: DBRun, schema: String) async throws -> [CopyTableInfo] {
		let rs = try await run("""
			SELECT name, type FROM sqlite_master WHERE \(userObjects) ORDER BY name;
			\(columnsSQL) WHERE \(userObjects("m.")) ORDER BY m.name, p.cid
			""")
		var metas = (rs.first?.rows ?? []).map { CopyTableInfo(name: $0[0].string ?? "", isView: $0[safe: 1]?.string == "view", approxRows: 0) }
		var cols: [String: [String]] = [:], keys: [String: [(Int, String)]] = [:]
		for row in rs.count > 1 ? rs[1].rows : [] {
			let c = Col(row)
			if c.hidden == 0 { cols[c.table, default: []].append(c.name) }
			if c.pk > 0 { keys[c.table, default: []].append((c.pk, c.name)) }
		}
		for i in metas.indices {
			metas[i].columns = cols[metas[i].name] ?? []
			metas[i].primaryKey = (keys[metas[i].name] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
		}
		return metas.filter { !$0.isView } + metas.filter(\.isView)
	}

	func routineNames(_ run: DBRun, schema: String) async throws -> [(kind: RoutineKind, name: String)] {
		try await one(run, "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").rows.map { (.trigger, $0[0].string ?? "") }
	}

	func contents(_ run: DBRun, schema: String) async -> SchemaContents {
		var c = SchemaContents()
		let t = (try? await one(run, "SELECT name, type FROM sqlite_master WHERE \(userObjects) OR type = 'trigger' ORDER BY name"))?.rows ?? []
		c.tables = t.filter { $0[safe: 1]?.string == "table" }.compactMap { $0[0].string }
		c.views = t.filter { $0[safe: 1]?.string == "view" }.compactMap { $0[0].string }
		c.triggers = t.filter { $0[safe: 1]?.string == "trigger" }.count
		return c
	}

	func tableCount(_ run: DBRun, schema: String) async throws -> Int? {
		Int(try await one(run, "SELECT COUNT(*) FROM sqlite_master WHERE \(userObjects)").rows.first?.first?.string ?? "")
	}

	/// CREATE VIEW 이름 AS 뒤
	func viewDefinition(_ run: DBRun, schema: String, name: String) async throws -> String? {
		guard let sql = try await createStatement(run, .view, schema: schema, name: name),
		      let r = sql.range(of: #"(?i)\bAS\b"#, options: .regularExpression) else { return nil }
		return sql[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
	}

	func needsClientCopy(_ run: DBRun) async -> Bool { false }

	func connectionInfo(_ run: DBRun) async throws -> (version: String?, user: String?, databases: String?) {
		let v = try await one(run, "SELECT sqlite_version(), (SELECT COUNT(*) FROM sqlite_master WHERE \(userObjects))").rows.first
		return (v?[safe: 0]?.string.map { "SQLite " + $0 }, nil, "1")
	}

	func databaseNames(_ run: DBRun) async throws -> [String] { [Self.schemaName] }

	func tableList(_ run: DBRun, schema: String) async throws -> [(name: String, isView: Bool, approxRows: Int?, comment: String)] {
		try await one(run, "SELECT name, type FROM sqlite_master WHERE \(userObjects) ORDER BY name").rows.map {
			($0[0].string ?? "", $0[safe: 1]?.string == "view", nil, "")
		}
	}

	// MARK: 루틴·계정·서버 상태 (SQLite 에는 없다 — 그 화면은 capabilities 로 숨긴다)

	private var unsupported: DBError { .message("SQLite 에는 없는 기능입니다.") }
	func routineParameters(_ run: DBRun, schema: String, name: String) async throws -> [(mode: String, name: String, type: String)] { [] }
	func eventSchedulerOff(_ run: DBRun) async -> Bool { false }
	func accounts(_ run: DBRun) async throws -> [DBAccount] { throw unsupported }
	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]] { throw unsupported }
	func currentUser(_ run: DBRun) async throws -> String? { nil }
	func grantStatements(_ run: DBRun, account: String) async throws -> [String] { throw unsupported }
	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary { throw unsupported }
	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process] { throw unsupported }
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest] { throw unsupported }
	/// PRAGMA 몇 개 (서버 변수 탭은 숨기지만 MCP 같은 곳에서 부를 수 있다)
	func variables(_ run: DBRun) async throws -> [(String, String)] {
		var out: [(String, String)] = []
		for p in ["journal_mode", "foreign_keys", "page_size", "page_count", "encoding", "user_version"] {
			if let v = (try? await one(run, "PRAGMA \(p)"))?.rows.first?.first?.string { out.append((p, v)) }
		}
		return out
	}
	func connectionID(_ run: DBRun) async throws -> Int64? { nil }

	// MARK: CREATE 글 읽기

	/// CREATE TABLE 의 괄호 안을 맨 위 쉼표로 나눠 컬럼 이름 → 정의 ("x" INTEGER NOT NULL → INTEGER NOT NULL). 제약 줄은 뺀다
	static func parseCreate(_ ddl: String) -> [String: String] {
		guard let open = ddl.firstIndex(of: "("), let close = ddl.lastIndex(of: ")"), open < close else { return [:] }
		var parts: [String] = [], cur = "", depth = 0
		var quote: Character?
		for ch in ddl[ddl.index(after: open)..<close] {
			if let q = quote { cur.append(ch); if ch == q || (q == "[" && ch == "]") { quote = nil }; continue }
			switch ch {
			case "'", "\"", "`", "[": quote = ch; cur.append(ch)
			case "(": depth += 1; cur.append(ch)
			case ")": depth -= 1; cur.append(ch)
			case "," where depth == 0: parts.append(cur); cur = ""
			default: cur.append(ch)
			}
		}
		parts.append(cur)
		var out: [String: String] = [:]
		for p in parts {
			let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let (name, rest) = splitName(t) else { continue }
			if ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].contains(name.uppercased()), !t.hasPrefix("\""), !t.hasPrefix("`"), !t.hasPrefix("[") { continue }
			out[name] = rest.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return out
	}

	/// 맨 앞 이름("a""b", `a`, [a], a)과 나머지
	static func splitName(_ t: String) -> (String, Substring)? {
		guard let f = t.first else { return nil }
		let close: Character? = f == "\"" ? "\"" : f == "`" ? "`" : f == "[" ? "]" : nil
		if let close {
			var name = "", i = t.index(after: t.startIndex)
			while i < t.endIndex {
				if t[i] == close {
					let n = t.index(after: i)
					if close != "]", n < t.endIndex, t[n] == close { name.append(close); i = t.index(after: n); continue }
					return (name, t[n...])
				}
				name.append(t[i]); i = t.index(after: i)
			}
			return nil
		}
		let end = t.firstIndex { $0.isWhitespace } ?? t.endIndex
		return (String(t[..<end]), t[end...])
	}

	/// 정의에서 AS ( … ) 의 식
	static func generationExpr(_ def: String) -> String {
		guard let r = def.range(of: #"(?i)\bAS\s*\("#, options: .regularExpression) else { return "" }
		var depth = 1, out = ""
		for ch in def[r.upperBound...] {
			if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 { break } }
			out.append(ch)
		}
		return out
	}
}
