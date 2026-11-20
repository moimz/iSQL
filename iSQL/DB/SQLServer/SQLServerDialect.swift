import Foundation

/// SQL Server (T-SQL) 문법. 데이터베이스 > 스키마 > 테이블 세 단계를 앱의 "DB > 테이블" 두 단계에 이렇게 맞춘다 (사용자 2026-11-20):
/// TableInfo.schema = 데이터베이스, TableInfo.name = dbo 테이블은 이름만 · 다른 스키마는 "스키마.이름". SQL 에서는 [DB].[스키마].[이름].
/// 서버 관리·계정·엔진·문자셋은 아직 없다 (capabilities 로 숨긴다). 없는 기능을 부르면 아무것도 하지 않는 주석을 돌려준다
struct SQLServerDialect: SQLDialect {
	var kind: SQLKind { .sqlserver }
	var syntax: SQLSyntax { .sqlServer }
	private let none = "-- SQL Server 에서는 아직 지원하지 않습니다"

	static let defaultSchema = "dbo"

	/// 앱의 테이블 이름 → (스키마, 이름). 점이 없으면 dbo
	static func split(_ name: String) -> (schema: String, table: String) {
		guard let dot = name.firstIndex(of: ".") else { return (defaultSchema, name) }
		return (String(name[..<dot]), String(name[name.index(after: dot)...]))
	}
	/// (스키마, 이름) → 앱의 테이블 이름
	static func displayName(schema: String, table: String) -> String {
		schema.caseInsensitiveCompare(defaultSchema) == .orderedSame ? table : schema + "." + table
	}

	// MARK: 감싸기

	func quote(_ name: String) -> String { "[" + name.replacingOccurrences(of: "]", with: "]]") + "]" }
	/// [DB].[스키마].[이름] (DB 가 비면 [스키마].[이름])
	func quote(schema db: String, table: String) -> String {
		let (s, t) = Self.split(table)
		return (db.isEmpty ? "" : quote(db) + ".") + quote(s) + "." + quote(t)
	}
	func quoteLocal(_ table: String) -> String { quote(schema: "", table: table) }
	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String {
		let ok = name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
			&& name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
		return ok && !reserved.contains(name.uppercased()) ? name : quote(name)
	}

	/// N'…' (유니코드, '' 로), 바이너리는 0x…
	func literal(_ v: Value) -> String {
		switch v {
		case .null: "NULL"
		case .bytes(let d): d.isEmpty ? "0x" : "0x" + d.map { String(format: "%02X", $0) }.joined()
		case .text(let s): "N'" + s.replacingOccurrences(of: "'", with: "''") + "'"
		}
	}

	// MARK: JSON (필터 줄의 JSON 칸은 숨긴다)

	func jsonPath(_ column: String, _ path: String) -> String { "JSON_VALUE(\(column), \(literal(.text(path))))" }
	func jsonSearch(_ column: String, _ pattern: String, path: String?) -> String { "\(column) LIKE \(literal(.text(pattern)))" }
	func jsonContains(_ column: String, _ candidate: String, path: String?) -> String { "\(column) LIKE \(literal(.text("%" + candidate + "%")))" }
	func jsonContainsPath(_ column: String, _ path: String) -> String {
		"CASE WHEN JSON_PATH_EXISTS(\(column), \(literal(.text(path)))) = 1 THEN 1 ELSE 0 END"
	}

	/// LIKE 의 [ 는 글자 묶음이라 [[] 로 (% _ 는 와일드카드 그대로)
	func likeEscaped(_ s: String) -> String { s.replacingOccurrences(of: "[", with: "[[]") }

	// MARK: EXPLAIN

	/// 예상 실행계획 (실행하지 않음). SET SHOWPLAN_TEXT 는 배치에 혼자 있어야 해서 GO 로 나눈다 (연결이 배치마다 따로 보낸다)
	func explain(_ body: String) -> String { "SET SHOWPLAN_TEXT ON\nGO\n\(body)\nGO\nSET SHOWPLAN_TEXT OFF" }
	func explainTree(_ body: String) -> String? { nil }

	// MARK: 기본 문장

	/// OFFSET … FETCH 는 ORDER BY 가 있어야 한다 → 맨 바깥에 ORDER BY 가 없으면 ORDER BY (SELECT NULL)
	func paged(_ sql: String, limit: Int, offset: Int?) -> String {
		let base = Self.hasTopLevelOrderBy(sql) ? sql : sql + " ORDER BY (SELECT NULL)"
		return base + " OFFSET \(offset ?? 0) ROWS FETCH NEXT \(limit) ROWS ONLY"
	}

	/// 괄호·따옴표 밖에 ORDER BY 가 있는지
	static func hasTopLevelOrderBy(_ sql: String) -> Bool {
		let u = Array(sql.uppercased().utf16)
		var depth = 0, i = 0
		var quote: UInt16 = 0
		while i < u.count {
			let c = u[i]
			if quote != 0 { if c == quote { quote = 0 }; i += 1; continue }
			switch c {
			case 39, 34: quote = c
			case 91: quote = 93
			case 40: depth += 1
			case 41: depth -= 1
			case 45 where i + 1 < u.count && u[i + 1] == 45:
				while i < u.count && u[i] != 10 { i += 1 }
				continue
			case 79 where depth == 0:   // O
				let rest = String(utf16CodeUnits: Array(u[i..<min(u.count, i + 12)]), count: min(12, u.count - i))
				let before = i == 0 ? 32 : u[i - 1]
				if !(before >= 65 && before <= 90) && before != 95, rest.range(of: #"^ORDER\s+BY\b"#, options: .regularExpression) != nil { return true }
			default: break
			}
			i += 1
		}
		return false
	}

	func use(_ schema: String) -> String { "USE \(quote(schema))" }
	var beginTransaction: String { "BEGIN TRANSACTION" }
	var commit: String { "COMMIT" }
	var rollback: String { "ROLLBACK" }
	func foreignKeyChecks(_ on: Bool) -> String? { nil }
	var dumpPrologue: [String] { ["SET NOCOUNT ON"] }
	var dumpEpilogue: [String] { [] }

	/// UPDATE·DELETE 에 LIMIT 대신 TOP (1)
	func updateRow(_ table: String, sets: [String], condition: String) -> String {
		"UPDATE TOP (1) \(table) SET \(sets.joined(separator: ", ")) WHERE \(condition)"
	}
	func deleteRow(_ table: String, condition: String) -> String { "DELETE TOP (1) FROM \(table) WHERE \(condition)" }
	func insertRow(_ table: String, columns: [String], values: [String]) -> String {
		columns.isEmpty ? "INSERT INTO \(table) DEFAULT VALUES"
			: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
	}
	func byteLength(_ expr: String) -> String { "DATALENGTH(\(expr))" }
	/// TEXT · NTEXT · IMAGE · XML · 공간 형식은 정렬할 수 없다(오류 306). 바이너리는 정렬해도 뜻이 없어 막는다 (다른 DB 와 같게)
	func sortExpression(_ column: String, type: String) -> String? {
		let t = type.lowercased()
		let base = t.split(separator: "(").first.map(String.init) ?? t
		if ["text", "ntext", "image", "xml", "geography", "geometry", "hierarchyid", "binary", "varbinary", "sql_variant", "timestamp", "rowversion"].contains(base) { return nil }
		return column
	}
	/// 큰 값의 앞부분만: SUBSTRING(바이너리, 1, keep)
	func blobPeek(_ column: String, over: Int, keep: Int) -> String {
		"CASE WHEN DATALENGTH(\(column)) > \(over) THEN SUBSTRING(\(column), 1, \(keep)) ELSE \(column) END"
	}

	func isAuthFailure(_ error: Error) -> Bool {
		if case .server(let n, _, _, _, _, _) = error as? TDSError { return n == 18456 }
		return false
	}
	func isServerError(_ error: Error) -> Bool { if case .server = error as? TDSError { return true }; return false }
}

// MARK: - 구조 바꾸기

extension SQLServerDialect {
	func createDatabase(_ name: String, charset: String, collation: String) -> String {
		"CREATE DATABASE \(quote(name))" + (collation.isEmpty ? "" : " COLLATE \(collation)")
	}
	func dropDatabase(_ name: String) -> String { "DROP DATABASE \(quote(name))" }

	func createTable(schema: String, name: String, columns: [String], primaryKey: [String],
	                 engine: String, charset: String, collation: String, comment: String) -> String {
		var lines = columns.map { "  " + $0 }
		if !primaryKey.isEmpty, !columns.contains(where: { $0.contains("PRIMARY KEY") }) {
			lines.append("  PRIMARY KEY (\(primaryKey.joined(separator: ", ")))")
		}
		return "CREATE TABLE \(quote(schema: schema, table: name)) (\n" + lines.joined(separator: ",\n") + "\n)"
	}
	func createTable(schema: String, name: String, definitions: [String]) -> String {
		"CREATE TABLE \(quote(schema: schema, table: name)) (\n  " + definitions.joined(separator: ",\n  ") + "\n)"
	}
	func autoIncrementKeyColumn(_ name: String) -> String { "\(quote(name)) INT IDENTITY(1,1) PRIMARY KEY" }
	/// LIKE 가 없다 → 컬럼만 같은 빈 테이블 (SELECT INTO, 제약은 옮기지 않는다)
	func createTableLike(_ target: String, like source: String) -> String { "SELECT * INTO \(target) FROM \(source) WHERE 1 = 0" }
	/// CREATE VIEW 앞에는 DB 를 붙일 수 없다 → [스키마].[이름] 만
	func createViewHead(_ target: String) -> String { "CREATE VIEW \(Self.withoutDatabase(target))" }
	func drop(_ targets: [String], views: Bool) -> String { (views ? "DROP VIEW " : "DROP TABLE ") + targets.joined(separator: ", ") }
	func dropIfExists(_ target: String, view: Bool) -> String { (view ? "DROP VIEW IF EXISTS " : "DROP TABLE IF EXISTS ") + target }
	func truncate(_ target: String) -> String { "TRUNCATE TABLE " + target }
	/// sp_rename 은 그 DB 안에서 돌아야 한다 → [DB].sys.sp_rename N'[스키마].[이름]', N'새 이름'
	func renameTables(_ pairs: [(from: String, to: String)]) -> String {
		pairs.map { p in
			let parts = Self.parts(p.from)
			let db = parts.count == 3 ? quote(parts[0]) + "." : ""
			let obj = parts.suffix(2).map(quote).joined(separator: ".")
			return "EXEC \(db)sys.sp_rename \(literal(.text(obj))), \(literal(.text(Self.parts(p.to).last ?? p.to)))"
		}.joined(separator: ";\n")
	}
	func retargetSchema(_ ddl: String, from: String, to: String) -> String {
		ddl.replacingOccurrences(of: quote(from) + ".", with: quote(to) + ".")
	}
	func rewriteViewDefinition(_ ddl: String, name: String, from: String, to: String) -> String { retargetSchema(ddl, from: from, to: to) }
	func retargetCreateTable(_ ddl: String, name: String, to target: String) -> String? { nil }

	func dropRoutine(_ kind: RoutineKind, _ target: String) -> String {
		switch kind {
		case .procedure, .function, .trigger, .view: "DROP \(kind.sqlWord) \(Self.withoutDatabase(target))"
		case .event, .package: none
		}
	}
	func setEventEnabled(_ target: String, _ on: Bool) -> String { none }

	/// 타입(길이) [IDENTITY] NULL/NOT NULL [DEFAULT …] — DEFAULT 는 맨 뒤 (ALTER COLUMN 에서 떼어 낸다)
	func columnDefinition(_ c: StructColumn) -> String {
		var s = Self.typeWithLength(c.type, c.length)
		if let co = c.collation, !co.isEmpty, StructColumn.textTypes.contains(c.type) || ["NVARCHAR", "NCHAR"].contains(c.type) { s += " COLLATE \(co)" }
		if c.autoIncrement { s += " IDENTITY(1,1)" }
		s += c.nullable ? " NULL" : " NOT NULL"
		if let d = c.defaultValue, !c.autoIncrement { s += " DEFAULT " + defaultValueSQL(d, expr: c.defaultExpr, numeric: c.isNumeric) }
		return s
	}
	func columnDefinition(_ c: NewColumn) -> String {
		var s = quote(c.name) + " " + Self.typeWithLength(Self.sqlServerType(c.type), c.length)
		if c.autoIncrement { s += " IDENTITY(1,1)" }
		s += (c.nullable && !c.primary) ? " NULL" : " NOT NULL"
		let d = c.defaultValue.trimmingCharacters(in: .whitespaces)
		if !d.isEmpty, !c.autoIncrement { s += " DEFAULT " + defaultValueSQL(c.defaultValue, expr: false, numeric: c.isNumeric) }
		return s
	}
	/// 길이를 받는 형식이면 (길이). VARCHAR·NVARCHAR·VARBINARY 는 MAX 도
	static func typeWithLength(_ type: String, _ length: String) -> String {
		let len = length.trimmingCharacters(in: .whitespaces)
		guard !len.isEmpty, !type.contains("(") else { return type }
		let takes: Set<String> = ["CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "BINARY", "VARBINARY", "DECIMAL", "NUMERIC", "DATETIME2", "TIME", "DATETIMEOFFSET", "FLOAT"]
		return takes.contains(type.uppercased()) ? "\(type)(\(len))" : type
	}
	/// MySQL 형식 이름을 SQL Server 형식으로 (새 테이블 시트가 MySQL 목록을 쓰는 동안)
	static func sqlServerType(_ t: String) -> String {
		switch t.uppercased() {
		case "MEDIUMINT", "INTEGER": "INT"
		case "DOUBLE": "FLOAT"
		case "TEXT", "MEDIUMTEXT", "LONGTEXT", "TINYTEXT": "NVARCHAR(MAX)"
		case "BLOB", "MEDIUMBLOB", "LONGBLOB", "TINYBLOB": "VARBINARY(MAX)"
		case "BOOLEAN", "BOOL": "BIT"
		case "TIMESTAMP": "DATETIME2"
		case "JSON": "NVARCHAR(MAX)"
		case "YEAR": "SMALLINT"
		default: t.uppercased()
		}
	}
	func defaultValueSQL(_ d: String, expr: Bool, numeric: Bool) -> String {
		let t = d.trimmingCharacters(in: .whitespaces)
		let up = t.uppercased()
		if ["NULL", "GETDATE()", "GETUTCDATE()", "SYSDATETIME()", "SYSUTCDATETIME()", "SYSDATETIMEOFFSET()", "NEWID()", "NEWSEQUENTIALID()", "CURRENT_TIMESTAMP"].contains(up) { return up }
		if expr { return t.hasPrefix("(") ? t : "(\(t))" }
		if numeric, Double(t) != nil { return t }
		if t.count >= 2, t.hasPrefix("'") || t.hasPrefix("N'"), t.hasSuffix("'") { return t }
		return literal(.text(d))
	}

	/// 절마다 따로 ALTER TABLE. {TABLE} 이 든 절(CREATE INDEX · DROP INDEX)은 그 자리에 테이블을 넣은 문장 그대로,
	/// 컬럼 이름 바꾸기({RENAME} 옛이름 \u{1} 새이름)는 [DB].sys.sp_rename
	func alterTable(_ target: String, _ clauses: [String], multiline: Bool) -> String {
		let parts = Self.parts(target)
		let db = parts.count == 3 ? quote(parts[0]) + "." : ""
		let obj = parts.suffix(2).map(quote).joined(separator: ".")
		var list: [String] = []
		for c in clauses where !c.hasPrefix("--") {
			for piece in c.components(separatedBy: "\u{2}") {
				if piece.hasPrefix("{RENAME}") {
					let names = piece.dropFirst("{RENAME}".count).components(separatedBy: "\u{1}")
					guard names.count == 2 else { continue }
					list.append("EXEC \(db)sys.sp_rename \(literal(.text(obj + "." + quote(names[0])))), \(literal(.text(names[1]))), N'COLUMN'")
				} else if piece.hasPrefix("CREATE ") || piece.hasPrefix("DROP INDEX") {
					list.append(piece.replacingOccurrences(of: "{TABLE}", with: target))
				} else {
					list.append("ALTER TABLE \(target) " + piece.replacingOccurrences(of: "{TABLE}", with: target))
				}
			}
		}
		return list.joined(separator: multiline ? ";\n" : "; ")
	}
	func dropColumn(_ name: String) -> String { "DROP COLUMN \(quote(name))" }
	/// 위치는 정할 수 없다 (늘 맨 뒤)
	func addColumn(_ name: String, definition: String, position: ColumnPosition?) -> String { "ADD \(quote(name)) \(definition)" }
	/// 이름 바꾸기는 sp_rename, 정의는 ALTER COLUMN (기본값·IDENTITY 는 ALTER COLUMN 으로 못 바꿔 뺀다)
	func changeColumn(_ old: String, to name: String, definition: String, position: ColumnPosition?) -> String {
		var def = definition
		if let r = def.range(of: " DEFAULT ") { def = String(def[..<r.lowerBound]) }
		def = def.replacingOccurrences(of: " IDENTITY(1,1)", with: "")
		let alter = "ALTER COLUMN \(quote(name)) \(def)"
		return old == name ? alter : "{RENAME}\(old)\u{1}\(name)\u{2}" + alter
	}
	func engineClause(_ engine: String) -> String { "--" }
	func charsetClause(_ charset: String, collation: String, convert: Bool) -> String { "--" }
	func tableCommentClause(_ comment: String) -> String { "--" }
	func autoIncrementClause(_ n: Int64) -> String { "--" }

	func indexPart(_ s: String) -> String { s.hasPrefix("(") ? s : quote(s) }
	func dropIndexClause(_ index: IndexInfo) -> String {
		index.kind == .primary ? "DROP CONSTRAINT \(quote(index.name))" : "DROP INDEX \(quote(index.name)) ON {TABLE}"
	}
	func addIndexClause(kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		let n = name.trimmingCharacters(in: .whitespaces)
		let cols = columns.map(indexPart).joined(separator: ", ")
		let idx = quote(n.isEmpty ? "IX_" + columns.joined(separator: "_") : n)
		switch kind {
		case .primary: return "ADD " + (n.isEmpty ? "" : "CONSTRAINT \(quote(n)) ") + "PRIMARY KEY (\(cols))"
		case .unique: return "CREATE UNIQUE INDEX \(idx) ON {TABLE} (\(cols))"
		default: return "CREATE INDEX \(idx) ON {TABLE} (\(cols))"
		}
	}
	/// 다른 DB 의 테이블은 참조할 수 없다 → [스키마].[이름]
	func addForeignKeyClause(_ fk: ForeignKeyInfo, schema: String) -> String {
		let ref = quote(schema: "", table: fk.refTable)
		var s = "ADD CONSTRAINT \(quote(fk.name)) FOREIGN KEY (\(fk.columns.map(quote).joined(separator: ", "))) REFERENCES \(ref) (\(fk.refColumns.map(quote).joined(separator: ", ")))"
		let rules = ["CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION"]
		if rules.contains(fk.onDelete.uppercased()) { s += " ON DELETE \(fk.onDelete.uppercased())" }
		if rules.contains(fk.onUpdate.uppercased()) { s += " ON UPDATE \(fk.onUpdate.uppercased())" }
		return s
	}
	func dropForeignKeyClause(_ name: String) -> String { "DROP CONSTRAINT \(quote(name))" }

	/// "[a].[b].[c]" → ["a", "b", "c"] (]] 는 ])
	static func parts(_ s: String) -> [String] {
		var out: [String] = [], cur = "", inside = false
		var it = Array(s)[...]
		while let ch = it.first {
			it = it.dropFirst()
			if inside {
				if ch == "]" {
					if it.first == "]" { cur.append("]"); it = it.dropFirst() } else { inside = false }
				} else { cur.append(ch) }
			} else if ch == "[" { inside = true }
			else if ch == "." { out.append(cur); cur = "" }
			else if !ch.isWhitespace { cur.append(ch) }
		}
		out.append(cur)
		return out
	}
	/// [DB].[스키마].[이름] → [스키마].[이름]
	static func withoutDatabase(_ s: String) -> String {
		let p = parts(s)
		guard p.count == 3 else { return s }
		return p.suffix(2).map { "[" + $0.replacingOccurrences(of: "]", with: "]]") + "]" }.joined(separator: ".")
	}
}

// MARK: - 루틴·계정·서버

extension SQLServerDialect {
	func routineTemplate(_ kind: RoutineKind, table: String?) -> String {
		switch kind {
		case .procedure: "CREATE OR ALTER PROCEDURE [dbo].[new_procedure]\nAS\nBEGIN\n\tSET NOCOUNT ON;\n\tSELECT 1;\nEND"
		case .function: "CREATE OR ALTER FUNCTION [dbo].[new_function]()\nRETURNS INT\nAS\nBEGIN\n\tRETURN 1;\nEND"
		case .trigger: "CREATE OR ALTER TRIGGER [dbo].[new_trigger]\nON \(table.map { quote(schema: "", table: $0) } ?? "[dbo].[테이블]")\nAFTER INSERT\nAS\nBEGIN\n\tSET NOCOUNT ON;\nEND"
		case .view: "CREATE OR ALTER VIEW [dbo].[new_view]\nAS\nSELECT 1 AS x"
		case .event, .package: none
		}
	}
	func callRoutine(_ kind: RoutineKind, _ target: String, args: [String], outs: [String]) -> [String] {
		switch kind {
		case .function: ["SELECT \(target)(\(args.joined(separator: ", ")))"]
		default: ["EXEC \(target)" + (args.isEmpty ? "" : " " + args.joined(separator: ", "))]
		}
	}
	func outVariable(_ name: String) -> String { "@" + name }
	/// 끝의 GO 줄을 뗀다
	func cleanDefinition(_ s: String) -> String {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if let r = t.range(of: #"\n\s*GO\s*$"#, options: [.regularExpression, .caseInsensitive]) { t = String(t[..<r.lowerBound]) }
		return t.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	func stripDefiner(_ s: String) -> String { s }
	/// CREATE → CREATE OR ALTER (2016 SP1 이상)
	func createOrReplace(_ s: String) -> String {
		guard let r = s.range(of: #"(?i)^\s*CREATE\s+(?!OR\s+ALTER)"#, options: .regularExpression) else { return s }
		return s.replacingCharacters(in: r, with: "CREATE OR ALTER ")
	}
	func definedName(_ s: String, _ k: RoutineKind) -> String? {
		let word = k == .procedure ? "PROC(?:EDURE)?" : k.sqlWord
		let pattern = #"\b"# + word + #"\s+((?:(?:\[[^\]]+\]|\w+)\s*\.\s*)?(?:\[(?:[^\]]|\]\])+\]|\w+))"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
		let p = Self.parts(String(s[r]))
		return p.count == 2 ? Self.displayName(schema: p[0], table: p[1]) : p.last
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
	func createDatabaseIfNotExists(_ name: String) -> String {
		"IF DB_ID(\(literal(.text(name)))) IS NULL CREATE DATABASE \(quote(name))"
	}
	func kill(_ id: Int64, connection: Bool) -> String { "KILL \(id)" }
}
