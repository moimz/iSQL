import Foundation

/// 쿼리 하나를 실행하고 결과를 모두 돌려주는 것 (session.query, 따로 연결의 query, MCP 의 run …).
/// 메타데이터를 읽는 쪽은 연결을 직접 잡지 않고 이걸 받는다 — 콘솔 기록·다시 접속은 부르는 쪽 그대로
typealias DBRun = (String) async throws -> [QueryResult]

/// 서버의 DB·테이블·컬럼 목록 한 번에
struct SchemaSnapshot {
	var databases: [String] = []
	var tables: [TableInfo] = []
	/// 테이블 id(스키마.이름) → 컬럼
	var columns: [String: [ColumnInfo]] = [:]
}

/// 테이블 정보 패널의 테이블 상태
struct TableStatus {
	var engine = "", collation = "", comment = ""
	var approxRows: Int64?
	var avgRowLength: Int64 = 0, dataLength: Int64 = 0, indexLength: Int64 = 0, dataFree: Int64 = 0
	var autoIncrement: Int64?
	var rowFormat = "", created = "", updated = ""
}

/// DB 를 복제할 때 테이블 하나 (테이블 먼저, 뷰는 나중)
struct CopyTableInfo {
	var name: String
	var isView: Bool
	var approxRows: Int64
	/// 생성 컬럼(GENERATED)은 빼고 넣는다 (값을 넣으면 오류)
	var columns: [String] = []
	var primaryKey: [String] = []
}

/// DB 하나에 든 것 (DB 이름 바꾸기)
struct SchemaContents {
	var tables: [String] = []
	var views: [String] = []
	var triggers = 0, routines = 0, events = 0
}

/// CREATE 문을 읽을 대상
enum DBObject {
	case table, view
	case routine(RoutineKind)
}

/// DB 종류마다 다른 메타데이터 읽기 (어떤 쿼리로 읽고 결과를 어떻게 푸는지). 부르는 쪽은 결과 구조만 본다
protocol SQLMeta: Sendable {
	/// 목록에서 빼는 시스템 DB
	var systemSchemas: Set<String> { get }

	/// DB·테이블·컬럼 목록 (결과가 모자라면 nil)
	func schema(_ run: DBRun) async throws -> SchemaSnapshot?
	/// 프로시저·함수·트리거·이벤트 목록 (시스템 DB 빼고)
	func routines(_ run: DBRun) async throws -> [RoutineInfo]
	/// 엔진·문자셋·콜레이션 (전문 검색 파서는 없으면 비워 둔다)
	func serverCatalog(_ run: DBRun) async throws -> ServerCatalog
	/// DB 개요의 테이블 통계
	func tableStats(_ run: DBRun, schema: String) async throws -> [TableStat]
	/// 테이블 정보 패널의 상태 (없으면 nil)
	func tableStatus(_ run: DBRun, _ table: TableInfo) async throws -> TableStatus?
	/// CREATE 문 (없으면 nil). schema 가 비면 지금 기본 DB 에서
	func createStatement(_ run: DBRun, _ object: DBObject, schema: String, name: String) async throws -> String?
	/// 인덱스 (기본 키가 맨 위). createSQL 은 그 테이블의 CREATE 문 (FULLTEXT 파서처럼 목록에 안 나오는 것을 읽는다)
	func indexes(_ run: DBRun, _ table: TableInfo, createSQL: String) async throws -> [IndexInfo]
	/// 외래 키: incoming 이 false 면 이 테이블에서 나가는 키, true 면 다른 테이블에서 이 테이블로 들어오는 키
	func foreignKeys(_ run: DBRun, schema: String, table: String, incoming: Bool) async throws -> [ForeignKeyInfo]
	/// 구조 편집기의 컬럼 정의와, 이름 → CREATE 문의 컬럼 정의 줄 (없으면 nil)
	func structure(_ run: DBRun, _ table: TableInfo) async throws -> (columns: [StructColumn], definitions: [String: String])?
	/// DB 의 기본 문자셋·콜레이션
	func schemaDefaults(_ run: DBRun, schema: String) async throws -> (charset: String, collation: String)?
	/// 서버의 기본 문자셋·콜레이션
	func serverDefaults(_ run: DBRun) async throws -> (charset: String, collation: String)?
	/// 서버의 기본 저장 엔진
	func defaultEngine(_ run: DBRun) async throws -> String?
	/// 복제할 테이블들 (테이블 먼저, 뷰는 나중)
	func copyTables(_ run: DBRun, schema: String) async throws -> [CopyTableInfo]
	/// DB 의 프로시저·함수·트리거·이벤트 이름 (복제용)
	func routineNames(_ run: DBRun, schema: String) async throws -> [(kind: RoutineKind, name: String)]
	/// DB 하나에 든 것
	func contents(_ run: DBRun, schema: String) async -> SchemaContents
	/// DB 의 테이블·뷰 수 (못 읽으면 nil)
	func tableCount(_ run: DBRun, schema: String) async throws -> Int?
	/// 뷰 정의 (SELECT 부분)
	func viewDefinition(_ run: DBRun, schema: String, name: String) async throws -> String?
	/// 서버 안에서 INSERT … SELECT 로 옮기면 안 되는지 (복제 로그가 문장 방식이면 앱을 거쳐 옮긴다)
	func needsClientCopy(_ run: DBRun) async -> Bool
	/// 접속 시험: 버전, 로그인한 계정, DB 수
	func connectionInfo(_ run: DBRun) async throws -> (version: String?, user: String?, databases: String?)
	/// MCP: DB 이름들 (시스템 DB 포함)
	func databaseNames(_ run: DBRun) async throws -> [String]
	// MARK: 루틴·계정·서버 상태

	/// 루틴 인자 (모드 IN/OUT/INOUT, 이름, 타입)
	func routineParameters(_ run: DBRun, schema: String, name: String) async throws -> [(mode: String, name: String, type: String)]
	/// 이벤트 스케줄러가 꺼져 있는지 (못 읽어도 꺼진 것으로)
	func eventSchedulerOff(_ run: DBRun) async -> Bool
	/// 계정 목록과 전역 권한 (권한 이름은 Privilege.sql)
	func accounts(_ run: DBRun) async throws -> [DBAccount]
	/// 계정 id(user@host) → DB 별 권한
	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]]
	/// 지금 접속한 계정
	func currentUser(_ run: DBRun) async throws -> String?
	/// 계정의 권한 문장들 (SHOW GRANTS)
	func grantStatements(_ run: DBRun, account: String) async throws -> [String]
	/// 서버 상태 요약
	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary
	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process]
	/// 쿼리별 요약 (오래 걸린 순). 못 읽으면 오류
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest]
	/// 서버 변수 전부 (이름, 값)
	func variables(_ run: DBRun) async throws -> [(String, String)]
	/// 이 연결의 번호 (프로세스 목록에서 표시)
	func connectionID(_ run: DBRun) async throws -> Int64?

	/// MCP: DB 의 테이블 목록
	func tableList(_ run: DBRun, schema: String) async throws -> [(name: String, isView: Bool, approxRows: Int?, comment: String)]

	// MARK: SQL 파일 내보내기
	/// 내보내기 파일의 CREATE 문 (기본: createStatement). Oracle 은 외래 키·스키마 이름을 빼서 순서와 상관없이, 다른 스키마에도 넣을 수 있게
	func dumpCreate(_ run: DBRun, schema: String, name: String) async throws -> String?
	/// 내보내기 파일 맨 끝에 붙일 문장 (; 없이. Oracle: 외래 키, 자동 증가 번호 맞추기)
	func dumpTrailer(_ run: DBRun, schema: String, tables: [String]) async throws -> [String]
}

extension SQLMeta {
	func dumpCreate(_ run: DBRun, schema: String, name: String) async throws -> String? {
		try await createStatement(run, .table, schema: schema, name: name)
	}
	func dumpTrailer(_ run: DBRun, schema: String, tables: [String]) async throws -> [String] { [] }
}
