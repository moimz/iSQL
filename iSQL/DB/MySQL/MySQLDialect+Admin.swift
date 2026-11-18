import Foundation

/// MySQL 루틴 실행·계정·서버 관리 SQL (1.x 의 RoutineViews·UserAccounts·ServerDiagnostics 에서 모았다)
extension MySQLDialect {
	// MARK: 루틴

	func routineTemplate(_ kind: RoutineKind, table: String?) -> String {
		let t = table.map { "`" + $0 + "`" } ?? "`테이블`"
		switch kind {
		case .procedure: return "CREATE PROCEDURE `new_procedure`(IN p_id INT)\nBEGIN\n\tSELECT p_id;\nEND"
		case .function: return "CREATE FUNCTION `new_function`(p INT) RETURNS INT\nDETERMINISTIC\nBEGIN\n\tRETURN p;\nEND"
		case .trigger: return "CREATE TRIGGER `new_trigger` BEFORE INSERT ON \(t) FOR EACH ROW\nBEGIN\n\t-- SET NEW.컬럼 = 값;\nEND"
		case .event: return "CREATE EVENT `new_event`\nON SCHEDULE EVERY 1 DAY\nDO\n\tSELECT 1"
		case .view: return "CREATE VIEW `new_view` AS\nSELECT 1"
		}
	}

	/// 함수는 SELECT, 프로시저는 CALL 뒤에 OUT 변수를 SELECT
	func callRoutine(_ kind: RoutineKind, _ target: String, args: [String], outs: [String]) -> [String] {
		let a = args.joined(separator: ", ")
		if kind == .function { return ["SELECT \(target)(\(a))"] }
		var s = ["CALL \(target)(\(a))"]
		if !outs.isEmpty { s.append("SELECT " + outs.map(outVariable).joined(separator: ", ")) }
		return s
	}
	func outVariable(_ name: String) -> String { "@" + name }

	// MARK: 계정

	func accountName(user: String, host: String) -> String { literal(.text(user)) + "@" + literal(.text(host)) }
	func createUser(_ account: String, password: String) -> String {
		"CREATE USER \(account)" + (password.isEmpty ? "" : " IDENTIFIED BY " + literal(.text(password)))
	}
	func dropUser(_ account: String) -> String { "DROP USER \(account)" }
	func setPassword(_ account: String, _ password: String) -> String { "ALTER USER \(account) IDENTIFIED BY \(literal(.text(password)))" }
	func setAccountLocked(_ account: String, _ locked: Bool) -> String { "ALTER USER \(account) ACCOUNT \(locked ? "LOCK" : "UNLOCK")" }
	/// DB 이름(mysql.db 의 Db, 와일드카드 \_ 그대로)을 `db`.* 로
	func grantTarget(database: String?) -> String { database.map { quote($0) + ".*" } ?? "*.*" }
	func grant(_ privileges: [String], on target: String, to account: String, grantOption: Bool) -> String {
		if privileges.isEmpty { return "GRANT USAGE ON \(target) TO \(account) WITH GRANT OPTION" }
		return "GRANT \(privileges.joined(separator: ", ")) ON \(target) TO \(account)" + (grantOption ? " WITH GRANT OPTION" : "")
	}
	func grantAll(on target: String, to account: String) -> String { "GRANT ALL PRIVILEGES ON \(target) TO \(account)" }
	func revoke(_ privileges: [String], on target: String, from account: String) -> String {
		"REVOKE \(privileges.joined(separator: ", ")) ON \(target) FROM \(account)"
	}
	func revokeAll(on target: String, from account: String) -> String { "REVOKE ALL PRIVILEGES ON \(target) FROM \(account)" }
	func revokeGrantOption(on target: String, from account: String) -> String { "REVOKE GRANT OPTION ON \(target) FROM \(account)" }
	func createDatabaseIfNotExists(_ name: String) -> String { "CREATE DATABASE IF NOT EXISTS \(quote(name))" }

	// MARK: 서버

	func kill(_ id: Int64, connection: Bool) -> String { connection ? "KILL \(id)" : "KILL QUERY \(id)" }
}
