import Foundation

/// MySQL 문법 (1.x 에서 여러 곳에 흩어져 있던 것을 모았다)
struct MySQLDialect: SQLDialect {
	var kind: SQLKind { .mysql }

	func quote(_ name: String) -> String { "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }

	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String {
		let ok = name.first.map { $0 == "_" || $0 == "$" || ($0.isASCII && $0.isLetter) } == true
			&& name.allSatisfy { $0 == "_" || $0 == "$" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
		return ok && !reserved.contains(name.uppercased()) ? name : quote(name)
	}

	/// MySQL 문자열 리터럴 (숫자 컬럼도 '123' 으로 넣으면 서버가 바꿔 준다)
	func literal(_ v: Value) -> String {
		switch v {
		case .null: return "NULL"
		case .bytes(let d): return d.isEmpty ? "''" : "X'" + d.map { String(format: "%02X", $0) }.joined() + "'"
		case .text(let s):
			var out = "'"
			for ch in s.unicodeScalars {
				switch ch {
				case "\\": out += "\\\\"
				case "'": out += "\\'"
				case "\0": out += "\\0"
				case "\n": out += "\\n"
				case "\r": out += "\\r"
				case "\u{1A}": out += "\\Z"
				default: out.unicodeScalars.append(ch)
				}
			}
			return out + "'"
		}
	}

	/// \ 로 이스케이프 (MySQL 기본 ESCAPE)
	func likeEscaped(_ s: String) -> String {
		s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
	}

	// MARK: 기본 문장

	func paged(_ sql: String, limit: Int, offset: Int?) -> String {
		sql + " LIMIT \(limit)" + (offset.map { " OFFSET \($0)" } ?? "")
	}
	func use(_ schema: String) -> String { "USE " + quote(schema) }
	var beginTransaction: String { "START TRANSACTION" }
	var commit: String { "COMMIT" }
	var rollback: String { "ROLLBACK" }
	func foreignKeyChecks(_ on: Bool) -> String? { "SET FOREIGN_KEY_CHECKS = \(on ? 1 : 0)" }
	var dumpPrologue: [String] { ["SET NAMES utf8mb4", "SET FOREIGN_KEY_CHECKS = 0"] }
	var dumpEpilogue: [String] { ["SET FOREIGN_KEY_CHECKS = 1"] }

	/// 같은 값의 행이 여럿이어도 하나만 바뀌게 LIMIT 1
	func updateRow(_ table: String, sets: [String], condition: String) -> String {
		"UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(condition) LIMIT 1"
	}
	func deleteRow(_ table: String, condition: String) -> String { "DELETE FROM \(table) WHERE \(condition) LIMIT 1" }
	func insertRow(_ table: String, columns: [String], values: [String]) -> String {
		columns.isEmpty ? "INSERT INTO \(table) () VALUES ()"
			: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
	}

	func byteLength(_ expr: String) -> String { "OCTET_LENGTH(\(expr))" }
	func blobPeek(_ column: String, over: Int, keep: Int) -> String {
		"IF(OCTET_LENGTH(\(column)) > \(over), LEFT(\(column), \(keep)), \(column))"
	}

	/// 1045 = Access denied
	func isAuthFailure(_ error: Error) -> Bool {
		if case .server(let code, _, _) = error as? MySQLError, code == 1045 { return true }
		return false
	}

	func isServerError(_ error: Error) -> Bool {
		if case .server = error as? MySQLError { return true }
		return false
	}
}
