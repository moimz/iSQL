import Foundation
import Observation

/// 창 하나의 상태: 여러 서버에 동시에 접속해 두고, 제목바 메뉴로 오간다
@Observable
final class WindowModel {
	/// 서버 id → 접속 (접속 중이거나 실패한 것만 있다)
	private(set) var sessions: [UUID: Session] = [:]
	/// 지금 보고 있는 서버 (nil 이면 퀵 커넥트 화면)
	private(set) var currentID: UUID?

	/// 오른쪽 분할에 둔 탭 (순서대로)과 그중 보이는 탭, 초점이 있는 쪽
	var parkedTabs: [ParkedTab] = []
	var parkedActive: ParkedTab?
	var splitFocus: SplitSide = .left
	/// 콘솔 패널 (하단바 아래, ⇧⌘L)
	var showConsole = false
	/// 양쪽 표 스크롤 맞추기 (오른쪽 탭바 끝 버튼)
	var scrollSync = false {
		didSet { applyScrollLink() }
	}
	/// 쿼리 결과가 왼쪽 칸을 덮고 있으면 맞추기를 잠시 멈춘다 (가려진 표끼리 맞추면 풀린 것처럼 보였다)
	var scrollPaused = false {
		didSet { if scrollPaused != oldValue { applyScrollLink() } }
	}
	private func applyScrollLink() {
		scrollLink.enabled = scrollSync && !scrollPaused
		if scrollLink.enabled { scrollLink.alignRightToLeft() }
	}
	@ObservationIgnored let scrollLink = ScrollLink()

	/// 왼쪽 사이드바가 서버 목록인지 테이블 목록인지 (접속한 서버가 있을 때 위쪽 [서버 | 테이블] 로 바꾼다)
	var sidebarMode: SidebarMode = .servers

	/// 서버 목록 맨 위 "새 접속" 줄의 id (저장된 서버와 겹치지 않는 고정값)
	static let newConnectionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

	/// 퀵 커넥트 화면: 왼쪽 목록에서 고른 저장된 서버 (newConnectionID·nil 이면 새 접속 draft). 앱을 켜면 새 접속
	var selectedServerID: UUID? = WindowModel.newConnectionID
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
		let sid = server.id
		s.focusParked = { [weak self] tab in self?.focusParked(ParkedTab(server: sid, tab: tab)) }
		s.closeParkedTab = { [weak self] tab in self?.closeParked(ParkedTab(server: sid, tab: tab)) }
		// 사이드바 "오른쪽 분할에 열기": 왼쪽에 열려 있으면 그 탭의 사본을, 아니면 새로 열어 오른쪽으로
		s.openInSplit = { [weak self, weak s] t in
			guard let self, let s else { return }
			if let tab = s.tabs.first(where: { Session.tableID(ofTab: $0) == t.id }) {
				self.duplicateToRight(tab, from: s)
			} else {
				s.openTab(t)
				if let tab = s.activeTab { self.park(tab, from: s) }
			}
		}
		sessions[server.id] = s
		Task { await s.connect(server, mysqlPassword: pw.mysql, sshSecret: pw.ssh) }
	}

	func disconnect(_ id: UUID) {
		// 오른쪽에 둔 그 서버 탭도 닫힌다
		for p in parkedTabs where p.server == id { removeParked(p) }
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
		selectedServerID = Self.newConnectionID
	}

	/// 접속을 끊고 그 설정을 퀵 커넥트 화면에서 고친다
	func edit(_ server: Server, saved: Bool) {
		disconnect(server.id)
		if saved { selectedServerID = server.id } else { draft = server; selectedServerID = Self.newConnectionID }
	}
}

enum SidebarMode { case servers, tables }

/// 오른쪽 분할(임시 영역)에 둔 탭: 어느 서버의 어느 탭인지
struct ParkedTab: Hashable {
	let server: UUID
	let tab: String
	/// 탭바용 id (서버가 달라도 겹치지 않게)
	var key: String { server.uuidString + "|" + tab }
}

/// 왼쪽·오른쪽 중 초점이 있는 쪽. 활성 탭은 양쪽을 통틀어 하나 (초점 쪽에서 고른 탭)
enum SplitSide { case left, right }

/// 오른쪽 분할: 서버를 바꿔도 그대로 있는 임시 영역. 탭은 각자 자기 서버 Session 의 데이터를 쓴다
extension WindowModel {
	var hasSplit: Bool { !parkedTabs.isEmpty }

	/// 왼쪽 탭을 오른쪽으로 옮긴다 (before 탭 앞에, nil 이면 맨 뒤)
	func park(_ tab: String, from session: Session, before: ParkedTab? = nil) {
		guard let id = session.server?.id else { return }
		let p = ParkedTab(server: id, tab: tab)
		session.park(tab)
		if !parkedTabs.contains(p) {
			if let b = before, let j = parkedTabs.firstIndex(of: b) { parkedTabs.insert(p, at: j) } else { parkedTabs.append(p) }
		}
		parkedActive = p
		splitFocus = .right
	}

	/// 왼쪽 탭의 사본을 오른쪽에 (같은 테이블을 다른 조건으로 나란히 보기)
	func duplicateToRight(_ tab: String, from session: Session) {
		guard let id = session.server?.id, let copy = session.duplicateToParked(tab) else { return }
		let p = ParkedTab(server: id, tab: copy)
		parkedTabs.append(p)
		parkedActive = p
		splitFocus = .right
	}

	/// 오른쪽 탭을 그 서버의 왼쪽 탭으로 돌려놓는다 (서버는 바꾸지 않는다). 오른쪽 탭 닫기에서
	func returnParked(_ p: ParkedTab) {
		removeParked(p)
		sessions[p.server]?.unpark(p.tab)
	}

	/// 오른쪽 탭 순서 바꾸기 (끌어 놓기)
	func moveParked(_ p: ParkedTab, before: ParkedTab?) {
		guard p != before, let i = parkedTabs.firstIndex(of: p) else { return }
		parkedTabs.remove(at: i)
		if let b = before, let j = parkedTabs.firstIndex(of: b) { parkedTabs.insert(p, at: j) } else { parkedTabs.append(p) }
	}

	/// 오른쪽 탭을 왼쪽으로. 다른 서버 탭이면 그 서버로 바꾼 뒤 그 서버 왼쪽 탭에 넣는다 (그때 before 는 무시)
	@MainActor
	func unpark(_ p: ParkedTab, before: String? = nil) {
		guard let s = sessions[p.server] else { removeParked(p); return }
		removeParked(p)
		let sameServer = currentID == p.server
		if !sameServer, let server = s.server { open(server) }
		s.unpark(p.tab, before: sameServer ? before : nil)
		splitFocus = .left
	}

	/// 오른쪽 탭 닫기 (저장 안 한 변경 확인은 부르는 쪽에서)
	func closeParked(_ p: ParkedTab) {
		sessions[p.server]?.closeParked(p.tab)
		removeParked(p)
	}

	/// 오른쪽 탭을 고른다
	func focusParked(_ p: ParkedTab) {
		guard parkedTabs.contains(p) else { return }
		parkedActive = p
		splitFocus = .right
	}

	/// 목록에서만 뺀다 (보이던 탭이면 옆 탭을 보이고, 다 빠지면 분할이 닫히고 초점은 왼쪽)
	func removeParked(_ p: ParkedTab) {
		guard let i = parkedTabs.firstIndex(of: p) else { return }
		parkedTabs.remove(at: i)
		if parkedActive == p { parkedActive = parkedTabs.isEmpty ? nil : parkedTabs[min(i, parkedTabs.count - 1)] }
		if parkedTabs.isEmpty { splitFocus = .left }
	}
}

