import Foundation

/// DB 종류마다 다른 SQL 문법. 앱이 SQL 을 만들 때는 직접 쓰지 않고 이걸 거친다 (`session.dialect`).
/// 1단계: 이름·값 감싸기만. SHOW·information_schema·LIMIT·ALTER 등은 2단계에서 하나씩 옮긴다
protocol SQLDialect: SQLDDL, SQLAdminSQL, Sendable {
	var kind: SQLKind { get }

	/// 이름 하나 감싸기 (MySQL: `이름`)
	func quote(_ name: String) -> String
	/// 스키마.테이블
	func quote(schema: String, table: String) -> String
	/// 그대로 쓸 수 있는 이름이면 그대로, 아니면 감싸기 (자동 완성). reserved 는 대문자 예약어
	func quoteIfNeeded(_ name: String, reserved: Set<String>) -> String
	/// 값 리터럴 (NULL, '글자', 바이너리)
	func literal(_ v: Value) -> String
	/// LIKE 값 안의 % _ (와 이스케이프 글자)를 글자 그대로 찾게
	func likeEscaped(_ s: String) -> String

	/// SQL 글자를 읽는 규칙 (따옴표·주석·키워드)
	var syntax: SQLSyntax { get }

	/// 실행계획 (표)
	func explain(_ body: String) -> String
	/// 실행계획 나무 모양 (없는 DB 면 nil)
	func explainTree(_ body: String) -> String?

	// MARK: 기본 문장

	/// SELECT(또는 INSERT … SELECT)에 행 수 제한을 붙인다. offset 이 nil 이면 처음부터 (OFFSET 을 쓰지 않는다)
	func paged(_ sql: String, limit: Int, offset: Int?) -> String
	/// 기본 DB 바꾸기
	func use(_ schema: String) -> String
	var beginTransaction: String { get }
	var commit: String { get }
	var rollback: String { get }
	/// 외래 키 검사 끄기·켜기 (없는 DB 면 nil)
	func foreignKeyChecks(_ on: Bool) -> String?
	/// SQL 파일 내보내기의 맨 앞·맨 뒤 문장 (; 없이)
	var dumpPrologue: [String] { get }
	var dumpEpilogue: [String] { get }

	/// 행 하나 고치기·지우기·넣기 (; 없이). table 은 감싼 이름, condition 은 그 행만 고르는 WHERE 조건,
	/// sets 는 "`컬럼` = 값", columns·values 는 감싼 이름·리터럴 (비면 기본값만으로 한 행)
	func updateRow(_ table: String, sets: [String], condition: String) -> String
	func deleteRow(_ table: String, condition: String) -> String
	func insertRow(_ table: String, columns: [String], values: [String]) -> String
	/// 바이트 길이 식 (큰 BLOB 은 앞부분만 읽으려고)
	func byteLength(_ expr: String) -> String
	/// 길이가 over 바이트를 넘으면 앞 keep 바이트만, 아니면 그대로인 식
	func blobPeek(_ column: String, over: Int, keep: Int) -> String

	/// 아이디·비밀번호가 틀려 접속에 실패한 오류인지 (로그인 시트를 띄운다)
	func isAuthFailure(_ error: Error) -> Bool
	/// 서버가 SQL 에 오류로 답했는지 (연결은 멀쩡하다 — 다시 접속해 봐야 소용없다)
	func isServerError(_ error: Error) -> Bool
}

extension SQLDialect {
	func quote(schema: String, table: String) -> String { quote(schema) + "." + quote(table) }
	/// 테이블 (스키마.테이블)
	func quote(table t: TableInfo) -> String { quote(schema: t.schema, table: t.name) }
	func paged(_ sql: String, limit: Int) -> String { paged(sql, limit: limit, offset: nil) }
}
