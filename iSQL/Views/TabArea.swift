import SwiftUI

/// 접속한 서버의 본문: 탭바 + 지금 탭. 탭은 서버마다 따로 있다.
/// 열린 탭은 모두 살려 두고 보이기만 바꾼다 (탭을 바꿀 때마다 표를 새로 만들면 뚝뚝 끊긴다).
/// 그래서 툴바·단축키는 탭마다가 아니라 여기서 지금 탭에 대해 한 번만 단다 (숨은 탭 것까지 겹치지 않게)
struct TabArea: View {
	/// 지금 서버 (왼쪽 탭바·사이드바·쿼리 패널)
	let session: Session
	/// 오른쪽 분할(임시 영역)과 초점은 창이 들고 있다 (서버를 바꿔도 그대로)
	let model: WindowModel
	@State private var pendingClose: PendingClose?
	/// 오른쪽 칸 너비 (0 이면 반)
	@AppStorage("splitRightWidth") private var splitWidth: Double = 0
	@State private var dragStartWidth: Double?

	private enum PendingClose {
		case left(String)
		case right(ParkedTab)
	}

	/// 초점이 있는 탭 (양쪽을 통틀어 하나): 그 탭의 서버와 탭 id. 제목바 버튼·단축키는 이 탭에 대해 움직인다
	private var focused: (session: Session, tab: String)? {
		if model.splitFocus == .right, let p = model.parkedActive, let s = model.sessions[p.server] { return (s, p.tab) }
		return session.activeTab.map { (session, $0) }
	}

	private var focusedSession: Session { focused?.session ?? session }

	private var active: TableData? {
		focused.flatMap { f in f.session.table(f.tab).map { f.session.data(for: $0) } }
	}

	private var activeTable: TableInfo? { focused.flatMap { $0.session.table($0.tab) } }

	/// 초점 탭이 DB 개요 탭이면 그 개요
	private var activeOverview: DatabaseOverview? {
		focused.flatMap { f in Session.databaseOf(tab: f.tab).map { f.session.overview($0) } }
	}

	/// 구조 보기이고 쿼리 결과가 덮고 있지 않을 때: 쿼리 버튼 자리에 테이블 정보 버튼
	private var structureShown: Bool {
		active?.mode == .structure && session.queryPanel?.resultsVisible != true
	}

	var body: some View {
		GeometryReader { geo in
			HStack(spacing: 0) {
				leftPane
					.frame(maxWidth: .infinity)
				if model.hasSplit {
					splitHandle(total: geo.size.width)
					rightPane
						.frame(width: rightWidth(total: geo.size.width))
				}
				// 구조 보기 오른쪽 테이블 정보 패널. SwiftUI .inspector 는 맥 26 에서 붙인 뷰가 사이드바·툴바 밑으로
				// 파고들어(안전 영역을 잃음, 화면으로 확인) 직접 옆 칸으로 그린다
				if focusedSession.showTableInfo && structureShown, let t = activeTable {
					Divider()
					TableInfoPanel(session: focusedSession, inspector: focusedSession.inspector(for: t), columns: focusedSession.columns[t.id] ?? [])
						.id(t.id)
						.frame(width: 320)
						.transition(.move(edge: .trailing))
				}
			}
			.clipped()
			.animation(.easeOut(duration: 0.2), value: focusedSession.showTableInfo)
		}
		// 숨은 탭의 표가 키 입력(⌫ 등)을 받지 않게 탭을 바꾸면 입력 초점을 놓는다
		.onChange(of: session.activeTab) {
			NSApp.keyWindow?.makeFirstResponder(nil)
		}
		.onChange(of: model.parkedActive) {
			NSApp.keyWindow?.makeFirstResponder(nil)
		}
		// 왼쪽 탭을 열거나 고르면 초점은 왼쪽
		.onChange(of: session.leftFocusTick) {
			model.splitFocus = .left
		}
		// 제목바 오른쪽 끝: [검색 | 새로 고침] (데이터 보기일 때) + [데이터 | 구조].
		// 창 전체가 아니라 detail 본문 뷰에 붙여야 오른쪽 정렬과 묶음 나누기가 된다 (Ai/iSQL.md 툴바 규칙)
		.toolbar {
			ToolbarSpacer(.flexible)
			// 쿼리 결과가 탭을 덮고 있으면 탭용 버튼은 숨긴다
			if let d = active, session.queryPanel?.resultsVisible != true {
				if d.mode == .data {
					ToolbarItemGroup {
						Button {
							d.showFilter.toggle()
						} label: {
							Image(systemName: "magnifyingglass")
								.foregroundStyle(d.showFilter || !d.whereClause.isEmpty ? Color.accentColor : Color.primary)
						}
						.help(d.whereClause.isEmpty ? "조건으로 찾기 (⌥⌘F)" : "조건으로 찾기 (⌥⌘F)\nWHERE \(d.whereClause)")
						Button {
							// 다시 읽으면 저장 안 한 변경이 사라지므로 그때는 하지 않는다
							if d.hasChanges { NSSound.beep() } else { Task { await d.load(offset: d.offset) } }
						} label: {
							Image(systemName: "arrow.clockwise")
						}
						.help(d.hasChanges ? "저장 안 된 변경이 있어 다시 읽지 않습니다" : "데이터 다시 읽기")
					}
					ToolbarSpacer(.fixed)
				}
				ToolbarItem {
					ModeSegment(selection: Binding(get: { d.mode == .data ? 0 : 1 }, set: { d.mode = $0 == 0 ? .data : .structure }))
						.fixedSize()
				}
				ToolbarSpacer(.fixed)
			} else if let o = activeOverview, session.queryPanel?.resultsVisible != true {
				// DB 개요: 테이블 이름·코멘트 검색 (⌥⌘F)
				ToolbarItem {
					Button {
						o.showSearch.toggle()
						if !o.showSearch { o.searchText = "" }
					} label: {
						Image(systemName: "magnifyingglass")
							.foregroundStyle(o.showSearch || o.isFiltered ? Color.accentColor : Color.primary)
					}
					.help("테이블 찾기 (⌥⌘F)")
				}
				ToolbarSpacer(.fixed)
			}
			if structureShown {
				// 구조 보기: 쿼리 버튼 대신 테이블 정보 패널 (⌥⌘I). 쿼리 패널은 ⌘J 로 여전히 열린다
				ToolbarItem {
					Button {
						focusedSession.showTableInfo.toggle()
					} label: {
						Image(systemName: "sidebar.right")
							.foregroundStyle(focusedSession.showTableInfo ? Color.accentColor : Color.primary)
					}
					.help("테이블 정보 (⌥⌘I)")
				}
			} else {
				// 쿼리: 탭이 없어도 접속만 돼 있으면 늘 보인다 (⌘J)
				ToolbarItem {
					Button {
						session.queryPanel?.open.toggle()
					} label: {
						Image(systemName: "terminal")
							.foregroundStyle(session.queryPanel?.open == true ? Color.accentColor : Color.primary)
					}
					.help("쿼리 (⌘J)")
				}
			}
		}
		.background {
			Group {
				// ⌘⇧W 탭 닫기, ⌘⇧[ ] 탭 옮기기 (초점 쪽에서)
				Button("") { closeFocused() }.keyboardShortcut("w", modifiers: [.command, .shift])
				Button("") { move(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
				Button("") { move(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
				// ⌘S 저장, ⌘1 데이터, ⌘2 구조, ⌥⌘F 조건 줄
				Button("") { if let d = active { Task { await d.saveIfNeeded() } } }.keyboardShortcut("s")
				Button("") { active?.mode = .data }.keyboardShortcut("1")
				Button("") { active?.mode = .structure }.keyboardShortcut("2")
				Button("") {
					if let d = active { d.mode = .data; d.showFilter.toggle() }
					else if let o = activeOverview { o.showSearch.toggle(); if !o.showSearch { o.searchText = "" } }
				}.keyboardShortcut("f", modifiers: [.command, .option])
				// ⌘J 쿼리 패널 열기/닫기
				Button("") { session.queryPanel?.open.toggle() }.keyboardShortcut("j")
				// ⌥⌘I 테이블 정보 (구조 보기로 바꿔서)
				Button("") { if let d = active { d.mode = .structure; focusedSession.showTableInfo.toggle() } }.keyboardShortcut("i", modifiers: [.command, .option])
			}
			.hidden()
		}
		.confirmationDialog("저장 안 된 변경이 있습니다", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })) {
			Button("버리고 닫기", role: .destructive) {
				switch pendingClose {
				case .left(let id): session.closeTab(id)
				case .right(let p): model.closeParked(p)
				case nil: break
				}
				pendingClose = nil
			}
		} message: {
			Text("이 탭을 닫으면 저장하지 않은 변경이 사라집니다.")
		}
	}

	// MARK: 왼쪽 (지금 서버의 탭)

	private var leftPane: some View {
		VStack(spacing: 0) {
			if !session.tabs.isEmpty {
				TabBar(session: session, paneFocused: !model.hasSplit || model.splitFocus == .left,
				       close: closeLeft, park: { model.park($0, from: session) })
				Divider()
			}
			ZStack {
				// 보이는 탭 하나만 화면에 두고, 그 화면(과 안의 AppKit 표)을 탭끼리 돌려 쓴다.
				// 탭을 다 살려 두면 애니메이션 프레임마다 숨은 탭까지 다시 배치하고(패널 열기 472ms),
				// 탭마다 화면을 새로 만들면 표를 버리고 새로 만들어 느리다(탭 전환 159ms). 둘 다 Time Profiler 로 확인 (Ai/iSQL.md)
				if let id = session.activeTab, let t = session.table(id) {
					TableDetailView(session: session, table: t)
				} else if let id = session.activeTab, let schema = Session.databaseOf(tab: id) {
					// DB 개요 탭
					DatabaseOverviewView(session: session, overview: session.overview(schema)).id(id)
				}
				if session.activeTab == nil {
					ContentUnavailableView("테이블을 고르세요", systemImage: "tablecells",
					                       description: Text("왼쪽 목록에서 누르면 탭으로 열립니다. ⌘F 로 테이블 이름, 코멘트, 컬럼을 찾을 수 있습니다."))
				}
			}
		}
		// 칸 안 어디를 눌러도 초점은 이쪽 (AppKit 표가 마우스를 먹어서 SwiftUI 탭 제스처로는 못 받는다)
		.background(PaneClickWatcher { if model.hasSplit { model.splitFocus = .left } })
	}

	// MARK: 오른쪽 (임시 영역, 서버를 바꿔도 그대로)

	private var rightPane: some View {
		VStack(spacing: 0) {
			ParkedTabBar(model: model, currentServer: session.server?.id, close: closeRight)
			Divider()
			ZStack {
				if let p = model.parkedActive, let s = model.sessions[p.server] {
					if let t = s.table(p.tab) {
						TableDetailView(session: s, table: t, alive: parkedSources)
					} else if let schema = Session.databaseOf(tab: p.tab) {
						DatabaseOverviewView(session: s, overview: s.overview(schema)).id(p.key)
					} else {
						ContentUnavailableView("테이블이 없습니다", systemImage: "tablecells", description: Text(p.tab))
					}
				}
			}
		}
		.background(PaneClickWatcher { model.splitFocus = .right })
	}

	/// 오른쪽에 둔 테이블 탭들의 표 공급자 (오른쪽 칸의 표 호스트가 살려 둘 것)
	private var parkedSources: [GridSource] {
		model.parkedTabs.compactMap { p in
			model.sessions[p.server].flatMap { s in s.table(p.tab).map { s.data(for: $0) } }
		}
	}

	private func rightWidth(total: CGFloat) -> CGFloat {
		let w = splitWidth > 0 ? CGFloat(splitWidth) : total / 2
		return min(max(w, 280), max(280, total - 280))
	}

	/// 두 칸 사이 경계: 끌어서 오른쪽 칸 너비를 바꾼다
	private func splitHandle(total: CGFloat) -> some View {
		Divider()
			.overlay {
				Color.clear
					.frame(width: 8)
					.contentShape(Rectangle())
					.onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
					.gesture(DragGesture(minimumDistance: 1)
						.onChanged { v in
							if dragStartWidth == nil { dragStartWidth = Double(rightWidth(total: total)) }
							let w = (dragStartWidth ?? 0) - Double(v.translation.width)
							splitWidth = min(max(w, 280), Double(max(280, total - 280)))
						}
						.onEnded { _ in dragStartWidth = nil })
			}
	}

	// MARK: 닫기·옮기기

	private func closeLeft(_ id: String) {
		if session.unsavedTables.contains(id) { pendingClose = .left(id) } else { session.closeTab(id) }
	}

	private func closeRight(_ p: ParkedTab) {
		if model.sessions[p.server]?.unsavedTables.contains(p.tab) == true { pendingClose = .right(p) } else { model.closeParked(p) }
	}

	private func closeFocused() {
		if model.splitFocus == .right, let p = model.parkedActive { closeRight(p) }
		else if let id = session.activeTab { closeLeft(id) }
	}

	private func move(_ d: Int) {
		if model.splitFocus == .right, let p = model.parkedActive, let i = model.parkedTabs.firstIndex(of: p) {
			let list = model.parkedTabs
			model.focusParked(list[(i + d + list.count) % list.count])
			return
		}
		guard let a = session.activeTab, let i = session.tabs.firstIndex(of: a), !session.tabs.isEmpty else { return }
		session.selectTab(session.tabs[(i + d + session.tabs.count) % session.tabs.count])
	}
}

/// 왼쪽 탭바: 지금 서버의 탭
struct TabBar: View {
	let session: Session
	/// 이 칸에 초점이 있는지 (고른 탭의 강조색 윗줄은 초점 칸에만)
	var paneFocused = true
	let close: (String) -> Void
	/// 오른쪽 분할로 옮기기
	let park: (String) -> Void

	var body: some View {
		TabStrip(selected: session.activeTab) {
			ForEach(session.tabs, id: \.self) { id in
				TabItem(table: session.table(id), id: id,
				        active: session.activeTab == id,
				        // data(for:) 로 만들어 두고 읽어야 loading 이 관찰된다
				        loading: session.table(id).map { session.data(for: $0).loading }
				            ?? Session.databaseOf(tab: id).map { session.overview($0).loading } ?? false,
				        stale: session.table(id).map { session.data(for: $0).stale } ?? false,
				        unsaved: session.unsavedTables.contains(id),
				        showSchema: needsSchema(id),
				        focused: paneFocused,
				        menu: [TabMenuAction(title: "오른쪽 분할로 옮기기") { park(id) }]) {
					session.selectTab(id)
				} close: {
					close(id)
				}
				.id(id)
			}
		}
		.frame(height: 36)
		// 색 배경은 기본으로 안전 영역(제목바 밑)까지 번진다. 탭바 안에만 칠한다
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	/// 같은 이름의 테이블이 다른 DB 에도 열려 있으면 DB 이름을 같이 보여 준다
	private func needsSchema(_ id: String) -> Bool {
		guard let t = session.table(id) else { return false }
		return session.tabs.contains { $0 != id && session.table($0)?.name == t.name }
	}
}

/// 오른쪽 탭바: 여러 서버의 탭이 섞일 수 있어 탭마다 서버 색 점, 지금 서버가 아니면 서버 이름도
struct ParkedTabBar: View {
	let model: WindowModel
	let currentServer: UUID?
	let close: (ParkedTab) -> Void

	var body: some View {
		TabStrip(selected: model.parkedActive?.key) {
			ForEach(model.parkedTabs, id: \.key) { p in
				let s = model.sessions[p.server]
				let t = s?.table(p.tab)
				TabItem(table: t, id: p.tab,
				        active: model.parkedActive == p,
				        loading: t.flatMap { tt in s.map { $0.data(for: tt).loading } }
				            ?? Session.databaseOf(tab: p.tab).flatMap { db in s.map { $0.overview(db).loading } } ?? false,
				        stale: t.flatMap { tt in s.map { $0.data(for: tt).stale } } ?? false,
				        unsaved: s?.unsavedTables.contains(p.tab) ?? false,
				        showSchema: needsSchema(p, t),
				        focused: model.splitFocus == .right,
				        server: s?.server.map { srv in
				            TabServer(name: p.server == currentServer ? nil : srv.displayName, color: srv.color.swiftUI)
				        },
				        menu: [TabMenuAction(title: "왼쪽으로 옮기기") { model.unpark(p) }]) {
					model.focusParked(p)
				} close: {
					close(p)
				}
				.id(p.key)
			}
		}
		.frame(height: 36)
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	private func needsSchema(_ p: ParkedTab, _ t: TableInfo?) -> Bool {
		guard let t else { return false }
		return model.parkedTabs.contains { q in
			q != p && model.sessions[q.server]?.table(q.tab)?.name == t.name
		}
	}
}

/// 탭 오른쪽 클릭 메뉴에 더할 항목
struct TabMenuAction {
	let title: String
	let run: () -> Void
}

/// 오른쪽 칸 탭의 서버 표시: 색 점 (+ 지금 서버가 아니면 이름)
struct TabServer {
	let name: String?
	let color: Color?
}

/// 칸 안을 누르면 알려 준다. AppKit 표가 마우스를 먹어 SwiftUI 제스처로는 못 받으므로 창의 마우스 누름을 엿본다
struct PaneClickWatcher: NSViewRepresentable {
	let onClick: () -> Void

	final class WatchView: NSView {
		var onClick: () -> Void = {}
		private var monitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
				if let self, e.window === self.window, !self.isHidden,
				   self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
					self.onClick()
				}
				return e
			}
		}

		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}

	func makeNSView(context: Context) -> WatchView {
		let v = WatchView()
		v.onClick = onClick
		return v
	}

	func updateNSView(_ v: WatchView, context: Context) { v.onClick = onClick }

	static func dismantleNSView(_ v: WatchView, coordinator: ()) {
		v.removeFromSuperview()
	}
}

struct TabItem: View {
	let table: TableInfo?
	let id: String
	let active: Bool
	var loading = false
	/// 쿼리 패널에서 이 테이블을 바꿔서 다시 읽어야 함
	var stale = false
	let unsaved: Bool
	let showSchema: Bool
	/// 이 탭이 있는 칸에 초점이 있는지 (고른 탭 강조색 윗줄은 초점 칸에만: 활성 탭은 양쪽 통틀어 하나)
	var focused = true
	/// 오른쪽 칸: 서버 색 점 (+ 이름)
	var server: TabServer? = nil
	/// 오른쪽 클릭 메뉴에 더할 항목 (분할로 옮기기 등)
	var menu: [TabMenuAction] = []
	let select: () -> Void
	let close: () -> Void
	@State private var hover = false

	var body: some View {
		HStack(spacing: 6) {
			// 받아오는 중이면 아이콘 자리에 로딩
			Group {
				if loading {
					ProgressView().controlSize(.mini)
				} else {
					Image(systemName: Session.databaseOf(tab: id) != nil ? "cylinder.split.1x2" : (table?.isView == true ? "eye" : "tablecells"))
						.font(.system(size: 11))
						.foregroundStyle(active && focused ? Color.accentColor : .secondary)
				}
			}
			.frame(width: 14, height: 14)
			if let srv = server {
				Circle().fill(srv.color ?? .secondary).frame(width: 7, height: 7)
				if let n = srv.name { Text(n).foregroundStyle(.secondary).lineLimit(1) }
			}
			if showSchema, let s = table?.schema {
				Text(s + ".").foregroundStyle(.secondary)
			}
			TabTitle(text: table?.name ?? Session.databaseOf(tab: id) ?? id, active: active && focused)
			if stale {
				Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
					.help("쿼리로 바뀌었습니다. 다시 읽으세요")
			}
			// X 는 탭 오른쪽 끝에 (이름이 짧아도 최소 너비 안에서 가운데로 밀리지 않게)
			Spacer(minLength: 4)
			// 저장 안 된 변경이 있으면 점, 마우스를 올리면 닫기 버튼
			ZStack {
				if unsaved && !hover {
					Circle().fill(.orange).frame(width: 7, height: 7)
				} else {
					Button(action: close) {
						Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
							.frame(width: 16, height: 16)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.opacity(hover || active ? 1 : 0)
					.help("탭 닫기 (⌘⇧W)")
				}
			}
			.frame(width: 16, height: 16)
		}
		.padding(.leading, 12)
		.padding(.trailing, 6)
		.frame(height: 36)
		// 최소 너비 안에서 가운데 정렬되면 짧은 이름 탭만 아이콘·X 가 밀려 보였다 → 왼쪽부터
		.frame(minWidth: 110, maxWidth: 240, alignment: .leading)
		.background(active ? Color(nsColor: .windowBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { if active && focused { Rectangle().fill(Color.accentColor).frame(height: 2) } }
		.overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.onTapGesture(perform: select)
		.help(table.map { $0.comment.isEmpty ? $0.id : "\($0.id)\n\($0.comment)" } ?? Session.databaseOf(tab: id).map { "DB \($0)" } ?? id)
		.contextMenu {
			ForEach(menu.indices, id: \.self) { i in Button(menu[i].title, action: menu[i].run) }
			if !menu.isEmpty { Divider() }
			Button("탭 닫기", action: close)
		}
	}
}
