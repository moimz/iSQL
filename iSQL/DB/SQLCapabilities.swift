import Foundation

/// DB 종류에 있는 기능. 없는 기능의 메뉴·탭·칸은 회색이 아니라 숨긴다 (session.capabilities).
/// 서버마다 그때그때 다른 것(n-gram 파서, performance_schema 켜짐, EXPLAIN 나무 모양)은 여기가 아니라 접속해서 읽은 값으로 본다
struct SQLCapabilities: Sendable {
	// MARK: 루틴
	/// 사이드바 묶음·새로 만들기에 나오는 루틴 종류
	var routineKinds: [RoutineKind] = RoutineKind.routineKinds
	/// 루틴 정의의 만든 계정(DEFINER) 남기기·빼기
	var routineDefiner = true

	// MARK: 서버 관리 (서버 설정 창)
	/// 사용자 계정 탭 (MySQL 전용 — 다른 DB 는 실제로 지원할 때 정한다, 사용자 2026-11-18)
	var accounts = true
	/// 상태 탭 (요약·프로세스 목록)
	var serverStatus = true
	/// 프로세스 목록에서 쿼리 멈추기·연결 끊기
	var processKill = true
	/// 상태 탭의 쿼리 통계
	var queryDigests = true
	/// 서버 설정(변수) 탭
	var serverVariables = true

	// MARK: DB·테이블 다루기
	var renameDatabase = true
	var copyDatabase = true
	/// DB 복제에서 루틴까지 복제
	var copyRoutines = true
	/// 테이블 복제 (CREATE TABLE … LIKE)
	var createTableLike = true
	/// 테이블 비우기 (TRUNCATE)
	var truncate = true
	/// DB 가 여럿 (SQLite 처럼 하나뿐이면 DB 만들기·지우기·목록이 없다)
	var multipleDatabases = true

	// MARK: 테이블·컬럼 설정
	/// 저장 엔진 고르기
	var engines = true
	/// DB·테이블·컬럼 문자셋·콜레이션 (서버 설정 "새로 만들 때" 기본값 포함)
	var charsets = true
	var tableComment = true
	var columnComment = true
	/// AUTO_INCREMENT 다음 값 바꾸기
	var autoIncrementEdit = true
	/// 행 형식 (ROW_FORMAT) 보기
	var rowFormat = true
	/// UNSIGNED 숫자 컬럼
	var unsignedColumns = true
	/// on update CURRENT_TIMESTAMP
	var onUpdateTimestamp = true
	var fulltextIndex = true
	var spatialIndex = true
	var foreignKeys = true

	// MARK: 내보내기·가져오기
	/// iModules 형식 내보내기 (MySQL 에서만. iModules 가 여러 DB 를 지원하면 하나씩 붙인다, 사용자 2026-11-18)
	var iModulesExport = true
	/// SQL 파일 가져오기의 "외래 키 검사 끄기"
	var foreignKeyChecksToggle = true

	/// MySQL: 모두 있다
	static let mysql = SQLCapabilities()
}

#if DEBUG
extension SQLCapabilities {
	/// 시험용: ISQL_CAPS_OFF=routines,accounts,… 로 기능을 꺼서 숨김이 되는지 본다 (배포판에는 없다)
	func applyingDebugOverrides() -> SQLCapabilities {
		guard let list = ProcessInfo.processInfo.environment["ISQL_CAPS_OFF"] else { return self }
		var c = self
		for k in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
			switch k {
			case "routines": c.routineKinds = []
			case "events": c.routineKinds.removeAll { $0 == .event }
			case "routineDefiner": c.routineDefiner = false
			case "accounts": c.accounts = false
			case "serverStatus": c.serverStatus = false
			case "processKill": c.processKill = false
			case "queryDigests": c.queryDigests = false
			case "serverVariables": c.serverVariables = false
			case "renameDatabase": c.renameDatabase = false
			case "copyDatabase": c.copyDatabase = false
			case "copyRoutines": c.copyRoutines = false
			case "createTableLike": c.createTableLike = false
			case "truncate": c.truncate = false
			case "multipleDatabases": c.multipleDatabases = false
			case "engines": c.engines = false
			case "charsets": c.charsets = false
			case "tableComment": c.tableComment = false
			case "columnComment": c.columnComment = false
			case "autoIncrementEdit": c.autoIncrementEdit = false
			case "rowFormat": c.rowFormat = false
			case "unsignedColumns": c.unsignedColumns = false
			case "onUpdateTimestamp": c.onUpdateTimestamp = false
			case "fulltextIndex": c.fulltextIndex = false
			case "spatialIndex": c.spatialIndex = false
			case "foreignKeys": c.foreignKeys = false
			case "iModulesExport": c.iModulesExport = false
			case "foreignKeyChecksToggle": c.foreignKeyChecksToggle = false
			default: break
			}
		}
		return c
	}
}
#endif
