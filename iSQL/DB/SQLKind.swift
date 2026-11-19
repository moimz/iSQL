import Foundation

/// DB 종류. rawValue 는 서버 파일의 "kind" 칸에 그대로 들어간다 (1.x 와 같은 이름 — 바꾸지 않는다)
enum SQLKind: String, CaseIterable, Identifiable, Sendable {
	case mysql, mariadb, postgres, sqlserver, sqlite, oracle

	var id: String { rawValue }

	/// 이 빌드가 접속할 수 있는 종류. 다른 종류의 서버 파일은 목록에서 숨기고 건드리지 않는다 (ServerStore).
	/// 하나씩 만들 때마다 여기에 넣는다
	/// Oracle 은 2026-11-20 부터 모든 빌드에서 (그 전에는 디버그 빌드에서만)
	static let supported: Set<SQLKind> = [.mysql, .mariadb, .sqlite, .oracle]

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

	/// 서버 목록 아이콘에 쓰는 로고 에셋 (없으면 드럼). 로고는 각 회사의 상표 — 접속 종류 표시에만 쓴다
	var logoAsset: String? {
		switch self {
		case .mysql: "DBLogoMySQL"
		case .mariadb: "DBLogoMariaDB"
		case .sqlite: "DBLogoSQLite"
		case .oracle: "DBLogoOracle"
		case .postgres, .sqlserver: nil
		}
	}

	/// 접속 주소 글자의 앞 (mysql://…)
	var urlScheme: String {
		switch self {
		case .mysql: "mysql"
		case .mariadb: "mariadb"
		case .postgres: "postgresql"
		case .sqlserver: "sqlserver"
		case .sqlite: "sqlite"
		case .oracle: "oracle"
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

	/// 이 종류에 있는 기능. 계정 관리·iModules 내보내기는 MySQL 에서만 (사용자 2026-11-18).
	/// 나머지는 종류마다 붙일 때 정한다 (지금은 MySQL 과 같게)
	var capabilities: SQLCapabilities {
		var c = SQLCapabilities.mysql
		if self != .mysql {
			c.accounts = false
			c.iModulesExport = false
		}
		if self == .sqlite {
			// 파일 하나짜리 DB: 서버 관리·엔진·문자셋·코멘트·루틴(트리거 빼고)이 없다. 외래 키는 보기만 (나중에 더할 수 없다)
			c.routineKinds = [.trigger]
			c.routineDefiner = false
			c.serverStatus = false; c.processKill = false; c.queryDigests = false; c.serverVariables = false
			c.renameDatabase = false; c.copyDatabase = false; c.copyRoutines = false
			c.createTableLike = false; c.truncate = false; c.multipleDatabases = false
			c.engines = false; c.charsets = false; c.tableComment = false; c.columnComment = false
			c.autoIncrementEdit = false; c.rowFormat = false; c.unsignedColumns = false; c.onUpdateTimestamp = false
			c.fulltextIndex = false; c.spatialIndex = false; c.foreignKeys = false
		}
		if self == .oracle {
			// "데이터베이스" = 스키마(사용자): 만들기·지우기·이름 바꾸기·복제는 없다. 서버 관리·계정·엔진·문자셋도 아직 없다
			c.routineKinds = [.procedure, .function, .package, .trigger]
			c.routineDefiner = false
			c.serverStatus = false; c.processKill = false; c.queryDigests = false; c.serverVariables = false
			c.renameDatabase = false; c.copyDatabase = false; c.copyRoutines = false
			c.createTableLike = false; c.multipleDatabases = false
			c.engines = false; c.charsets = false; c.tableComment = false; c.columnComment = false
			c.autoIncrementEdit = false; c.rowFormat = false; c.unsignedColumns = false; c.onUpdateTimestamp = false
			c.fulltextIndex = false; c.spatialIndex = false
			c.foreignKeyChecksToggle = false; c.jsonPathFilter = false
		}
		#if DEBUG
		c = c.applyingDebugOverrides()
		#endif
		return c
	}

	/// 이 종류의 메타데이터 읽기 (아직 없는 종류는 MySQL)
	var meta: any SQLMeta {
		switch self {
		case .mariadb: MySQLMeta(mariadb: true)
		case .sqlite: SQLiteMeta()
		case .oracle: OracleMeta()
		case .mysql, .postgres, .sqlserver: MySQLMeta()
		}
	}

	/// 이 종류의 SQL 문법 (아직 없는 종류는 MySQL)
	var dialect: any SQLDialect {
		switch self {
		case .mariadb: MySQLDialect(mariadb: true)
		case .sqlite: SQLiteDialect()
		case .oracle: OracleDialect()
		case .mysql, .postgres, .sqlserver: MySQLDialect()
		}
	}
}

extension SQLKind {
	/// 같은 프로토콜로 붙는 종류끼리 (MySQL·MariaDB) 접속해서 서버가 알려 준 버전으로 실제 종류를 고른다.
	/// 다른 계열이면 nil (그대로 둔다)
	func detected(fromVersion version: String) -> SQLKind? {
		guard self == .mysql || self == .mariadb else { return nil }
		return version.localizedCaseInsensitiveContains("mariadb") ? .mariadb : .mysql
	}

	/// 접속 화면에 쓰는 이름 (MySQL·MariaDB 는 접속해 봐야 알아서 하나로)
	var familyLabel: String { self == .mysql || self == .mariadb ? "MySQL · MariaDB" : label }
}

extension Server {
	/// kind 글자를 SQLKind 로 (옛 파일 = mysql, 이 빌드가 모르는 이름이면 nil)
	var sqlKind: SQLKind? { SQLKind(rawValue: kind ?? Self.mysqlKind) }
	/// 화면에 쓰는 DB 종류 이름 (모르는 종류면 kind 글자 그대로)
	var kindLabel: String { sqlKind?.label ?? (kind ?? "") }

	/// 파일 하나가 DB 인 종류 (호스트·SSH 대신 파일)
	var isFileDB: Bool { sqlKind == .sqlite }

	/// SQLite 파일의 이 맥 경로: 이 맥에서 다시 고른 경로(파일이 있으면) → 서버 파일의 경로. ~ 를 펼친다
	var sqliteFilePath: String? {
		if let local = UserDefaults.standard.string(forKey: Self.localPathKey(id)), FileManager.default.fileExists(atPath: local) { return local }
		guard let p = path, !p.isEmpty else { return nil }
		return (p as NSString).expandingTildeInPath
	}
	static func localPathKey(_ id: UUID) -> String { "sqlitePath.\(id.uuidString)" }

	/// 홈 아래 경로는 ~ 로 (두 맥이 같은 사용자 이름이면 그대로 맞는다)
	static func abbreviatedPath(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

	/// 동기화 폴더(iCloud Drive·Dropbox·Google Drive·OneDrive 등) 안의 파일인지 — 열어 둔 채 고치면 깨질 수 있어 경고
	static func isInSyncedFolder(_ path: String) -> Bool {
		let p = (path as NSString).expandingTildeInPath
		let home = NSHomeDirectory()
		let synced = [home + "/Library/Mobile Documents/", home + "/Library/CloudStorage/", home + "/Dropbox/", home + "/Google Drive/", home + "/OneDrive"]
		if synced.contains(where: { p.hasPrefix($0) }) { return true }
		// 데스크탑·문서를 iCloud 로 동기화하는 경우
		return (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
	}
}
