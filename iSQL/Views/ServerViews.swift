import SwiftUI

/// 접속 전 사이드바: 서버 목록 (그룹별). 한 번 누르면 가운데 퀵 커넥트에 설정이, 두 번 누르면 접속.
/// 서버를 끌어다 놓으면 그룹을 옮기거나 순서를 바꾸고, 그룹 머리를 끌면 그룹 순서를 바꾼다
struct ServerSidebar: View {
	@Environment(ServerStore.self) private var store
	@Bindable var model: WindowModel
	@State private var deleting: Server?
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
				}
			}
			ForEach(shown, id: \.group) { g in
				Section {
					ForEach(g.servers) { s in
						ServerRow(server: s, state: model.state(s.id)).tag(s.id)
							.draggable(DragItem.server(s.id))
							// 서버 위에 놓으면 그 서버 앞으로
							.dropDestination(for: String.self) { items, _ in
								drop(items, group: g.group, before: s.id)
							}
					}
					if g.servers.isEmpty && searchText.isEmpty {
						Text("서버를 여기로 끌어 놓으세요").font(.caption).foregroundStyle(.tertiary)
							.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
							.dropDestination(for: String.self) { items, _ in drop(items, group: g.group, before: nil) }
					}
				} header: {
					GroupHeader(name: g.group, count: g.servers.count)
						.draggable(DragItem.group(g.group))
						// 그룹 머리에 놓으면: 서버는 그 그룹 맨 뒤로, 그룹은 그 그룹 앞으로
						.dropDestination(for: String.self) { items, _ in drop(items, group: g.group, before: nil) }
						.contextMenu {
							if !g.group.isEmpty {
								Button("그룹 지우기…", role: .destructive) { deletingGroup = g.group }
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
				Button("접속 문자열 복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(s.connectionString, forType: .string)
				}
				Divider()
				Button("지우기…", role: .destructive) { deleting = s }
			}
		} primaryAction: { ids in
			// 두 번 누르면 접속
			if let id = ids.first, let s = store.servers.first(where: { $0.id == id }) { model.open(s) }
		}
		}
		// 한 번 누르기: 접속한 서버면 그 서버로 옮기고(사이드바는 테이블 목록으로),
		// 아니면 다른 서버를 보고 있더라도 퀵 커넥트 화면에 그 서버 설정을 띄운다 (보던 접속은 그대로)
		.onChange(of: model.selectedServerID) { _, id in
			if id == WindowModel.newConnectionID {
				if model.currentID != nil { model.goHome() }
				return
			}
			guard let id, let s = store.servers.first(where: { $0.id == id }) else { return }
			switch model.state(id) {
			case .connected?, .connecting?: model.open(s)
			default: if model.currentID != nil { model.goHome() }
			}
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
		.confirmationDialog("‘\(deleting?.displayName ?? "")’ 서버를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
			Button("지우기", role: .destructive) {
				if let d = deleting {
					if model.selectedServerID == d.id { model.selectedServerID = WindowModel.newConnectionID }
					store.delete(d)
				}
				deleting = nil
			}
		} message: {
			Text("저장한 비밀번호도 키체인에서 지웁니다. 다른 맥에서도 사라집니다.")
		}
		.confirmationDialog("‘\(deletingGroup ?? "")’ 그룹을 지울까요?", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
			Button("지우기", role: .destructive) {
				if let g = deletingGroup { store.deleteGroup(g) }
				deletingGroup = nil
			}
		} message: {
			Text("그룹 안 서버는 지우지 않고 그룹 없음으로 옮깁니다.")
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
	var body: some View {
		HStack(spacing: 9) {
			ServerIcon(color: server.color, size: 30)
			VStack(alignment: .leading, spacing: 1) {
				Text(server.displayName)
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
	var size: CGFloat = 30

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
			.fill(color.swiftUI ?? Color.gray)
			.frame(width: size, height: size)
			.overlay {
				Image(systemName: "cylinder.split.1x2.fill")
					.font(.system(size: size * 0.48, weight: .semibold))
					.foregroundStyle(.white)
			}
	}
}

extension Server {
	var subtitle: String {
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
