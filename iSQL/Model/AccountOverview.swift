import Foundation

/// 보기만 하는 사용자 계정 (SQL Server 로그인 · 나중에 Oracle 사용자). 고치기는 쿼리 패널에서.
/// MySQL 의 계정 편집(AccountManager · DBAccount)과 달리 DB 종류마다 모양이 달라 이름·값 목록으로 들고 온다 (사용자 2026-11-20: 일단 보기만)
struct AccountOverview {
	var accounts: [AccountInfo] = []
	/// 지금 접속한 계정 이름
	var current = ""
	/// 권한이 모자라 일부만 보일 때 안내 (없으면 nil)
	var note: String?
	/// 탭 이름 (DB 종류마다): 역할 · DB 연결 · 권한
	var roleTitle = "서버 역할"
	var databaseTitle = "데이터베이스"
	var permissionTitle = "서버 권한"
	/// 탭이 비었을 때 글
	var roleEmpty = "역할 없음 (public 만)"
	var databaseEmpty = "이어진 DB 사용자가 없습니다 (기본 DB 외에는 들어갈 수 없거나, sysadmin 이면 모든 DB 를 dbo 로 씁니다)"
	var permissionEmpty = "직접 받은 권한 없음"
}

struct AccountInfo: Identifiable, Hashable {
	var name: String
	/// 목록 둘째 줄 (종류: SQL 로그인 · Windows 로그인 …)
	var kind: String
	/// 접속할 수 없음 (사용 안 함 · 잠김 · 만료)
	var disabled = false
	/// 서버가 만든 계정 (## … · NT SERVICE\ …) — 흐리게
	var system = false
	/// 일반 탭: (이름, 값)
	var fields: [Field] = []
	var roles: [String] = []
	var databases: [Access] = []
	/// 직접 받은 권한 ("GRANT VIEW SERVER STATE")
	var permissions: [String] = []

	var id: String { name }

	struct Field: Hashable { let label: String; let value: String }
	/// DB 하나에 이어진 사용자와 그 DB 의 역할 (Oracle: database = 객체 주인 스키마, roles = 그 스키마 객체에 받은 권한, user 는 비움)
	struct Access: Hashable { let database: String; let user: String; let schema: String; let roles: [String] }
}

extension String {
	/// 비었으면 다른 글 ("—" 등)
	func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
