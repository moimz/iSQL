import Foundation
import Observation

/// 창 하나의 상태: 여러 서버에 동시에 접속해 두고, 제목바 메뉴로 오간다
@Observable
final class WindowModel {
	/// 서버 id → 접속 (접속 중이거나 실패한 것만 있다)
	private(set) var sessions: [UUID: Session] = [:]
	/// 지금 보고 있는 서버 (nil 이면 퀵 커넥트 화면)
	private(set) var currentID: UUID?

	/// 왼쪽 사이드바가 서버 목록인지 테이블 목록인지 (접속한 서버가 있을 때 위쪽 [서버 | 테이블] 로 바꾼다)
	var sidebarMode: SidebarMode = .servers

	/// 퀵 커넥트 화면: 왼쪽 목록에서 고른 저장된 서버 (nil 이면 새 접속 draft)
	var selectedServerID: UUID?
	/// 저장하지 않은 새 접속 내용 (화면을 오가도 남게)
	var draft = Server()
	/// 저장하지 않은 접속의 비밀번호 (다시 시도할 때 쓴다, 메모리에만)
	@ObservationIgnored private var secrets: [UUID: (mysql: String?, ssh: String?)] = [:]

	/// 그룹 추가 시트를 띄웠는지, 추가하면 알려 줄 곳 (퀵 커넥트 폼이 새 그룹을 고르게)
	var addingGroup = false
	@ObservationIgnored var onGroupAdded: ((String) -> Void)?

	var current: Session? { currentID.flatMap { sessions[$0] } }

	func addGroup(then: ((String) -> Void)? = nil) {
		onGroupAdded = then
		addingGroup = true
	}

	/// 퀵 커넥트로 접속한 것(목록에 없는 서버)을 그룹 없이 저장한다. 입력했던 비밀번호도 키체인에 넣는다
	func saveUnsaved(_ id: UUID, to store: ServerStore) {
		guard var server = sessions[id]?.server else { return }
		server.group = ""
		let pw = secrets[id]
		Keychain.set(pw?.mysql, for: server.mysqlPasswordKey)
		Keychain.set(server.ssh.enabled ? pw?.ssh : nil, for: server.sshSecretKey)
		store.save(server)
		if draft.id == server.id { draft = Server() }
	}

	func state(_ id: UUID) -> Session.State? { sessions[id]?.state }

	/// 그 서버로 옮긴다. 접속돼 있지 않으면 접속한다.
	/// 비밀번호를 주면 그것을, 안 주면 앞서 받은 것이나 키체인 것을 쓴다
	@MainActor
	func open(_ server: Server, mysqlPassword: String? = nil, sshSecret: String? = nil, given: Bool = false) {
		if given { secrets[server.id] = (mysqlPassword, sshSecret) }
		currentID = server.id
		if let s = sessions[server.id] {
			switch s.state {
			case .connected, .connecting: return
			default: break
			}
		}
		let pw = secrets[server.id] ?? (Keychain.get(server.mysqlPasswordKey), Keychain.get(server.sshSecretKey))
		let s = sessions[server.id] ?? Session()
		sessions[server.id] = s
		Task { await s.connect(server, mysqlPassword: pw.mysql, sshSecret: pw.ssh) }
	}

	func disconnect(_ id: UUID) {
		sessions[id]?.disconnect()
		sessions[id] = nil
		secrets[id] = nil
		if currentID == id { currentID = nil }
	}

	/// 퀵 커넥트 화면으로 (접속은 그대로 둔다)
	func goHome() { currentID = nil }

	/// 새 접속 화면
	func newConnection() {
		currentID = nil
		selectedServerID = nil
	}

	/// 접속을 끊고 그 설정을 퀵 커넥트 화면에서 고친다
	func edit(_ server: Server, saved: Bool) {
		disconnect(server.id)
		if saved { selectedServerID = server.id } else { draft = server; selectedServerID = nil }
	}
}

enum SidebarMode { case servers, tables }
