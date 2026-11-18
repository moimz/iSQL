import Foundation

/// 루틴 실행·계정·서버 관리 SQL 만들기 (SQLDialect 의 한 부분). 모두 ; 없이 돌려준다
protocol SQLAdminSQL {
	// MARK: 루틴
	/// 새로 만들 때 기본 틀 (table: 트리거가 붙을 테이블, 없으면 자리 표시)
	func routineTemplate(_ kind: RoutineKind, table: String?) -> String
	/// 루틴 부르기 (쿼리 패널에 넣을 문장들). args 는 이미 SQL 로 바꾼 인자, outs 는 OUT·INOUT 인자 이름
	func callRoutine(_ kind: RoutineKind, _ target: String, args: [String], outs: [String]) -> [String]
	/// OUT 인자를 받을 변수 (CALL 의 인자 자리)
	func outVariable(_ name: String) -> String

	// MARK: 계정
	/// 'user'@'host'
	func accountName(user: String, host: String) -> String
	func createUser(_ account: String, password: String) -> String
	func dropUser(_ account: String) -> String
	func setPassword(_ account: String, _ password: String) -> String
	func setAccountLocked(_ account: String, _ locked: Bool) -> String
	/// 권한 대상: DB 하나의 모든 것 (`db`.*) / 서버 전체 (*.*)
	func grantTarget(database: String?) -> String
	/// privileges 가 비고 grantOption 만 있으면 GRANT USAGE … WITH GRANT OPTION
	func grant(_ privileges: [String], on target: String, to account: String, grantOption: Bool) -> String
	func grantAll(on target: String, to account: String) -> String
	func revoke(_ privileges: [String], on target: String, from account: String) -> String
	func revokeAll(on target: String, from account: String) -> String
	func revokeGrantOption(on target: String, from account: String) -> String
	func createDatabaseIfNotExists(_ name: String) -> String

	// MARK: 서버
	/// kill: 연결 끊기(true) / 쿼리만 멈추기(false)
	func kill(_ id: Int64, connection: Bool) -> String
}
