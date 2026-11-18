import Foundation
import Observation

/// MySQL 계정 하나 ('user'@'host')
struct DBAccount: Identifiable, Hashable {
	var user: String
	var host: String
	var plugin = ""
	/// ACCOUNT LOCK 상태 (컬럼이 없는 서버는 nil)
	var locked: Bool?
	/// 전역 권한 (SQL 이름: SELECT, GRANT OPTION …)
	var global: Set<String> = []

	var id: String { user + "@" + host }
	/// SQL 에 쓰는 이름 'user'@'host'
	func sql(_ dialect: any SQLDialect) -> String { dialect.literal(.text(user)) + "@" + dialect.literal(.text(host)) }
}

/// 데이터베이스 하나에 준 권한 (mysql.db 한 줄)
struct DBGrant: Identifiable, Hashable {
	var db: String
	var privileges: Set<String>
	var id: String { db }
}

/// 권한 하나: mysql.user / mysql.db 의 컬럼 이름 ↔ GRANT 에 쓰는 이름
struct Privilege: Hashable {
	let column: String
	let sql: String
	let group: Group
	/// 데이터베이스별로도 줄 수 있는지 (mysql.db 에 있는 것)
	let perDatabase: Bool

	enum Group: String, CaseIterable { case data = "데이터", structure = "구조", admin = "관리" }

	/// phpMyAdmin 처럼 데이터 / 구조 / 관리 로 묶는다 (정적 권한만. MySQL 8 의 동적 권한은 SHOW GRANTS 에서 본다)
	static let all: [Privilege] = [
		.init(column: "Select_priv", sql: "SELECT", group: .data, perDatabase: true),
		.init(column: "Insert_priv", sql: "INSERT", group: .data, perDatabase: true),
		.init(column: "Update_priv", sql: "UPDATE", group: .data, perDatabase: true),
		.init(column: "Delete_priv", sql: "DELETE", group: .data, perDatabase: true),
		.init(column: "File_priv", sql: "FILE", group: .data, perDatabase: false),

		.init(column: "Create_priv", sql: "CREATE", group: .structure, perDatabase: true),
		.init(column: "Alter_priv", sql: "ALTER", group: .structure, perDatabase: true),
		.init(column: "Index_priv", sql: "INDEX", group: .structure, perDatabase: true),
		.init(column: "Drop_priv", sql: "DROP", group: .structure, perDatabase: true),
		.init(column: "Create_tmp_table_priv", sql: "CREATE TEMPORARY TABLES", group: .structure, perDatabase: true),
		.init(column: "Show_view_priv", sql: "SHOW VIEW", group: .structure, perDatabase: true),
		.init(column: "Create_routine_priv", sql: "CREATE ROUTINE", group: .structure, perDatabase: true),
		.init(column: "Alter_routine_priv", sql: "ALTER ROUTINE", group: .structure, perDatabase: true),
		.init(column: "Execute_priv", sql: "EXECUTE", group: .structure, perDatabase: true),
		.init(column: "Create_view_priv", sql: "CREATE VIEW", group: .structure, perDatabase: true),
		.init(column: "Event_priv", sql: "EVENT", group: .structure, perDatabase: true),
		.init(column: "Trigger_priv", sql: "TRIGGER", group: .structure, perDatabase: true),
		.init(column: "References_priv", sql: "REFERENCES", group: .structure, perDatabase: true),

		.init(column: "Grant_priv", sql: "GRANT OPTION", group: .admin, perDatabase: true),
		.init(column: "Super_priv", sql: "SUPER", group: .admin, perDatabase: false),
		.init(column: "Process_priv", sql: "PROCESS", group: .admin, perDatabase: false),
		.init(column: "Reload_priv", sql: "RELOAD", group: .admin, perDatabase: false),
		.init(column: "Shutdown_priv", sql: "SHUTDOWN", group: .admin, perDatabase: false),
		.init(column: "Show_db_priv", sql: "SHOW DATABASES", group: .admin, perDatabase: false),
		.init(column: "Lock_tables_priv", sql: "LOCK TABLES", group: .admin, perDatabase: true),
		.init(column: "Repl_client_priv", sql: "REPLICATION CLIENT", group: .admin, perDatabase: false),
		.init(column: "Repl_slave_priv", sql: "REPLICATION SLAVE", group: .admin, perDatabase: false),
		.init(column: "Create_user_priv", sql: "CREATE USER", group: .admin, perDatabase: false),
		.init(column: "Create_tablespace_priv", sql: "CREATE TABLESPACE", group: .admin, perDatabase: false),
		.init(column: "Create_role_priv", sql: "CREATE ROLE", group: .admin, perDatabase: false),
		.init(column: "Drop_role_priv", sql: "DROP ROLE", group: .admin, perDatabase: false),
	]

	/// GRANT 문에 쓸 권한 목록 (GRANT OPTION 은 따로 뺀다: "GRANT … WITH GRANT OPTION")
	static func grantSQL(_ privs: Set<String>, on target: String, to account: DBAccount, _ dialect: any SQLDialect) -> String? {
		let normal = all.map(\.sql).filter { privs.contains($0) && $0 != "GRANT OPTION" }
		let withGrant = privs.contains("GRANT OPTION")
		if normal.isEmpty && !withGrant { return nil }
		if normal.isEmpty { return "GRANT USAGE ON \(target) TO \(account.sql(dialect)) WITH GRANT OPTION" }
		return "GRANT \(normal.joined(separator: ", ")) ON \(target) TO \(account.sql(dialect))" + (withGrant ? " WITH GRANT OPTION" : "")
	}

	static func revokeSQL(_ privs: Set<String>, on target: String, from account: DBAccount, _ dialect: any SQLDialect) -> String? {
		let list = all.map(\.sql).filter { privs.contains($0) }
		return list.isEmpty ? nil : "REVOKE \(list.joined(separator: ", ")) ON \(target) FROM \(account.sql(dialect))"
	}
}

/// 서버 설정 창 > 사용자 계정: mysql.user · mysql.db 를 읽고 CREATE/ALTER/DROP USER, GRANT/REVOKE 를 실행한다
@Observable
final class AccountManager {
	@ObservationIgnored private weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	private var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }

	private(set) var accounts: [DBAccount] = []
	private(set) var dbGrants: [String: [DBGrant]] = [:]
	/// SHOW GRANTS (계정 id 별. 하나만 두면 다른 계정 것이 남아 보였다)
	private(set) var showGrants: [String: [String]] = [:]
	/// 지금 접속한 계정 (CURRENT_USER())
	private(set) var current = ""
	private(set) var loading = false
	private(set) var loaded = false
	/// 목록을 못 읽음 (권한 없음 등)
	private(set) var loadError: String?
	/// 실행 실패 (알림)
	var runError: String?
	private(set) var running = false

	init(session: Session) { self.session = session }

	@MainActor
	func load() async {
		guard let session, !loading else { return }
		loading = true
		defer { loading = false }
		do {
			let u = try await session.query("SELECT * FROM mysql.user ORDER BY User, Host").last ?? QueryResult()
			func col(_ n: String) -> Int? { u.columns.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
			let iUser = col("User"), iHost = col("Host"), iPlugin = col("plugin"), iLocked = col("account_locked")
			let privCols = Privilege.all.compactMap { p in col(p.column).map { (p.sql, $0) } }
			accounts = u.rows.map { r in
				var a = DBAccount(user: iUser.flatMap { r[$0].string } ?? "", host: iHost.flatMap { r[$0].string } ?? "")
				a.plugin = iPlugin.flatMap { r[$0].string } ?? ""
				a.locked = iLocked.map { r[$0].string == "Y" }
				a.global = Set(privCols.filter { r[$0.1].string == "Y" }.map(\.0))
				return a
			}
			loadError = nil
		} catch {
			accounts = []
			loadError = "사용자 목록을 볼 권한이 없습니다 (mysql.user 를 읽을 수 있어야 합니다).\n\(error.localizedDescription)"
			loaded = true
			return
		}
		// DB 별 권한 (못 읽어도 목록은 보인다)
		if let d = try? await session.query("SELECT * FROM mysql.db ORDER BY Db").last {
			func col(_ n: String) -> Int? { d.columns.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
			let iUser = col("User"), iHost = col("Host"), iDb = col("Db")
			let privCols = Privilege.all.filter(\.perDatabase).compactMap { p in col(p.column).map { (p.sql, $0) } }
			var map: [String: [DBGrant]] = [:]
			for r in d.rows {
				let id = (iUser.flatMap { r[$0].string } ?? "") + "@" + (iHost.flatMap { r[$0].string } ?? "")
				map[id, default: []].append(DBGrant(db: iDb.flatMap { r[$0].string } ?? "",
				                                    privileges: Set(privCols.filter { r[$0.1].string == "Y" }.map(\.0))))
			}
			dbGrants = map
		}
		current = (try? await session.query("SELECT CURRENT_USER()").last?.rows.first?.first?.string) ?? ""
		loaded = true
	}

	@MainActor
	func loadGrants(_ a: DBAccount) async {
		guard let session else { return }
		showGrants[a.id] = (try? await session.query("SHOW GRANTS FOR \(a.sql(dialect))").last?.rows.compactMap { $0.first?.string }) ?? []
	}

	/// 문장들을 차례로 실행하고 다시 읽는다. 실패하면 runError
	@MainActor
	@discardableResult
	func run(_ statements: [String], then account: DBAccount? = nil) async -> Bool {
		guard let session, !statements.isEmpty else { return true }
		running = true
		defer { running = false }
		var ok = true
		for s in statements {
			do { _ = try await session.query(s) } catch { runError = error.localizedDescription + "\n\n" + s; ok = false; break }
		}
		await load()
		if let account, let a = accounts.first(where: { $0.id == account.id }) { await loadGrants(a) }
		return ok
	}

	// MARK: 문장 만들기

	static func createSQL(user: String, host: String, password: String, _ dialect: any SQLDialect) -> String {
		let a = DBAccount(user: user, host: host)
		return "CREATE USER \(a.sql(dialect))" + (password.isEmpty ? "" : " IDENTIFIED BY " + dialect.literal(.text(password)))
	}

	/// 전역 권한을 지금 → 바꾼 것으로
	static func globalChangeSQL(_ a: DBAccount, to wanted: Set<String>, _ dialect: any SQLDialect) -> [String] {
		[Privilege.revokeSQL(a.global.subtracting(wanted), on: "*.*", from: a, dialect),
		 Privilege.grantSQL(wanted.subtracting(a.global), on: "*.*", to: a, dialect)].compactMap { $0 }
	}

	/// DB 이름(mysql.db 의 Db, 와일드카드 \_ 그대로)을 `db`.* 로
	static func target(_ db: String, _ dialect: any SQLDialect) -> String { dialect.quote(db) + ".*" }
}
