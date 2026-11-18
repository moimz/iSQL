import Foundation

/// 접속할 서버 하나. 비밀번호는 여기에 두지 않는다 (Keychain 에만 있다)
struct Server: Codable, Identifiable, Hashable {
	var id = UUID()
	var name = ""
	/// 서버 목록에서 묶어 보여 줄 이름 (비어 있으면 묶지 않음)
	var group = ""
	var color: ServerColor = .none

	var host = "127.0.0.1"
	var port = 3306
	var user = "root"
	/// 접속하자마자 고를 DB (비어 있으면 고르지 않음)
	var database = ""

	/// DB 종류. 2.0 의 SQLKind 이름과 같다 (mysql · mariadb · postgres · sqlserver · sqlite · oracle).
	/// 1.0 은 mysql 만 다룬다: 옛 파일(없음)은 읽을 때 "mysql" 로 적어 두고, 다른 종류는 목록에 넣지 않고 파일도 건드리지 않는다.
	/// 모르는 값이 와도 읽기가 실패하지 않게 enum 이 아닌 문자열 (사용자 2026-11-18, 2.0 대비)
	var kind: String? = Server.mysqlKind
	static let mysqlKind = "mysql"
	/// 이 버전이 다룰 수 있는 종류인지 (없으면 옛 파일 = mysql)
	var isSupportedKind: Bool {
		// 2.0: SQLKind.supported 에 든 종류만 (지금은 mysql 하나)
		sqlKind.map { SQLKind.supported.contains($0) } ?? false
	}

	/// mysql://user@host:port/db (비밀번호·SSH 는 빼고)
	var connectionString: String {
		let u = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
		let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
		let db = database.isEmpty ? "" : "/" + (database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database)
		return "mysql://\(u)@\(h):\(port)\(db)"
	}

	var ssh = SSHSettings()

	/// 그룹 안 순서 (작을수록 위, 없으면 이름순으로 뒤에). 예전 파일에는 없어서 옵셔널
	var order: Double?

	/// 마지막으로 고친 시각 (두 맥에서 고쳤을 때 최근 것을 남기려고)
	var modified = Date()

	// MARK: 서버별 앱 설정 (설정 창 > 일반, iCloud 로 같이 동기화). 예전 파일에는 없어서 옵셔널, nil 이면 기본값

	/// 위험한 SQL(DROP·TRUNCATE·ALTER·WHERE 없는 UPDATE 등)을 쿼리 패널에서 실행하기 전에 묻기 (기본 켬)
	var warnDangerousSQL: Bool?
	/// 새 데이터베이스·새 테이블을 만들 때 먼저 골라 둘 문자셋·콜레이션 (비면 서버·DB 기본값). 서버 설정 > 일반
	var defaultCharset: String?
	var defaultCollation: String?
	var warnsDangerousSQL: Bool { warnDangerousSQL ?? true }

	var displayName: String { name.isEmpty ? (ssh.enabled ? "\(ssh.host) → \(host)" : host) : name }

	/// Keychain 항목 이름
	var mysqlPasswordKey: String { "\(id.uuidString)/mysql" }
	var sshSecretKey: String { "\(id.uuidString)/ssh" }
}

struct SSHSettings: Codable, Hashable {
	var enabled = false
	/// ~/.ssh/config 의 Host 별칭을 넣어도 된다 (시스템 ssh 가 그 설정을 그대로 쓴다)
	var host = ""
	var port = 22
	/// 비어 있으면 ~/.ssh/config 나 이 맥 사용자 이름을 쓴다
	var user = ""
	var auth: SSHAuth = .key
	/// 비어 있으면 ~/.ssh/config 와 ssh-agent 가 알아서 고른다
	var keyPath = ""
}

enum SSHAuth: String, Codable, CaseIterable, Identifiable {
	/// 키 파일 (암호가 있으면 Keychain 의 ssh 항목을 쓴다)
	case key
	/// 비밀번호 (Keychain 의 ssh 항목)
	case password
	var id: String { rawValue }
	var label: String { self == .key ? "키 파일" : "비밀번호" }
}

enum ServerColor: String, Codable, CaseIterable, Identifiable {
	case none, red, orange, yellow, green, blue, purple, gray
	var id: String { rawValue }
	var label: String {
		switch self {
		case .none: "없음"
		case .red: "빨강 (운영)"
		case .orange: "주황"
		case .yellow: "노랑"
		case .green: "초록 (개발)"
		case .blue: "파랑"
		case .purple: "보라"
		case .gray: "회색"
		}
	}
}
