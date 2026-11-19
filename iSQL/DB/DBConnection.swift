import Foundation

/// DB 연결 하나. 종류마다 하나씩 구현한다 (지금은 MySQLConnection)
protocol DBConnection: AnyObject, Sendable {
	/// 서버가 알려 준 버전 글자
	var serverVersion: String { get }
	var isOpen: Bool { get }
	/// TLS 로 붙었으면 그 버전 ("TLS 1.2"), 아니면 nil
	var tlsSummary: String? { get }
	/// 쿼리를 보낸 뒤 알린다 (콘솔): SQL, 걸린 시간(초), 오류
	var onQuery: (@Sendable (String, Double, String?) -> Void)? { get set }

	/// SQL 을 실행하고 결과를 모두 돌려준다 (여러 문장이면 결과도 여러 개)
	func query(_ sql: String) async throws -> [QueryResult]
	/// 바이트 그대로 실행 (SQL 파일 가져오기)
	func query(bytes: [UInt8]) async throws -> [QueryResult]
	/// 결과 하나만 필요할 때 (마지막 결과)
	func rows(_ sql: String) async throws -> QueryResult
	func close()
}

extension DBConnection {
	var tlsSummary: String? { nil }
}

/// 접속에 필요한 것 (비밀번호는 메모리에만)
struct DBConnectOptions {
	var host: String
	var port: Int
	var user: String
	var password: String
	var database: String
	/// SQLite 파일 (펼친 경로)
	var path = ""
	/// TLS (MySQL·MariaDB). tlsHost = 인증서 이름 확인용 원래 서버 이름
	var tls: TLSMode = .off
	var tlsHost = ""
	var tlsCA = ""
	/// Oracle: 서비스 이름(또는 sid 가 true 면 SID), SYSDBA 로 접속. database 는 기본 스키마
	var service = ""
	var sid = false
	var sysdba = false
}

extension DBConnectOptions {
	/// 서버 설정의 Oracle 칸을 채운다
	func oracle(_ server: Server) -> DBConnectOptions {
		var o = self
		o.service = server.service ?? ""
		o.sid = server.oracleSID ?? false
		o.sysdba = server.oracleSysDBA ?? false
		return o
	}
}

enum DB {
	/// 종류에 맞는 연결을 연다
	static func connect(_ kind: SQLKind, _ o: DBConnectOptions) async throws -> any DBConnection {
		switch kind {
		case .sqlite:
			return try await SQLiteConnection.open(path: o.path)
		case .oracle:
			guard !o.service.isEmpty else { throw DBError.message("서비스 이름(또는 SID)을 넣으세요.") }
			return try await OracleConnection.connect(.init(host: o.host, port: o.port, user: o.user, password: o.password,
			                                                service: o.service, sid: o.sid, sysdba: o.sysdba, schema: o.database))
		case .mysql, .mariadb, .postgres, .sqlserver:
			return try await MySQLConnection.connect(.init(host: o.host, port: o.port, user: o.user, password: o.password, database: o.database,
			                                               tls: o.tls, tlsHost: o.tlsHost, tlsCA: o.tlsCA))
		}
	}
}

/// 종류와 상관없는 오류 (서버가 돌려준 오류는 각 연결의 오류 형식 그대로)
enum DBError: LocalizedError {
	/// 연결이 없거나 끊김
	case closed
	/// 앱이 만든 오류 글자
	case message(String)

	var errorDescription: String? {
		switch self {
		case .closed: "서버와 연결이 끊어졌습니다."
		case .message(let s): s
		}
	}
}
