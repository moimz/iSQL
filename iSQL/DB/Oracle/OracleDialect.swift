import Foundation

/// Oracle 문법. "데이터베이스" 자리는 스키마(= 사용자)다. 서버 관리·계정·엔진·문자셋은 아직 없다 (capabilities 로 숨긴다).
/// 없는 기능을 부르면 아무것도 하지 않는 주석을 돌려준다
struct OracleDialect: SQLDialect {
	var kind: SQLKind { .oracle }
	var syntax: SQLSyntax { .oracle }
	private let none = "-- Oracle 에서는 아직 지원하지 않습니다"

	// MARK: 감싸기

	func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

	/// 따옴표 없는 이름은 대문자로 바뀌므로, 대문자·숫자·_ $ # 로만 된 이름만 그대로 쓴다
	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String {
		let ok = name.first.map { $0.isASCII && $0.isUppercase } == true
			&& name.allSatisfy { $0 == "_" || $0 == "$" || $0 == "#" || ($0.isASCII && ($0.isUppercase || $0.isNumber)) }
		return ok && !reserved.contains(name) ? name : quote(name)
	}

	/// '' 로만 (\ 는 그냥 글자), 바이너리는 HEXTORAW('…')
	func literal(_ v: Value) -> String {
		switch v {
		case .null: "NULL"
		case .bytes(let d): "HEXTORAW('" + d.map { String(format: "%02X", $0) }.joined() + "')"
		case .text(let s): "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
		}
	}

	// MARK: JSON (필터 줄의 JSON 칸은 숨긴다 — 쿼리 패널에서 쓸 때를 위한 기본 꼴)

	func jsonPath(_ column: String, _ path: String) -> String { "JSON_VALUE(\(column), \(literal(.text(path))))" }
	func jsonSearch(_ column: String, _ pattern: String, path: String?) -> String { "\(column) LIKE \(literal(.text(pattern)))" }
	func jsonContains(_ column: String, _ candidate: String, path: String?) -> String { "\(column) LIKE \(literal(.text("%" + candidate + "%")))" }
	func jsonContainsPath(_ column: String, _ path: String) -> String {
		"CASE WHEN JSON_EXISTS(\(column), \(literal(.text(path)))) THEN 1 ELSE 0 END"
	}

	/// Oracle 의 LIKE 는 기본 이스케이프 글자가 없다 → 그대로 (% _ 는 와일드카드)
	func likeEscaped(_ s: String) -> String { s }

	// MARK: EXPLAIN

	/// 계획을 PLAN_TABLE 에 넣고 DBMS_XPLAN 으로 읽는다 (결과는 마지막 것)
	func explain(_ body: String) -> String { "EXPLAIN PLAN FOR \(body);\nSELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY())" }
	func explainTree(_ body: String) -> String? { nil }

	// MARK: 기본 문장

	/// 12c 이상: OFFSET … ROWS FETCH NEXT … ROWS ONLY
	func paged(_ sql: String, limit: Int, offset: Int?) -> String {
		if let offset, offset > 0 { return sql + " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY" }
		return sql + " FETCH FIRST \(limit) ROWS ONLY"
	}
	func use(_ schema: String) -> String { "ALTER SESSION SET CURRENT_SCHEMA = \(quote(schema))" }
	/// 연결(OracleConnection)이 알아듣고 자동 커밋을 끈다 (서버에는 보내지 않는다). COMMIT · ROLLBACK 뒤 다시 켠다
	var beginTransaction: String { "START TRANSACTION" }
	var commit: String { "COMMIT" }
	var rollback: String { "ROLLBACK" }
	func foreignKeyChecks(_ on: Bool) -> String? { nil }
	var dumpPrologue: [String] { [] }
	var dumpEpilogue: [String] { [] }

	/// UPDATE·DELETE 에 LIMIT 이 없다 → ROWNUM = 1 로 한 행만
	func updateRow(_ table: String, sets: [String], condition: String) -> String {
		"UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(condition) AND ROWNUM = 1"
	}
	func deleteRow(_ table: String, condition: String) -> String { "DELETE FROM \(table) WHERE \(condition) AND ROWNUM = 1" }
	func insertRow(_ table: String, columns: [String], values: [String]) -> String {
		columns.isEmpty ? "INSERT INTO \(table) VALUES (DEFAULT)"
			: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
	}
	/// 여러 행 VALUES 는 23ai 부터라 INSERT ALL (12c · 19c 에서도 된다)
	func insertRows(_ table: String, columns: String, rows: [String]) -> String {
		"INSERT ALL\n" + rows.map { "  INTO \(table) (\(columns)) VALUES \($0)" }.joined(separator: "\n") + "\nSELECT 1 FROM dual"
	}
	func byteLength(_ expr: String) -> String { "DBMS_LOB.GETLENGTH(\(expr))" }
	/// LOB 은 정의해서 통째로 받는다 (앞부분만 읽기는 아직)
	func blobPeek(_ column: String, over: Int, keep: Int) -> String { column }

	func isAuthFailure(_ error: Error) -> Bool {
		if case .server(let code, _) = error as? OracleError { return code == 1017 }
		return false
	}
	func isServerError(_ error: Error) -> Bool { if case .server = error as? OracleError { return true }; return false }
}

// MARK: - 구조 바꾸기

extension OracleDialect {
	func createDatabase(_ name: String, charset: String, collation: String) -> String { none }
	func dropDatabase(_ name: String) -> String { none }

	/// 엔진·문자셋은 없고, 코멘트는 COMMENT ON TABLE 로 따로
	func createTable(schema: String, name: String, columns: [String], primaryKey: [String],
	                 engine: String, charset: String, collation: String, comment: String) -> String {
		var lines = columns.map { "  " + $0 }
		if !primaryKey.isEmpty, !columns.contains(where: { $0.contains("PRIMARY KEY") }) {
			lines.append("  PRIMARY KEY (\(primaryKey.joined(separator: ", ")))")
		}
		var sql = "CREATE TABLE \(quote(schema)).\(quote(name)) (\n" + lines.joined(separator: ",\n") + "\n)"
		if !comment.isEmpty { sql += ";\nCOMMENT ON TABLE \(quote(schema)).\(quote(name)) IS \(literal(.text(comment)))" }
		return sql
	}
	func createTable(schema: String, name: String, definitions: [String]) -> String {
		"CREATE TABLE \(quote(schema)).\(quote(name)) (\n  " + definitions.joined(separator: ",\n  ") + "\n)"
	}
	func autoIncrementKeyColumn(_ name: String) -> String { "\(quote(name)) NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY" }
	/// LIKE 가 없다 → 컬럼만 같은 빈 테이블 (제약은 옮기지 않는다)
	func createTableLike(_ target: String, like source: String) -> String { "CREATE TABLE \(target) AS SELECT * FROM \(source) WHERE 1 = 0" }
	func createViewHead(_ target: String) -> String { "CREATE VIEW \(target)" }
	/// 한 문장에 하나씩. 지운 테이블은 휴지통(RECYCLEBIN)으로 간다 (PURGE 하지 않는다)
	func drop(_ targets: [String], views: Bool) -> String { targets.map { (views ? "DROP VIEW " : "DROP TABLE ") + $0 }.joined(separator: ";\n") }
	/// 23ai 부터 IF EXISTS 를 받는다
	func dropIfExists(_ target: String, view: Bool) -> String { (view ? "DROP VIEW IF EXISTS " : "DROP TABLE IF EXISTS ") + target }
	func truncate(_ target: String) -> String { "TRUNCATE TABLE " + target }
	/// RENAME TO 뒤에는 스키마를 붙이지 않는다
	func renameTables(_ pairs: [(from: String, to: String)]) -> String {
		pairs.map { "ALTER TABLE \($0.from) RENAME TO \(Self.unqualified($0.to))" }.joined(separator: ";\n")
	}
	func retargetSchema(_ ddl: String, from: String, to: String) -> String {
		ddl.replacingOccurrences(of: quote(from) + ".", with: quote(to) + ".")
	}
	func rewriteViewDefinition(_ ddl: String, name: String, from: String, to: String) -> String { retargetSchema(ddl, from: from, to: to) }
	func retargetCreateTable(_ ddl: String, name: String, to target: String) -> String? { nil }

	func dropRoutine(_ kind: RoutineKind, _ target: String) -> String {
		switch kind {
		case .procedure, .function, .trigger, .view: "DROP \(kind.sqlWord) \(target)"
		case .event, .package: none
		}
	}
	func setEventEnabled(_ target: String, _ on: Bool) -> String { none }

	/// 타입(길이) DEFAULT … NOT NULL (Oracle 은 DEFAULT 가 NOT NULL 보다 앞)
	func columnDefinition(_ c: StructColumn) -> String {
		var s = c.type
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, !c.type.contains("(") { s += "(\(len))" }
		if c.autoIncrement { s += " GENERATED BY DEFAULT AS IDENTITY" }
		if let d = c.defaultValue, !c.autoIncrement { s += " DEFAULT " + defaultValueSQL(d, expr: c.defaultExpr, numeric: c.isNumeric) }
		if !c.nullable { s += " NOT NULL" }
		return s
	}
	func columnDefinition(_ c: NewColumn) -> String {
		var s = quote(c.name) + " " + Self.oracleType(c.type)
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, NewColumn.takesLength.contains(c.type) || ["VARCHAR2", "NUMBER", "RAW", "NVARCHAR2"].contains(c.type) { s += "(\(len))" }
		if c.autoIncrement { s += " GENERATED BY DEFAULT AS IDENTITY" }
		let d = c.defaultValue.trimmingCharacters(in: .whitespaces)
		if !d.isEmpty, !c.autoIncrement { s += " DEFAULT " + defaultValueSQL(c.defaultValue, expr: false, numeric: c.isNumeric) }
		if !(c.nullable && !c.primary) { s += " NOT NULL" }
		return s
	}
	/// MySQL 형식 이름을 Oracle 형식으로 (새 테이블 시트가 MySQL 목록을 쓰는 동안)
	static func oracleType(_ t: String) -> String {
		switch t.uppercased() {
		case "VARCHAR": "VARCHAR2"
		case "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT", "DECIMAL", "NUMERIC": "NUMBER"
		case "DOUBLE": "BINARY_DOUBLE"
		case "FLOAT": "BINARY_FLOAT"
		case "TEXT", "MEDIUMTEXT", "LONGTEXT", "TINYTEXT": "CLOB"
		case "BLOB", "MEDIUMBLOB", "LONGBLOB", "TINYBLOB": "BLOB"
		case "DATETIME": "DATE"
		case "VARBINARY", "BINARY": "RAW"
		default: t.uppercased()
		}
	}
	func defaultValueSQL(_ d: String, expr: Bool, numeric: Bool) -> String {
		let t = d.trimmingCharacters(in: .whitespaces)
		let up = t.uppercased()
		if ["NULL", "SYSDATE", "SYSTIMESTAMP", "CURRENT_TIMESTAMP", "CURRENT_DATE", "USER", "SYS_GUID()"].contains(up) { return up }
		if expr { return t }
		if numeric, Double(t) != nil { return t }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return t }
		return literal(.text(d))
	}

	/// 절마다 따로 ALTER TABLE 문장. {TABLE} 이 든 절은 그 자리에 테이블을 넣은 문장 그대로
	func alterTable(_ target: String, _ clauses: [String], multiline: Bool) -> String {
		let list = clauses.filter { !$0.hasPrefix("--") }.map { c in
			c.hasPrefix("CREATE ") || c.hasPrefix("DROP INDEX") || c.hasPrefix("COMMENT ")
				? c.replacingOccurrences(of: "{TABLE}", with: target)
				: "ALTER TABLE \(target) " + c.replacingOccurrences(of: "{TABLE}", with: target)
		}
		return list.joined(separator: multiline ? ";\n" : "; ")
	}
	func dropColumn(_ name: String) -> String { "DROP COLUMN \(quote(name))" }
	/// 위치는 정할 수 없다 (늘 맨 뒤)
	func addColumn(_ name: String, definition: String, position: ColumnPosition?) -> String { "ADD (\(quote(name)) \(definition))" }
	/// 이름이 바뀌면 RENAME COLUMN 다음 MODIFY (두 문장)
	func changeColumn(_ old: String, to name: String, definition: String, position: ColumnPosition?) -> String {
		let modify = "MODIFY (\(quote(name)) \(definition))"
		return old == name ? modify : "RENAME COLUMN \(quote(old)) TO \(quote(name)); ALTER TABLE {TABLE} \(modify)"
	}
	func engineClause(_ engine: String) -> String { "--" }
	func charsetClause(_ charset: String, collation: String, convert: Bool) -> String { "--" }
	func tableCommentClause(_ comment: String) -> String { "COMMENT ON TABLE {TABLE} IS \(literal(.text(comment)))" }
	func autoIncrementClause(_ n: Int64) -> String { "--" }

	func indexPart(_ s: String) -> String { s.hasPrefix("(") ? s : quote(s) }
	func dropIndexClause(_ index: IndexInfo) -> String {
		index.kind == .primary ? "DROP PRIMARY KEY" : "DROP INDEX \(quote(index.name))"
	}
	func addIndexClause(kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		let n = name.trimmingCharacters(in: .whitespaces)
		let cols = columns.map(indexPart).joined(separator: ", ")
		let idx = quote(n.isEmpty ? "IDX_" + columns.joined(separator: "_").uppercased() : n)
		switch kind {
		case .primary: return "ADD PRIMARY KEY (\(cols))"
		case .unique: return "CREATE UNIQUE INDEX \(idx) ON {TABLE} (\(cols))"
		default: return "CREATE INDEX \(idx) ON {TABLE} (\(cols))"
		}
	}
	/// ON UPDATE 는 없다. ON DELETE 는 CASCADE · SET NULL 만
	func addForeignKeyClause(_ fk: ForeignKeyInfo, schema: String) -> String {
		let ref = fk.refSchema.isEmpty || fk.refSchema == schema ? quote(fk.refTable) : quote(schema: fk.refSchema, table: fk.refTable)
		var s = "ADD CONSTRAINT \(quote(fk.name)) FOREIGN KEY (\(fk.columns.map(quote).joined(separator: ", "))) REFERENCES \(ref) (\(fk.refColumns.map(quote).joined(separator: ", ")))"
		if ["CASCADE", "SET NULL"].contains(fk.onDelete.uppercased()) { s += " ON DELETE \(fk.onDelete.uppercased())" }
		return s
	}
	func dropForeignKeyClause(_ name: String) -> String { "DROP CONSTRAINT \(quote(name))" }

	/// "SCHEMA"."이름" → "이름"
	static func unqualified(_ s: String) -> String {
		if let r = s.range(of: "\".\"", options: .backwards) { return "\"" + s[r.upperBound...] }
		return s
	}
}

// MARK: - 루틴·계정·서버

extension OracleDialect {
	func routineTemplate(_ kind: RoutineKind, table: String?) -> String {
		switch kind {
		case .procedure: "CREATE OR REPLACE PROCEDURE \"NEW_PROCEDURE\" AS\nBEGIN\n\tNULL;\nEND;"
		case .function: "CREATE OR REPLACE FUNCTION \"NEW_FUNCTION\" RETURN NUMBER AS\nBEGIN\n\tRETURN 1;\nEND;"
		case .trigger: "CREATE OR REPLACE TRIGGER \"NEW_TRIGGER\"\nAFTER INSERT ON \(table.map(quote) ?? "테이블")\nFOR EACH ROW\nBEGIN\n\tNULL;\nEND;"
		case .view: "CREATE OR REPLACE VIEW \"NEW_VIEW\" AS\nSELECT 1 AS X FROM DUAL"
		case .event, .package: none
		}
	}
	func callRoutine(_ kind: RoutineKind, _ target: String, args: [String], outs: [String]) -> [String] {
		switch kind {
		case .function: ["SELECT \(target)(\(args.joined(separator: ", "))) FROM DUAL"]
		default: ["BEGIN \(target)(\(args.joined(separator: ", "))); END;"]
		}
	}
	func outVariable(_ name: String) -> String { ":" + name }
	/// PL/SQL 은 끝의 END; 가 필요하다 → / 줄만 뗀다
	func cleanDefinition(_ s: String) -> String {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.hasSuffix("/") { t.removeLast(); t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
		return t
	}
	func stripDefiner(_ s: String) -> String { s }
	func createOrReplace(_ s: String) -> String {
		guard let r = s.range(of: #"(?i)^\s*CREATE\s+(?!OR\s+REPLACE)"#, options: .regularExpression) else { return s }
		return s.replacingCharacters(in: r, with: "CREATE OR REPLACE ")
	}
	func definedName(_ s: String, _ k: RoutineKind) -> String? {
		let pattern = #"\b"# + k.sqlWord + #"\s+(?:(?:"[^"]+"|\w+)\s*\.\s*)?("(?:[^"]|"")+"|\w+)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
		let n = String(s[r])
		return n.hasPrefix("\"") ? String(n.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") : n.uppercased()
	}

	func accountName(user: String, host: String) -> String { quote(user) }
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
