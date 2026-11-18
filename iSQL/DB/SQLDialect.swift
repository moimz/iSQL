import Foundation

/// DB 종류마다 다른 SQL 문법. 앱이 SQL 을 만들 때는 직접 쓰지 않고 이걸 거친다 (`session.dialect`).
/// 1단계: 이름·값 감싸기만. SHOW·information_schema·LIMIT·ALTER 등은 2단계에서 하나씩 옮긴다
protocol SQLDialect: Sendable {
	var kind: SQLKind { get }

	/// 이름 하나 감싸기 (MySQL: `이름`)
	func quote(_ name: String) -> String
	/// 스키마.테이블
	func quote(schema: String, table: String) -> String
	/// 그대로 쓸 수 있는 이름이면 그대로, 아니면 감싸기 (자동 완성). reserved 는 대문자 예약어
	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String
	/// 값 리터럴 (NULL, '글자', 바이너리)
	func literal(_ v: Value) -> String

	/// 아이디·비밀번호가 틀려 접속에 실패한 오류인지 (로그인 시트를 띄운다)
	func isAuthFailure(_ error: Error) -> Bool
	/// 서버가 SQL 에 오류로 답했는지 (연결은 멀쩡하다 — 다시 접속해 봐야 소용없다)
	func isServerError(_ error: Error) -> Bool
}

extension SQLDialect {
	func quote(schema: String, table: String) -> String { quote(schema) + "." + quote(table) }
	/// 테이블 (스키마.테이블)
	func quote(table t: TableInfo) -> String { quote(schema: t.schema, table: t.name) }
}
