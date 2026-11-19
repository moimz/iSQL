import SwiftUI

/// 접속 전 사이드바: 서버 목록 (그룹별). 한 번 누르면 가운데 퀵 커넥트에 설정이, 두 번 누르면 접속.
/// 서버를 끌어다 놓으면 그룹을 옮기거나 순서를 바꾸고, 그룹 머리를 끌면 그룹 순서를 바꾼다
struct ServerSidebar: View {
	@Environment(ServerStore.self) private var store
	@Bindable var model: WindowModel
	@State private var deleting: Server?
	/// 앱 열 때 자동 접속 표시한 서버 (메뉴에서 바꾸면 다시 읽는다)
	@State private var autoIDs = AutoConnect.servers
	@State private var deletingGroup: String?
	@State private var searchText = ""
	@FocusState private var searchFocused: Bool

	/// 검색어(띄어 쓴 낱말 모두)가 이름·호스트·SSH 호스트·사용자·그룹에 들어 있는 서버만. 찾는 동안 빈 그룹은 숨긴다
	private var shown: [(group: String, servers: [Server])] {
		let words = searchText.lowercased().split(separator: " ").map(String.init)
		guard !words.isEmpty else { return store.grouped }
		return store.grouped.compactMap { g in
			let list = g.servers.filter { s in
				let hay = [s.displayName, s.host, s.user, s.ssh.host, s.ssh.user, s.group, s.database].joined(separator: " ").lowercased()
				return words.allSatisfy { hay.contains($0) }
			}
			return list.isEmpty ? nil : (g.group, list)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
		SidebarSearchField(text: $searchText, prompt: "서버 이름, 호스트, 그룹 검색", focused: $searchFocused)
		List(selection: $model.selectedServerID) {
			// 맨 위 "새 접속": 고르면 가운데에 빈 서버 정보 입력 (찾는 동안은 숨김)
			if searchText.isEmpty {
				Section {
					NewConnectionRow().tag(WindowModel.newConnectionID)
						// 앱을 켜면 이미 골라져 있어서, 다른 서버를 보던 중에 눌러도 선택이 안 바뀌어 반응이 없었다 → 서버 줄처럼 다시 눌러도 새 접속 화면으로
						.simultaneousGesture(TapGesture().onEnded { model.newConnectionTapped() })
				}
			}
			ForEach(shown, id: \.group) { g in
				Section {
					ForEach(g.servers) { s in
						ServerRow(server: s, state: model.state(s.id), auto: autoIDs.contains(s.id)).tag(s.id)
							// 이미 고른 줄을 다시 눌러도(선택이 안 바뀌어 onChange 가 안 온다) 서버 정보로
							.simultaneousGesture(TapGesture().onEnded { if model.currentID != nil { model.goHome() } })
							.draggable(DragItem.server(s.id)) {
								DragGhost { ServerRow(server: s, state: model.state(s.id), auto: autoIDs.contains(s.id)) }
							}
					}
					// 줄 사이에 놓기: List 가 놓일 자리에 맥 기본 삽입선(앞에 동그라미)을 그린다 (사용자: 줄 위에 놓는 강조는 어디로 들어가는지 모르겠고 겹쳐 보였다)
					.onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
						insert(providers, group: g.group, servers: g.servers, at: index)
					}
					if g.servers.isEmpty && searchText.isEmpty {
						Text("서버를 여기로 끌어 놓으세요").font(.caption).foregroundStyle(.tertiary)
							.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
							.dropDestination(for: String.self) { items, _ in drop(items, group: g.group, before: nil) }
					}
				} header: {
					GroupHeader(name: g.group, count: g.servers.count)
						.draggable(DragItem.group(g.group)) {
							DragGhost { Label(g.group.isEmpty ? "그룹 없음" : g.group, systemImage: "folder").fontWeight(.semibold) }
						}
						.contextMenu {
							if !g.group.isEmpty {
								Button("그룹 삭제…", role: .destructive) { deletingGroup = g.group }
							}
						}
				}
			}
		}
		.overlay {
			if !searchText.isEmpty && shown.isEmpty { ContentUnavailableView.search(text: searchText) }
		}
		.contextMenu(forSelectionType: Server.ID.self) { ids in
			if let id = ids.first, let s = store.servers.first(where: { $0.id == id }) {
				Button("접속") { model.open(s) }
				Button("복제") { model.selectedServerID = store.duplicate(s).id }
				Toggle("앱 실행 시 자동 접속", isOn: Binding(get: { autoIDs.contains(s.id) },
				                                          set: { _ in AutoConnect.toggle(s.id); autoIDs = AutoConnect.servers }))
				Button("접속 문자열 복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(s.connectionString, forType: .string)
				}
				Divider()
				Button("삭제…", role: .destructive) { deleting = s }
			}
		} primaryAction: { ids in
			// 두 번 누르면 접속 (접속한 서버면 그 서버로 옮긴다)
			if let id = ids.first, let s = store.servers.first(where: { $0.id == id }) { model.open(s) }
		}
		}
		// 한 번 누르기: 접속했든 안 했든 퀵 커넥트 화면에 그 서버 정보를 띄운다 (보던 접속은 그대로).
		// 접속한 서버로 옮기는 것은 두 번 누르기 (사용자 2026-11-17: 접속 안 한 서버와 같게)
		.onChange(of: model.selectedServerID) { _, id in
			if id != nil, model.currentID != nil { model.goHome() }
		}
		// ⌘F 로 검색칸
		.background { Button("") { searchFocused = true }.keyboardShortcut("f").hidden() }
		.safeAreaInset(edge: .bottom) { SyncStatus().padding(10) }
		.toolbar {
			ToolbarItem {
				Menu {
					Button("서버 추가") { model.newConnection() }
					Button("그룹 추가…") { model.addGroup() }
				} label: {
					Label("추가", systemImage: "plus")
				}
				.menuIndicator(.hidden)
				.help("서버 추가 / 그룹 추가")
			}
		}
		.confirmationDialog("‘\(deleting?.displayName ?? "")’ 서버를 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
			Button("삭제", role: .destructive) {
				if let d = deleting {
					if model.selectedServerID == d.id { model.selectedServerID = WindowModel.newConnectionID }
					store.delete(d)
				}
				deleting = nil
			}
		} message: {
			Text("저장한 비밀번호도 키체인에서 삭제합니다. 다른 맥에서도 사라집니다.")
		}
		.confirmationDialog("‘\(deletingGroup ?? "")’ 그룹을 삭제할까요?", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
			Button("삭제", role: .destructive) {
				if let g = deletingGroup { store.deleteGroup(g) }
				deletingGroup = nil
			}
		} message: {
			Text("그룹 안 서버는 삭제하지 않고 그룹 없음으로 옮깁니다.")
		}
	}

	/// 삽입선 자리에 놓았을 때. index = 그 그룹(보이는 목록)에서 들어갈 자리.
	/// 서버 = 그 그룹의 그 자리로, 그룹 = 맨 앞 자리면 이 그룹 앞, 아니면 이 그룹 뒤(다음 그룹 앞)
	private func insert(_ providers: [NSItemProvider], group: String, servers: [Server], at index: Int) {
		guard let p = providers.first else { return }
		_ = p.loadTransferable(type: String.self) { result in
			guard case .success(let text) = result else { return }
			DispatchQueue.main.async {
				guard let item = DragItem(text) else { return }
				switch item {
				case .server(let id):
					store.moveServer(id, toGroup: group, before: index < servers.count ? servers[index].id : nil)
				case .group(let name):
					guard !name.isEmpty else { return }
					if index == 0 && !group.isEmpty {
						store.moveGroup(name, before: group)
					} else {
						let order = store.grouped.map(\.group).filter { !$0.isEmpty && $0 != name }
						let next = group.isEmpty ? order.first : order.firstIndex(of: group).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
						store.moveGroup(name, before: next)
					}
				}
			}
		}
	}

	@discardableResult
	private func drop(_ items: [String], group: String, before: UUID?) -> Bool {
		guard let item = items.first.flatMap(DragItem.init) else { return false }
		switch item {
		case .server(let id):
			store.moveServer(id, toGroup: group, before: before)
		case .group(let name):
			// 그룹 없음 칸은 늘 맨 위라 순서를 바꾸지 않는다
			guard !name.isEmpty else { return false }
			store.moveGroup(name, before: group.isEmpty ? store.grouped.first { !$0.group.isEmpty }?.group : group)
		}
		return true
	}
}

/// 끌 때 커서에 붙는 그림: 바탕 없이 글자만 떠서 알아보기 힘들었다 (사용자) → 창 바탕색 둥근 상자 + 테두리
struct DragGhost<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View {
		content
			.padding(.horizontal, 10).padding(.vertical, 6)
			.frame(width: 240, alignment: .leading)
			.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
	}
}

/// 사이드바에서 끄는 것 (문자열로 주고받는다)
enum DragItem {
	case server(UUID)
	case group(String)

	init?(_ s: String) {
		if s.hasPrefix("isql-server:"), let id = UUID(uuidString: String(s.dropFirst(12))) { self = .server(id) }
		else if s.hasPrefix("isql-group:") { self = .group(String(s.dropFirst(11))) }
		else { return nil }
	}

	static func server(_ id: UUID) -> String { "isql-server:" + id.uuidString }
	static func group(_ name: String) -> String { "isql-group:" + name }
}

struct GroupHeader: View {
	let name: String
	let count: Int
	var body: some View {
		HStack {
			Text(name.isEmpty ? "그룹 없음" : name)
			Spacer()
			// 접속 후 DB 머리의 개수와 같은 작은 알약, 오른쪽에 붙지 않게 여백
			Text("\(count)")
				.font(.system(size: 11, weight: .medium))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.padding(.horizontal, 6).padding(.vertical, 1)
				.background(Capsule().fill(Color.secondary.opacity(0.15)))
				.padding(.trailing, 8)
		}
		.contentShape(Rectangle())
	}
}

/// 그룹 추가 (제목바에 붙는 시트, 이름만)
struct GroupAddSheet: View {
	@Environment(ServerStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	let onAdd: (String) -> Void
	@State private var name = ""
	@FocusState private var focused: Bool

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	private var exists: Bool { store.grouped.contains { $0.group == trimmed } }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("그룹 추가").font(.headline)
			TextField("그룹 이름", text: $name, prompt: Text("회사, 개인 같은 이름"))
				.textFieldStyle(.roundedBorder)
				.focused($focused)
				.onSubmit(add)
			if exists { Text("이미 있는 그룹입니다.").font(.caption).foregroundStyle(.orange) }
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("추가", action: add)
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(trimmed.isEmpty || exists)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 340)
		.onAppear { focused = true }
	}

	private func add() {
		guard !trimmed.isEmpty, !exists else { return }
		store.addGroup(trimmed)
		onAdd(trimmed)
		dismiss()
	}
}

struct ServerRow: View {
	let server: Server
	var state: Session.State?
	/// 앱 열 때 자동 접속
	var auto = false
	var body: some View {
		HStack(spacing: 9) {
			ServerIcon(color: server.color, kind: server.sqlKind, size: 30)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(server.displayName)
					if auto {
						Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.yellow)
							.help("앱 실행 시 자동 접속")
					}
				}
				Text(server.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			if state == .connected {
				Spacer()
				Text("접속 중").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
					.background(Capsule().fill(Color.green.opacity(0.2))).foregroundStyle(.green)
			}
		}
		.padding(.vertical, 2)
	}
}

/// 서버 목록 맨 위 "새 접속" 줄: 서버 줄과 같은 크기의 강조색 N 아이콘
struct NewConnectionRow: View {
	var body: some View {
		HStack(spacing: 9) {
			RoundedRectangle(cornerRadius: 30 * 0.24, style: .continuous)
				.fill(Color.accentColor)
				.frame(width: 30, height: 30)
				.overlay {
					Text("N").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
				}
			VStack(alignment: .leading, spacing: 1) {
				Text("새 접속")
				Text("서버 정보를 입력해 접속").font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
		}
		.padding(.vertical, 2)
	}
}

/// 서버 아이콘: 줄 높이에 맞춘 둥근 정사각형을 서버 색으로 칠하고 DB 아이콘 (색이 없으면 회색)
struct ServerIcon: View {
	let color: ServerColor
	/// DB 종류: 로고가 있으면 드럼 대신 흰 로고 (MySQL 돌고래·MariaDB 물개 — 각 회사의 상표, 접속 종류 표시에만)
	var kind: SQLKind? = nil
	var size: CGFloat = 30

	@Environment(\.colorScheme) private var scheme

	/// 바탕이 밝으면(노랑 등) 흰 로고가 안 보여 어두운 로고 (사용자 2026-11-19)
	private var logoColor: Color {
		guard let c = color.swiftUI else { return .white }
		var env = EnvironmentValues()
		env.colorScheme = scheme
		let r = c.resolve(in: env)
		// 상대 휘도 (sRGB 선형값)
		let l = 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
		return l > 0.55 ? Color.black.opacity(0.72) : .white  // 노랑 0.64~0.69, 초록 0.42~0.47
	}

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
			.fill(color.swiftUI ?? Color.gray)
			.frame(width: size, height: size)
			.overlay {
				if let logo = kind?.logoAsset {
					Image(logo).resizable().renderingMode(.template).scaledToFit()
						.frame(width: size * 0.66, height: size * 0.66)
						.foregroundStyle(logoColor)
				} else {
					Image(systemName: "cylinder.split.1x2.fill")
						.font(.system(size: size * 0.48, weight: .semibold))
						.foregroundStyle(logoColor)
				}
			}
	}
}

extension Server {
	var subtitle: String {
		if isFileDB { return path ?? "" }
		let db = "\(user)@\(host):\(port)"
		return ssh.enabled ? "SSH \(ssh.host) → \(db)" : db
	}
}

/// 사이드바 아래: iCloud 동기화 여부 한 줄 (서버 목록과 키체인 둘 다 iCloud 여야 동기화)
struct SyncStatus: View {
	@Environment(ServerStore.self) private var store
	var body: some View {
		let synced = store.isCloud && Keychain.mode != .localOnly
		Label(synced ? "iCloud 동기화" : "이 맥에만 저장", systemImage: synced ? "checkmark.icloud" : "icloud.slash")
			.font(.caption)
			.foregroundStyle(synced ? Color.secondary : Color.orange)
			.frame(maxWidth: .infinity, alignment: .leading)
			.help(synced ? "서버 목록과 비밀번호(키체인)가 iCloud 로 다른 맥과 동기화됩니다"
			             : (store.isCloud ? "비밀번호가 이 맥 키체인에만 저장됩니다" : "서버 목록이 이 맥에만 저장됩니다"))
	}
}

/// 접속 중 / 실패 화면
struct SessionStatusView: View {
	@Environment(ServerStore.self) private var store
	let model: WindowModel
	let session: Session
	/// 로그인 시트를 닫은 실패 번호 (다시 실패하면 번호가 달라져 다시 띄운다: "다시 시도" 로 또 틀려도)
	@State private var dismissedFailure = -1

	var body: some View {
		switch session.state {
		case .failed(let message):
			VStack(spacing: 16) {
				Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
				Text("\(session.server?.displayName ?? "") 에 접속하지 못했습니다").font(.title2)
				Text(message).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 520)
				HStack {
					Button("설정 고치기") {
						if let s = session.server { model.edit(s, saved: store.servers.contains { $0.id == s.id }) }
					}
					.controlSize(.large)
					Button("다시 시도") { if let s = session.server { model.open(s) } }
						.controlSize(.large).buttonStyle(.borderedProminent)
				}
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			// 아이디·비밀번호가 틀렸으면(또는 비밀번호 없이 저장된 서버) 제목바 시트로 바로 묻는다
			.sheet(isPresented: Binding(get: { session.authFailed && dismissedFailure != session.authFailCount },
			                            set: { if !$0 { dismissedFailure = session.authFailCount } })) {
				if let s = session.server {
					LoginSheet(server: s, saved: store.servers.contains { $0.id == s.id }) { user, pw, save in
						dismissedFailure = session.authFailCount
						Task { await model.retryLogin(s, user: user, password: pw, save: save, store: store) }
					}
				}
			}
		default:
			VStack(spacing: 16) {
				ProgressView().controlSize(.large)
				Text(session.server?.displayName ?? "").font(.title2)
				if case .connecting(let step) = session.state { Text(step).foregroundStyle(.secondary) }
				Button("그만두기") { if let id = session.server?.id { model.disconnect(id) } }.controlSize(.large)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}
}

/// 접속 실패(아이디·비밀번호) 때 묻는 시트: 아이디, 비밀번호, (저장된 서버면) 서버 정보에 저장
struct LoginSheet: View {
	let server: Server
	/// 저장된 서버인지 (퀵 커넥트가 아니면 "서버 정보에 저장" 을 보인다)
	let saved: Bool
	let connect: (_ user: String, _ password: String, _ save: Bool) -> Void
	@State private var user: String
	@State private var password = ""
	@State private var save = true
	@State private var focus = false
	@Environment(\.dismiss) private var dismiss

	init(server: Server, saved: Bool, connect: @escaping (String, String, Bool) -> Void) {
		self.server = server
		self.saved = saved
		self.connect = connect
		_user = State(initialValue: server.user)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(server.displayName) 에 로그인").font(.headline)
			Text("아이디나 비밀번호가 맞지 않습니다. 다른 앱에서 가져온 서버처럼 비밀번호가 저장되지 않았을 수도 있습니다.")
				.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				GridRow {
					Text("아이디:").gridColumnAlignment(.trailing)
					TextField("", text: $user).textFieldStyle(.roundedBorder)
				}
				GridRow {
					Text("비밀번호:")
					PasswordField(text: $password, focus: $focus, onSubmit: go)
				}
			}
			if saved {
				Toggle("접속되면 서버 정보에 저장 (아이디·비밀번호)", isOn: $save).toggleStyle(.checkbox)
			}
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("접속", action: go).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
					.disabled(user.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 420)
		.onAppear { focus = true }
	}

	private func go() {
		let u = user.trimmingCharacters(in: .whitespaces)
		guard !u.isEmpty else { return }
		connect(u, password, saved && save)
		dismiss()
	}
}
