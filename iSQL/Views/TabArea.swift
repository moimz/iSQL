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
	/// 분할이 없을 때 탭을 왼쪽 칸 오른쪽 절반으로 끌고 있으면: "오른쪽 분할로" 안내
	@State private var splitDropHint = false

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
		focused.flatMap { f in f.session.data(tab: f.tab) }
	}

	private var activeTable: TableInfo? { focused.flatMap { $0.session.table($0.tab) } }

	/// 초점 탭이 DB 개요 탭이면 그 개요
	private var activeOverview: DatabaseOverview? {
		focused.flatMap { f in Session.databaseOf(tab: f.tab).map { f.session.overview($0) } }
	}

	/// 쿼리 결과가 초점 탭을 덮고 있는지 (결과는 왼쪽 칸만 덮으니 초점이 오른쪽이면 아님)
	private var resultsCoverFocused: Bool {
		session.queryPanel?.resultsVisible == true && (!model.hasSplit || model.splitFocus == .left)
	}

	/// 구조 보기이고 쿼리 결과가 덮고 있지 않을 때: 쿼리 버튼 자리에 테이블 정보 버튼
	private var structureShown: Bool {
		active?.mode == .structure && !resultsCoverFocused
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
			if let d = active, !resultsCoverFocused {
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
			} else if let o = activeOverview, !resultsCoverFocused {
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
		GeometryReader { geo in
			ZStack(alignment: .top) {
				leftTabs
				// 탭을 오른쪽 절반으로 끌면 분할 자리 안내
				if splitDropHint {
					HStack(spacing: 0) {
						Spacer(minLength: 0)
						RoundedRectangle(cornerRadius: 8)
							.fill(Color.accentColor.opacity(0.12))
							.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
							.overlay { Label("오른쪽 분할로 옮기기", systemImage: "rectangle.righthalf.inset.filled").foregroundStyle(Color.accentColor) }
							.padding(6)
							.frame(width: geo.size.width / 2)
					}
					.allowsHitTesting(false)
				}
				// 결과 보기: 위에서 아래로 스르륵 내려오고, 숨기면 위로 말려 올라간다 (탭바·표·하단바 통째로).
				// 결과가 있는 동안은 결과 화면을 살려 두고 위치만 옮긴다 (보일 때마다 새로 만들면 100ms 씩 멈췄다)
				if let q = session.queryPanel, q.open, !q.outputs.isEmpty {
					QueryResultsOverlay(panel: q)
						.offset(y: q.resultsVisible ? 0 : -geo.size.height - 4)
						.allowsHitTesting(q.resultsVisible)
						.animation(.easeInOut(duration: 0.28), value: q.resultsVisible)
				}
			}
			.frame(width: geo.size.width, height: geo.size.height)
			.clipped()
			// 탭 놓기: 오른쪽 탭 → 왼쪽으로, 왼쪽 탭을 (분할이 없을 때) 오른쪽 절반에 → 오른쪽 분할로
			.onDrop(of: [.utf8PlainText, .plainText], delegate: PaneDropDelegate(width: geo.size.width, splitExists: model.hasSplit, hint: $splitDropHint) { text, rightHalf in
				guard let d = TabDrag(text) else { return }
				if d.side == .right { model.unpark(d.parked) }
				else if !model.hasSplit && rightHalf && d.parked.server == session.server?.id { model.park(d.parked.tab, from: session) }
			})
		}
		// 칸 안 어디를 눌러도 초점은 이쪽 (AppKit 표가 마우스를 먹어서 SwiftUI 탭 제스처로는 못 받는다)
		.background(PaneClickWatcher { if model.hasSplit { model.splitFocus = .left } })
	}

	private var leftTabs: some View {
		VStack(spacing: 0) {
			if !session.tabs.isEmpty {
				TabBar(session: session, paneFocused: !model.hasSplit || model.splitFocus == .left,
				       close: closeLeft, park: { model.park($0, from: session) },
				       duplicate: { model.duplicateToRight($0, from: session) }, drop: dropToLeft)
				Divider()
			}
			ZStack {
				// 보이는 탭 하나만 화면에 두고, 그 화면(과 안의 AppKit 표)을 탭끼리 돌려 쓴다.
				// 탭을 다 살려 두면 애니메이션 프레임마다 숨은 탭까지 다시 배치하고(패널 열기 472ms),
				// 탭마다 화면을 새로 만들면 표를 버리고 새로 만들어 느리다(탭 전환 159ms). 둘 다 Time Profiler 로 확인 (Ai/iSQL.md)
				if let id = session.activeTab, let t = session.table(id) {
					TableDetailView(session: session, tab: id, table: t,
					                onGridScroll: { model.scrollLink.register(.left, $0) })
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
	}

	// MARK: 오른쪽 (임시 영역, 서버를 바꿔도 그대로)

	private var rightPane: some View {
		VStack(spacing: 0) {
			ParkedTabBar(model: model, currentServer: session.server?.id, close: closeRight, drop: dropToRight)
			Divider()
			ZStack {
				if let p = model.parkedActive, let s = model.sessions[p.server] {
					if let t = s.table(p.tab) {
						TableDetailView(session: s, tab: p.tab, table: t, alive: parkedSources,
						                onGridScroll: { model.scrollLink.register(.right, $0) })
					} else if let schema = Session.databaseOf(tab: p.tab) {
						DatabaseOverviewView(session: s, overview: s.overview(schema)).id(p.key)
					} else {
						ContentUnavailableView("테이블이 없습니다", systemImage: "tablecells", description: Text(p.tab))
					}
				}
			}
			// 탭을 오른쪽 칸 본문에 놓으면 오른쪽 맨 뒤로
			.dropDestination(for: String.self) { items, _ in dropToRight(items, before: nil) }
		}
		.background(PaneClickWatcher { model.splitFocus = .right })
	}

	/// 오른쪽에 둔 테이블 탭들의 표 공급자 (오른쪽 칸의 표 호스트가 살려 둘 것)
	private var parkedSources: [GridSource] {
		model.parkedTabs.compactMap { p in model.sessions[p.server]?.data(tab: p.tab) }
	}

	private func rightWidth(total: CGFloat) -> CGFloat {
		let w = splitWidth > 0 ? CGFloat(splitWidth) : total / 2
		return min(max(w, 280), max(280, total - 280))
	}

	/// 두 칸 사이 경계: 끌어서 오른쪽 칸 너비를 바꾼다.
	/// 1pt 선은 분할이 한눈에 안 보여서(사용자 지적) 양쪽 테두리 + 어두운 띠 + 가운데 손잡이
	private func splitHandle(total: CGFloat) -> some View {
		HStack(spacing: 0) {
			Divider()
			// 표 바탕과 확실히 달라 보이게: 글자색을 옅게 깐 띠 (다크면 밝은 회색, 라이트면 어두운 회색).
			// 창 바탕색·underPageBackground 는 다크 모드 표 줄무늬와 거의 같아 안 보였다 (화면으로 확인)
			Color.primary.opacity(0.13)
				.frame(width: 7)
				.overlay {
					Capsule().fill(Color.primary.opacity(0.45)).frame(width: 3, height: 36)
				}
			Divider()
		}
			.overlay {
				Color.clear
					.frame(width: 12)
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

	// MARK: 끌어 놓기

	/// 왼쪽 탭바에 놓기: 왼쪽 탭이면 순서 바꾸기, 오른쪽 탭이면 왼쪽으로 (before 앞, nil 이면 맨 뒤)
	@discardableResult
	private func dropToLeft(_ items: [String], before: String?) -> Bool {
		guard let d = items.first.flatMap(TabDrag.init) else { return false }
		if d.side == .left {
			guard d.parked.server == session.server?.id else { return false }
			session.moveTab(d.parked.tab, before: before)
			session.selectTab(d.parked.tab)
		} else {
			model.unpark(d.parked, before: before)
		}
		return true
	}

	/// 오른쪽 탭바에 놓기: 오른쪽 탭이면 순서 바꾸기, 왼쪽 탭이면 오른쪽으로
	@discardableResult
	private func dropToRight(_ items: [String], before: ParkedTab?) -> Bool {
		guard let d = items.first.flatMap(TabDrag.init) else { return false }
		if d.side == .right {
			model.moveParked(d.parked, before: before)
			model.focusParked(d.parked)
		} else {
			guard d.parked.server == session.server?.id else { return false }
			model.park(d.parked.tab, from: session, before: before)
		}
		return true
	}

	// MARK: 닫기·옮기기

	private func closeLeft(_ id: String) {
		if session.unsavedTables.contains(id) { pendingClose = .left(id) } else { session.closeTab(id) }
	}

	/// 오른쪽 탭 닫기: 그 서버 왼쪽에 같은 테이블이 이미 있으면 닫고, 없으면 왼쪽으로 돌려놓는다 (사용자 결정)
	private func closeRight(_ p: ParkedTab) {
		guard let s = model.sessions[p.server] else { model.closeParked(p); return }
		if s.leftHasSame(as: p.tab) {
			if s.unsavedTables.contains(p.tab) { pendingClose = .right(p) } else { model.closeParked(p) }
		} else {
			model.returnParked(p)
		}
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
	/// 오른쪽 분할에 사본 (같은 테이블을 다른 조건으로)
	let duplicate: (String) -> Void
	/// 끌어 온 탭 놓기 (그 탭 앞, nil 이면 맨 뒤)
	let drop: ([String], String?) -> Bool
	/// 끌어 온 탭이 놓일 자리 (그 탭 왼쪽에 강조색 세로줄)
	@State private var dropTarget: String?
	/// 탭바 빈 곳 위: 맨 뒤에 놓일 자리 (마지막 탭 오른쪽 끝에 세로줄)
	@State private var dropAtEnd = false

	var body: some View {
		TabStrip(selected: session.activeTab) {
			ForEach(session.tabs, id: \.self) { id in
				TabItem(table: session.table(id), id: id,
				        active: session.activeTab == id,
				        // data(for:) 로 만들어 두고 읽어야 loading 이 관찰된다
				        loading: session.data(tab: id)?.loading
				            ?? Session.databaseOf(tab: id).map { session.overview($0).loading } ?? false,
				        stale: session.data(tab: id)?.stale ?? false,
				        unsaved: session.unsavedTables.contains(id),
				        showSchema: needsSchema(id),
				        focused: paneFocused,
				        menu: [TabMenuAction(title: "오른쪽 분할로 옮기기") { park(id) }]
				            + (session.table(id) != nil ? [TabMenuAction(title: "오른쪽 분할에 복제") { duplicate(id) }] : [])) {
					session.selectTab(id)
				} close: {
					close(id)
				}
				.draggable(session.server.map { TabDrag(side: .left, server: $0.id, tab: id).string } ?? "") {
					TabDragPreview(title: session.table(id)?.name ?? Session.databaseOf(tab: id) ?? id, isDatabase: Session.databaseOf(tab: id) != nil)
				}
				.dropDestination(for: String.self) { items, _ in drop(items, id) } isTargeted: { on in
					if on { dropTarget = id } else if dropTarget == id { dropTarget = nil }
				}
				.overlay(alignment: .leading) { if dropTarget == id { DropMarker() } }
				.overlay(alignment: .trailing) { if dropAtEnd && dropTarget == nil && id == session.tabs.last { DropMarker() } }
				.id(id)
			}
		}
		// 탭을 옮기면 탭바 안에서만 짧게 미끄러지게 (바깥 묶음에 animation 을 걸면 표까지 프레임마다 다시 배치된다)
		.animation(.easeOut(duration: 0.18), value: session.tabs)
		.frame(height: 36)
		// 탭이 없는 빈 곳에 놓으면 맨 뒤로
		.dropDestination(for: String.self) { items, _ in drop(items, nil) } isTargeted: { dropAtEnd = $0 }
		// 색 배경은 기본으로 안전 영역(제목바 밑)까지 번진다. 탭바 안에만 칠한다
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	/// 이 탭바에 서로 다른 DB 의 테이블이 섞여 있으면 모든 테이블 탭에 DB 이름을 붙인다
	/// (같은 이름 테이블만 붙이면 어느 탭은 붙고 어느 탭은 안 붙어 헷갈렸다, 사용자 지적)
	private func needsSchema(_ id: String) -> Bool {
		guard session.table(id) != nil else { return false }
		return Set(session.tabs.compactMap { session.table($0)?.schema }).count > 1
	}
}

/// 오른쪽 탭바: 여러 서버의 탭이 섞일 수 있어 탭마다 서버 색 점, 지금 서버가 아니면 서버 이름도
struct ParkedTabBar: View {
	let model: WindowModel
	let currentServer: UUID?
	let close: (ParkedTab) -> Void
	let drop: ([String], ParkedTab?) -> Bool
	@State private var dropTarget: ParkedTab?
	@State private var dropAtEnd = false

	var body: some View {
		HStack(spacing: 0) {
		TabStrip(selected: model.parkedActive?.key) {
			ForEach(model.parkedTabs, id: \.key) { p in
				let s = model.sessions[p.server]
				let t = s?.table(p.tab)
				TabItem(table: t, id: p.tab,
				        active: model.parkedActive == p,
				        loading: s?.data(tab: p.tab)?.loading
				            ?? Session.databaseOf(tab: p.tab).flatMap { db in s.map { $0.overview(db).loading } } ?? false,
				        stale: s?.data(tab: p.tab)?.stale ?? false,
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
				.draggable(TabDrag(side: .right, server: p.server, tab: p.tab).string) {
					TabDragPreview(title: t?.name ?? Session.databaseOf(tab: p.tab) ?? p.tab, isDatabase: Session.databaseOf(tab: p.tab) != nil)
				}
				.dropDestination(for: String.self) { items, _ in drop(items, p) } isTargeted: { on in
					if on { dropTarget = p } else if dropTarget == p { dropTarget = nil }
				}
				.overlay(alignment: .leading) { if dropTarget == p { DropMarker() } }
				.overlay(alignment: .trailing) { if dropAtEnd && dropTarget == nil && p == model.parkedTabs.last { DropMarker() } }
				.id(p.key)
			}
		}
		.animation(.easeOut(duration: 0.18), value: model.parkedTabs)
			Divider()
			// 양쪽 표 스크롤 맞추기 (같은 테이블을 DB·서버끼리 비교할 때)
			Button { model.scrollSync.toggle() } label: {
				Image(systemName: "link")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(model.scrollSync ? Color.accentColor : Color.secondary)
					.frame(width: 30, height: 30)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 3)
			.help(model.scrollSync ? "양쪽 스크롤 맞추기 켜짐 (누르면 끔)" : "양쪽 스크롤 맞추기: 왼쪽·오른쪽 표를 같이 스크롤")
		}
		.frame(height: 36)
		.dropDestination(for: String.self) { items, _ in drop(items, nil) } isTargeted: { dropAtEnd = $0 }
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	/// 오른쪽도 같은 규칙: 서로 다른 (서버, DB) 의 테이블이 섞여 있으면 모든 테이블 탭에 DB 이름
	private func needsSchema(_ p: ParkedTab, _ t: TableInfo?) -> Bool {
		guard t != nil else { return false }
		let dbs = Set(model.parkedTabs.compactMap { q in
			model.sessions[q.server]?.table(q.tab).map { q.server.uuidString + "|" + $0.schema }
		})
		return dbs.count > 1
	}
}

/// 탭을 끄는 동안 마우스에 붙는 작은 알약 (탭 전체를 찍은 그림은 배경·크기가 어색했다)
struct TabDragPreview: View {
	let title: String
	var isDatabase = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: isDatabase ? "cylinder.split.1x2" : "tablecells").foregroundStyle(Color.accentColor)
			Text(title).lineLimit(1)
		}
		.font(.system(size: 13, weight: .medium))
		.padding(.horizontal, 12)
		.frame(height: 28)
		.background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
		.overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
	}
}

/// 양쪽 표의 스크롤을 맞춘다: 왼쪽·오른쪽 칸에서 지금 보이는 표를 기억하고, 한쪽이 움직이면 다른 쪽을 같은 위치로
final class ScrollLink {
	var enabled = false
	private(set) weak var left: NSScrollView?
	private(set) weak var right: NSScrollView?
	private var observed = Set<ObjectIdentifier>()
	private var syncing = false

	func register(_ side: SplitSide, _ scroll: NSScrollView) {
		if side == .left { if left === scroll { return }; left = scroll } else { if right === scroll { return }; right = scroll }
		let clip = scroll.contentView
		if observed.insert(ObjectIdentifier(clip)).inserted {
			clip.postsBoundsChangedNotifications = true
			NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak scroll] _ in
				guard let self, let scroll else { return }
				MainActor.assumeIsolated { self.follow(scroll) }
			}
		}
		// 새로 보이게 된 표는 반대쪽 위치에 맞춘다
		if enabled, let other = side == .left ? right : left { copy(from: other, to: scroll) }
	}

	func alignRightToLeft() {
		if let l = left, let r = right { copy(from: l, to: r) }
	}

	private func follow(_ s: NSScrollView) {
		guard enabled, !syncing else { return }
		guard let other = s === left ? right : (s === right ? left : nil) else { return }
		copy(from: s, to: other)
	}

	private func copy(from a: NSScrollView, to b: NSScrollView) {
		syncing = true
		defer { syncing = false }
		let clip = b.contentView
		// 제목 줄 여백(contentInsets)·문서 크기는 constrainBoundsRect 가 맞춰 준다
		let target = clip.constrainBoundsRect(NSRect(origin: a.contentView.bounds.origin, size: clip.bounds.size)).origin
		guard target != clip.bounds.origin else { return }
		clip.setBoundsOrigin(target)
		b.reflectScrolledClipView(clip)
		Self.syncHeader(b)
	}

	/// 본문만 옮기면 컬럼 제목 줄은 가로로 따라오지 않는다 (화면으로 확인) → 제목 줄 클립도 같은 x 로
	static func syncHeader(_ scroll: NSScrollView) {
		guard let header = (scroll.documentView as? NSTableView)?.headerView,
		      let hclip = header.superview as? NSClipView else { return }
		let x = scroll.contentView.bounds.origin.x
		if hclip.bounds.origin.x != x { hclip.setBoundsOrigin(NSPoint(x: x, y: hclip.bounds.origin.y)) }
	}
}

/// 끌어 온 탭이 놓일 자리 표시 (탭 왼쪽 가장자리 강조색 세로줄)
struct DropMarker: View {
	var body: some View {
		Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
	}
}

/// 본문에 탭 놓기: 놓는 위치(왼쪽/오른쪽 절반)를 알아야 해서 dropDestination 대신 DropDelegate
struct PaneDropDelegate: DropDelegate {
	let width: CGFloat
	let splitExists: Bool
	@Binding var hint: Bool
	let perform: (String, Bool) -> Void

	func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText, .plainText]) }

	func dropUpdated(info: DropInfo) -> DropProposal? {
		let on = !splitExists && info.location.x > width / 2
		if hint != on { hint = on }
		return DropProposal(operation: .move)
	}

	func dropExited(info: DropInfo) { hint = false }

	func performDrop(info: DropInfo) -> Bool {
		let right = info.location.x > width / 2
		hint = false
		guard let p = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
		_ = p.loadObject(ofClass: NSString.self) { obj, _ in
			guard let s = obj as? String else { return }
			DispatchQueue.main.async { perform(s, right) }
		}
		return true
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
			// 누르는 순간 초점을 바꾸면 탭바가 다시 그려지며 진행 중인 탭 클릭(떼는 순간에 일어남)이 사라졌다
			// (오른쪽에 초점이 있을 때 왼쪽 탭을 눌러도 그 탭이 안 골라짐, 사용자 지적) → 뗀 뒤에, 그 이벤트 처리가 끝난 다음 바꾼다
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseDown]) { [weak self] e in
				if let self, e.window === self.window, !self.isHidden,
				   self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
					DispatchQueue.main.async { self.onClick() }
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
			// DB 이름은 테이블 이름에 붙여서 ("html.im_core…", 사이 띄어쓰기 없이)
			TabTitle(prefix: showSchema ? table.map { $0.schema + "." } : nil,
			         text: table?.name ?? Session.databaseOf(tab: id) ?? id, active: active && focused)
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
		// 오른쪽 칸은 서버 이름·DB 이름까지 붙으니 조금 넉넉하게
		.frame(minWidth: 110, maxWidth: 300, alignment: .leading)
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
