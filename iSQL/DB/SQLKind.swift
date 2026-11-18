import Foundation

/// DB 종류. rawValue 는 서버 파일의 "kind" 칸에 그대로 들어간다 (1.x 와 같은 이름 — 바꾸지 않는다)
enum SQLKind: String, CaseIterable, Identifiable, Sendable {
	case mysql, mariadb, postgres, sqlserver, sqlite, oracle

	var id: String { rawValue }

	/// 이 빌드가 접속할 수 있는 종류. 다른 종류의 서버 파일은 목록에서 숨기고 건드리지 않는다 (ServerStore).
	/// 하나씩 만들 때마다 여기에 넣는다
	static let supported: Set<SQLKind> = [.mysql]

	var label: String {
		switch self {
		case .mysql: "MySQL"
		case .mariadb: "MariaDB"
		case .postgres: "PostgreSQL"
		case .sqlserver: "SQL Server"
		case .sqlite: "SQLite"
		case .oracle: "Oracle"
		}
	}

	/// 기본 포트 (SQLite 는 파일이라 없음)
	var defaultPort: Int? {
		switch self {
		case .mysql, .mariadb: 3306
		case .postgres: 5432
		case .sqlserver: 1433
		case .sqlite: nil
		case .oracle: 1521
		}
	}

	/// 이 종류의 SQL 문법. 아직 모두 MySQL (2.0 1단계: 동작은 1.x 그대로, 틀만)
	var dialect: any SQLDialect {
		switch self {
		case .mysql, .mariadb, .postgres, .sqlserver, .sqlite, .oracle: MySQLDialect()
		}
	}
}

extension Server {
	/// kind 글자를 SQLKind 로 (옛 파일 = mysql, 이 빌드가 모르는 이름이면 nil)
	var sqlKind: SQLKind? { SQLKind(rawValue: kind ?? Self.mysqlKind) }
}
