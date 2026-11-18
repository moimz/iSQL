import Foundation

/// SQLite 문법. DB 는 파일 하나(main)이고, 서버 관리·계정·엔진·문자셋 같은 것은 없다 (그 메뉴는 capabilities 로 숨긴다).
/// 없는 기능을 부르면 아무것도 하지 않는 주석을 돌려준다
struct SQLiteDialect: SQLDialect {
	var kind: SQLKind { .sqlite }
	var syntax: SQLSyntax { .sqlite }
	private let none = "-- SQLite 에는 없습니다"

	// MARK: 감싸기

	func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String {
		let ok = name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
			&& name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
		return ok && !reserved.contains(name.uppercased()) ? name : quote(name)
	}

	/// '' 로만 (\ 는 그냥 글자), 바이너리는 X'…'
	func literal(_ v: Value) -> String {
		switch v {
		case .null: "NULL"
		case .bytes(let d): "X'" + d.map { String(format: "%02X", $0) }.joined() + "'"
		case .text(let s): "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
		}
	}

	// MARK: JSON (JSON1 함수)

	func jsonPath(_ column: String, _ path: String) -> String { "json_extract(\(column), \(literal(.text(path))))" }
	func jsonSearch(_ column: String, _ pattern: String, path: String?) -> String {
		"EXISTS (SELECT 1 FROM json_tree(\(column)\(path.map { ", " + literal(.text($0)) } ?? "")) WHERE atom LIKE \(literal(.text(pattern))))"
	}
	func jsonContains(_ column: String, _ candidate: String, path: String?) -> String {
		"EXISTS (SELECT 1 FROM json_each(\(column)\(path.map { ", " + literal(.text($0)) } ?? "")) WHERE value = json_extract(\(literal(.text(candidate))), '$'))"
	}
	func jsonContainsPath(_ column: String, _ path: String) -> String { "(json_type(\(column), \(literal(.text(path)))) IS NOT NULL)" }

	/// SQLite 의 LIKE 는 기본 이스케이프 글자가 없다 → 그대로 (% _ 는 와일드카드)
	func likeEscaped(_ s: String) -> String { s }

	// MARK: EXPLAIN

	func explain(_ body: String) -> String { "EXPLAIN QUERY PLAN \(body)" }
	func explainTree(_ body: String) -> String? { nil }

	// MARK: 기본 문장

	func paged(_ sql: String, limit: Int, offset: Int?) -> String { sql + " LIMIT \(limit)" + (offset.map { " OFFSET \($0)" } ?? "") }
	/// DB 가 하나라 바꿀 것이 없다 (빈 문장)
	func use(_ schema: String) -> String { "" }
	var beginTransaction: String { "BEGIN" }
	var commit: String { "COMMIT" }
	var rollback: String { "ROLLBACK" }
	func foreignKeyChecks(_ on: Bool) -> String? { "PRAGMA foreign_keys = \(on ? "ON" : "OFF")" }
	var dumpPrologue: [String] { ["PRAGMA foreign_keys = OFF", "BEGIN TRANSACTION"] }
	var dumpEpilogue: [String] { ["COMMIT", "PRAGMA foreign_keys = ON"] }

	/// UPDATE·DELETE 에 LIMIT 을 못 붙인다 → 그 행의 rowid 하나로
	func updateRow(_ table: String, sets: [String], condition: String) -> String {
		"UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE rowid IN (SELECT rowid FROM \(table) WHERE \(condition) LIMIT 1)"
	}
	func deleteRow(_ table: String, condition: String) -> String {
		"DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE \(condition) LIMIT 1)"
	}
	func insertRow(_ table: String, columns: [String], values: [String]) -> String {
		columns.isEmpty ? "INSERT INTO \(table) DEFAULT VALUES"
			: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
	}
	func byteLength(_ expr: String) -> String { "length(CAST(\(expr) AS BLOB))" }
	func blobPeek(_ column: String, over: Int, keep: Int) -> String {
		"CASE WHEN length(CAST(\(column) AS BLOB)) > \(over) THEN substr(CAST(\(column) AS BLOB), 1, \(keep)) ELSE \(column) END"
	}

	func isAuthFailure(_ error: Error) -> Bool { false }
	func isServerError(_ error: Error) -> Bool { if case .sqlite = error as? SQLiteError { return true }; return false }
}

// MARK: - 구조 바꾸기

extension SQLiteDialect {
	func createDatabase(_ name: String, charset: String, collation: String) -> String { none }
	func dropDatabase(_ name: String) -> String { none }

	/// 엔진·문자셋·코멘트는 없다. 자동 증가 기본 키 컬럼이 있으면 그 줄에 PRIMARY KEY 가 들어 있어 따로 쓰지 않는다
	func createTable(schema: String, name: String, columns: [String], primaryKey: [String],
	                 engine: String, charset: String, collation: String, comment: String) -> String {
		var lines = columns.map { "  " + $0 }
		if !primaryKey.isEmpty, !columns.contains(where: { $0.contains("PRIMARY KEY") }) {
			lines.append("  PRIMARY KEY (\(primaryKey.joined(separator: ", ")))")
		}
		return "CREATE TABLE \(quote(schema)).\(quote(name)) (\n" + lines.joined(separator: ",\n") + "\n)"
	}
	func createTable(schema: String, name: String, definitions: [String]) -> String {
		"CREATE TABLE \(quote(schema)).\(quote(name)) (\n  " + definitions.joined(separator: ",\n  ") + "\n)"
	}
	func autoIncrementKeyColumn(_ name: String) -> String { "\(quote(name)) INTEGER PRIMARY KEY AUTOINCREMENT" }
	/// LIKE 가 없다 → 컬럼만 같은 빈 테이블 (제약은 옮기지 않는다)
	func createTableLike(_ target: String, like source: String) -> String { "CREATE TABLE \(target) AS SELECT * FROM \(source) WHERE 0" }
	func createViewHead(_ target: String) -> String { "CREATE VIEW \(target)" }
	/// 한 문장에 하나씩
	func drop(_ targets: [String], views: Bool) -> String { targets.map { (views ? "DROP VIEW " : "DROP TABLE ") + $0 }.joined(separator: ";\n") }
	func dropIfExists(_ target: String, view: Bool) -> String { (view ? "DROP VIEW IF EXISTS " : "DROP TABLE IF EXISTS ") + target }
	func truncate(_ target: String) -> String { "DELETE FROM " + target }
	/// RENAME TO 뒤에는 DB 를 붙이지 않는다
	func renameTables(_ pairs: [(from: String, to: String)]) -> String {
		pairs.map { "ALTER TABLE \($0.from) RENAME TO \(Self.unqualified($0.to))" }.joined(separator: ";\n")
	}
	func retargetSchema(_ ddl: String, from: String, to: String) -> String { ddl }
	func rewriteViewDefinition(_ ddl: String, name: String, from: String, to: String) -> String { ddl }
	func retargetCreateTable(_ ddl: String, name: String, to target: String) -> String? { nil }

	func dropRoutine(_ kind: RoutineKind, _ target: String) -> String { kind == .trigger ? "DROP TRIGGER \(target)" : none }
	func setEventEnabled(_ target: String, _ on: Bool) -> String { none }

	func columnDefinition(_ c: StructColumn) -> String {
		var s = c.type
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, c.takesLength { s += "(\(len))" }
		if let co = c.collation, !co.isEmpty { s += " COLLATE \(co)" }
		if let g = c.generated { s += " GENERATED ALWAYS AS (\(c.generationExpr)) \(g)" }
		if !c.nullable { s += " NOT NULL" }
		if let d = c.defaultValue, c.generated == nil { s += " DEFAULT " + defaultValueSQL(d, expr: c.defaultExpr, numeric: c.isNumeric) }
		return s
	}
	/// 자동 증가는 INTEGER PRIMARY KEY AUTOINCREMENT (SQLite 는 그 꼴만 된다)
	func columnDefinition(_ c: NewColumn) -> String {
		if c.autoIncrement { return quote(c.name) + " INTEGER PRIMARY KEY AUTOINCREMENT" }
		var s = quote(c.name) + " " + c.type
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, NewColumn.takesLength.contains(c.type) { s += "(\(len))" }
		if !(c.nullable && !c.primary) { s += " NOT NULL" }
		let d = c.defaultValue.trimmingCharacters(in: .whitespaces)
		if !d.isEmpty { s += " DEFAULT " + defaultValueSQL(c.defaultValue, expr: false, numeric: c.isNumeric) }
		return s
	}
	func defaultValueSQL(_ d: String, expr: Bool, numeric: Bool) -> String {
		let t = d.trimmingCharacters(in: .whitespaces)
		let up = t.uppercased()
		if up == "NULL" || up == "CURRENT_TIMESTAMP" || up == "CURRENT_DATE" || up == "CURRENT_TIME" { return up }
		if expr { return t.hasPrefix("(") ? t : "(\(t))" }
		if numeric, Double(t) != nil { return t }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return t }
		return literal(.text(d))
	}

	/// ALTER 는 한 문장에 절 하나. 인덱스 절({TABLE} 자리)은 따로 선 문장으로 (ON 뒤에는 DB 를 붙이지 않는다).
	/// 문장이 여럿이면 한 트랜잭션으로 (인덱스 고치기 = 지우고 만들기가 중간에 실패해도 그대로 남게)
	func alterTable(_ target: String, _ clauses: [String], multiline: Bool) -> String {
		let list = clauses.map { c in
			c.contains("{TABLE}") || c.hasPrefix("DROP INDEX") || c.hasPrefix("--") ? c.replacingOccurrences(of: "{TABLE}", with: Self.unqualified(target))
				: "ALTER TABLE \(target) \(c)"
		}
		let sep = multiline ? ";\n" : "; "
		return list.filter { !$0.hasPrefix("--") }.count > 1 ? (["BEGIN"] + list + ["COMMIT"]).joined(separator: sep) : list.joined(separator: sep)
	}
	func dropColumn(_ name: String) -> String { "DROP COLUMN \(quote(name))" }
	/// 위치는 정할 수 없다 (늘 맨 뒤)
	func addColumn(_ name: String, definition: String, position: ColumnPosition?) -> String { "ADD COLUMN \(quote(name)) \(definition)" }
	/// 이름만 바꿀 수 있다 (정의를 바꾸려면 테이블을 새로 만들어야 한다 — 구조 편집기가 막는다)
	func changeColumn(_ old: String, to name: String, definition: String, position: ColumnPosition?) -> String {
		old == name ? "-- SQLite 는 컬럼 정의를 바꿀 수 없습니다: \(old)" : "RENAME COLUMN \(quote(old)) TO \(quote(name))"
	}
	func engineClause(_ engine: String) -> String { none }
	func charsetClause(_ charset: String, collation: String, convert: Bool) -> String { none }
	func tableCommentClause(_ comment: String) -> String { none }
	func autoIncrementClause(_ n: Int64) -> String { none }

	func indexPart(_ s: String) -> String {
		if s.hasPrefix("(") { return s }
		return quote(s)
	}
	func dropIndexClause(_ index: IndexInfo) -> String {
		index.kind == .primary ? "-- SQLite 는 기본 키를 따로 지울 수 없습니다" : "DROP INDEX \(quote(index.name))"
	}
	/// CREATE [UNIQUE] INDEX 이름 ON 테이블 (컬럼) — 테이블 자리는 alterTable 이 채운다
	func addIndexClause(kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		let n = name.trimmingCharacters(in: .whitespaces)
		let cols = columns.map(indexPart).joined(separator: ", ")
		switch kind {
		case .primary: return "-- SQLite 는 기본 키를 나중에 더할 수 없습니다"
		case .unique: return "CREATE UNIQUE INDEX \(quote(n.isEmpty ? "idx_" + columns.joined(separator: "_") : n)) ON {TABLE} (\(cols))"
		default: return "CREATE INDEX \(quote(n.isEmpty ? "idx_" + columns.joined(separator: "_") : n)) ON {TABLE} (\(cols))"
		}
	}
	func addForeignKeyClause(_ fk: ForeignKeyInfo, schema: String) -> String { "-- SQLite 는 외래 키를 나중에 더할 수 없습니다" }
	func dropForeignKeyClause(_ name: String) -> String { "-- SQLite 는 외래 키를 따로 지울 수 없습니다" }

	/// "main"."이름" → "이름"
	static func unqualified(_ s: String) -> String {
		if let r = s.range(of: "\".\"", options: .backwards) { return "\"" + s[r.upperBound...] }
		return s
	}
}

// MARK: - 루틴·계정·서버 (SQLite 는 트리거만)

extension SQLiteDialect {
	func routineTemplate(_ kind: RoutineKind, table: String?) -> String {
		switch kind {
		case .trigger: "CREATE TRIGGER \"new_trigger\" AFTER INSERT ON \(quote(table ?? "테이블"))\nBEGIN\n\tSELECT 1;\nEND"
		case .view: "CREATE VIEW \"new_view\" AS\nSELECT 1"
		default: none
		}
	}
	func callRoutine(_ kind: RoutineKind, _ target: String, args: [String], outs: [String]) -> [String] { [none] }
	func outVariable(_ name: String) -> String { name }
	func cleanDefinition(_ s: String) -> String {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		while t.hasSuffix(";"), !t.uppercased().hasSuffix("END;") { t.removeLast(); t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
		return t
	}
	func stripDefiner(_ s: String) -> String { s }
	/// OR REPLACE 가 없다 → 지우고 다시 (같은 이름의 뷰)
	func createOrReplace(_ s: String) -> String {
		guard let n = definedName(s, .view) else { return s }
		return "DROP VIEW IF EXISTS \(quote(n));\n" + s
	}
	func definedName(_ s: String, _ k: RoutineKind) -> String? {
		let pattern = #"\b"# + k.sqlWord + #"\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(?:"[^"]+"|`[^`]+`|\w+)\s*\.\s*)?("(?:[^"]|"")+"|`[^`]+`|\[[^\]]+\]|\w+)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
		var n = String(s[r])
		if n.hasPrefix("\"") { n = String(n.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") }
		else if n.hasPrefix("`") || n.hasPrefix("[") { n = String(n.dropFirst().dropLast()) }
		return n
	}

	func accountName(user: String, host: String) -> String { user }
	func createUser(_ account: String, password: String) -> String { none }
	func dropUser(_ account: String) -> String { none }
	func setPassword(_ account: String, _ password: String) -> String { none }
	func setAccountLocked(_ account: String, _ locked: Bool) -> String { none }
	func grantTarget(database: String?) -> String { "" }
	func grant(_ privileges: [String], on target: String, to account: String, grantOption: Bool) -> String { none }
	func grantAll(on target: String, to account: String) -> String { none }
	func revoke(_ privileges: [String], on target: String, from account: String) -> String { none }
	func revokeAll(on target: String, from account: String) -> String { none }
	func revokeGrantOption(on target: String, from account: String) -> String { none }
	func createDatabaseIfNotExists(_ name: String) -> String { none }
	func kill(_ id: Int64, connection: Bool) -> String { none }
}
