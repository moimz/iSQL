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
		focused.flatMap { f in f.session.data(tab: f.tab) }
	}

	/// 초점 탭이 DB 개요 탭이면 그 개요
	private var activeOverview: DatabaseOverview? {
		focused.flatMap { f in Session.databaseOf(tab: f.tab).map { f.session.overview($0) } }
	}

	/// 쿼리 결과가 초점 탭을 덮고 있는지 (결과는 왼쪽 칸만 덮으니 초점이 오른쪽이면 아님)
	private var resultsCoverFocused: Bool {
		session.queryPanel?.resultsVisible == true && (!model.hasSplit || model.splitFocus == .left)
	}

	/// 초점 칸의 테이블 정보 패널을 켰는지 (패널은 칸마다 따로: 왼쪽은 서버별 기억, 오른쪽은 창이 든다)
	private var focusedInfoOn: Bool {
		model.hasSplit && model.splitFocus == .right ? model.showRightInfo : session.showTableInfo
	}

	private func toggleFocusedInfo() {
		if model.hasSplit && model.splitFocus == .right { model.showRightInfo.toggle() } else { session.showTableInfo.toggle() }
	}

	/// 왼쪽 칸 정보 패널: 왼쪽 탭이 구조 보기이고 쿼리 결과가 덮고 있지 않을 때
	private var leftInfoTable: TableInfo? {
		guard session.showTableInfo, !(session.queryPanel.map { $0.open && !$0.outputs.isEmpty && $0.resultsVisible } ?? false),
		      let id = session.activeTab, session.data(tab: id)?.mode == .structure else { return nil }
		return session.table(id)
	}

	/// 오른쪽 칸 정보 패널
	private var rightInfo: (Session, TableInfo)? {
		guard model.showRightInfo, let p = model.parkedActive, let s = model.sessions[p.server],
		      s.data(tab: p.tab)?.mode == .structure, let t = s.table(p.tab) else { return nil }
		return (s, t)
	}

	var body: some View {
		VStack(spacing: 0) {
		GeometryReader { geo in
			HStack(spacing: 0) {
				leftPane
					.frame(maxWidth: .infinity)
				if model.hasSplit {
					splitHandle(total: geo.size.width)
					rightPane
						.frame(width: rightWidth(total: geo.size.width))
				}
			}
			.clipped()
		}
			// 콘솔: 하단바 아래 (쿼리 패널이 탭바 위에 열리는 것과 짝)
			if model.showConsole {
				ConsolePanel(log: QueryLog.shared) { sql in
					guard let q = session.queryPanel else { return }
					q.text = q.text.isEmpty ? sql : q.text + "\n" + sql
					q.open = true
				}
			}
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
		// 제목바 오른쪽 끝: [검색] (데이터 보기일 때) + [데이터 | 구조]. 다시 읽기는 하단바 맨 오른쪽.
		// 창 전체가 아니라 detail 본문 뷰에 붙여야 오른쪽 정렬과 묶음 나누기가 된다 (Ai/iSQL.md 툴바 규칙)
		.toolbar {
			ToolbarSpacer(.flexible)
			// 쿼리 결과가 탭을 덮고 있으면 탭용 버튼은 숨긴다
			if let d = active, !resultsCoverFocused {
				// 데이터 보기: 검색 / 구조 보기: 테이블 정보 패널 (⌥⌘I). 한 버튼을 그대로 두고 아이콘·동작만 바꾼다:
				// 다른 버튼으로 갈아 끼우면 다른 버튼이 움직이고(사용자), 새로 생긴 버튼이 빈 알약으로 그려지기도 했다
				ToolbarItem {
					let structure = d.mode == .structure
					Button {
						if structure { toggleFocusedInfo() } else { d.showFilter.toggle() }
					} label: {
						Image(systemName: structure ? "sidebar.right" : "magnifyingglass")
							.foregroundStyle((structure ? focusedInfoOn : (d.showFilter || !d.whereClause.isEmpty)) ? Color.accentColor : Color.primary)
					}
					.help(structure ? "테이블 정보 (⌥⌘I)"
					      : d.whereClause.isEmpty ? "조건으로 찾기 (⌥⌘F)" : "조건으로 찾기 (⌥⌘F)\nWHERE \(d.whereClause)")
				}
				ToolbarSpacer(.fixed)
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
			// [쿼리 | 콘솔]: 어느 보기에서나 (쿼리 ⌘J, 콘솔 ⇧⌘L)
			ToolbarItemGroup {
				Button {
					session.queryPanel?.open.toggle()
				} label: {
					Image(systemName: "terminal")
						.foregroundStyle(session.queryPanel?.open == true ? Color.accentColor : Color.primary)
				}
				.help("쿼리 (⌘J)")
				Button {
					model.showConsole.toggle()
				} label: {
					Image(systemName: "list.bullet.rectangle")
						.foregroundStyle(model.showConsole ? Color.accentColor : Color.primary)
				}
				.help("콘솔: 앱이 서버에 보낸 쿼리 (⇧⌘L)")
			}
		}
		.background {
			Group {
				// ⌘⇧W 탭 닫기, ⌘⇧[ ] 탭 옮기기 (초점 쪽에서)
				Button("") { closeFocused() }.keyboardShortcut("w", modifiers: [.command, .shift])
				Button("") { move(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
				Button("") { move(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
				// ⌘S 저장, ⌘1 데이터, ⌘2 구조, ⌥⌘F 조건 줄
				Button("") {
					// 쿼리 결과가 덮고 있으면 고른 결과를 저장
					if resultsCoverFocused, let q = session.queryPanel, q.outputs.indices.contains(q.selectedOutput) {
						let src = q.outputs[q.selectedOutput].source
						Task { await src.save() }
						return
					}
					// 루틴 탭: 저장 (DROP → CREATE)
					if let f = focused, let e = f.session.routineEditor(f.tab) {
						let s = f.session, tab = f.tab
						Task {
							if let n = await e.save() { s.retargetRoutineTab(tab, to: RoutineInfo.tabID(e.kind, e.schema, n)) }
						}
						return
					}
					guard let d = active else { return }
					Task { if d.mode == .structure { await d.saveStructure() } else { await d.saveIfNeeded() } }
				}.keyboardShortcut("s")
				Button("") { active?.mode = .data }.keyboardShortcut("1")
				Button("") { active?.mode = .structure }.keyboardShortcut("2")
				Button("") {
					if let d = active { d.mode = .data; d.showFilter.toggle() }
					else if let o = activeOverview { o.showSearch.toggle(); if !o.showSearch { o.searchText = "" } }
				}.keyboardShortcut("f", modifiers: [.command, .option])
				// ⌘J 쿼리 패널 열기/닫기
				Button("") { session.queryPanel?.open.toggle() }.keyboardShortcut("j")
				// ⌘K 빠른 열기
				Button("") { model.showQuickOpen.toggle() }.keyboardShortcut("k")
				// ⇧⌘L 콘솔
				Button("") { model.showConsole.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
				// ⌥⌘I 테이블 정보 (구조 보기로 바꿔서)
				Button("") { if let d = active { if d.mode == .structure { toggleFocusedInfo() } else { d.mode = .structure; if !focusedInfoOn { toggleFocusedInfo() } } } }.keyboardShortcut("i", modifiers: [.command, .option])
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
					.infoPanel(session: session, table: leftInfoTable, overlayTop: session.tabs.isEmpty ? 0 : 37, alwaysBeside: !model.hasSplit)
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
		}
		// 칸 안 어디를 눌러도 초점은 이쪽 (AppKit 표가 마우스를 먹어서 SwiftUI 탭 제스처로는 못 받는다)
		.background(PaneClickWatcher { if model.hasSplit { model.splitFocus = .left } })
	}

	private var leftTabs: some View {
		VStack(spacing: 0) {
			if !session.tabs.isEmpty {
				TabBar(session: session, paneFocused: !model.hasSplit || model.splitFocus == .left,
				       close: closeLeft, park: { model.park($0, from: session) },
				       duplicate: { model.duplicateToRight($0, from: session) })
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
				} else if let id = session.activeTab, let e = session.routineEditor(id) {
					// 프로시저·함수·트리거·이벤트
					RoutineTabView(session: session, tab: id, editor: e).id(id)
				} else if let id = session.activeTab, let v = session.privateView(tab: id) {
					// 나만 보는 뷰
					PrivateViewTabView(session: session, view: v).id(id)
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
		rightPaneBody
			.infoPanel(session: rightInfo?.0, table: rightInfo?.1, overlayTop: 37, alwaysBeside: false)
			.background(PaneClickWatcher { model.splitFocus = .right })
	}

	private var rightPaneBody: some View {
		VStack(spacing: 0) {
			ParkedTabBar(model: model, currentServer: session.server?.id, close: closeRight)
			Divider()
			ZStack {
				if let p = model.parkedActive, let s = model.sessions[p.server] {
					if let t = s.table(p.tab) {
						TableDetailView(session: s, tab: p.tab, table: t, alive: parkedSources,
						                onGridScroll: { model.scrollLink.register(.right, $0) })
					} else if let schema = Session.databaseOf(tab: p.tab) {
						DatabaseOverviewView(session: s, overview: s.overview(schema)).id(p.key)
					} else if let e = s.routineEditor(p.tab) {
						RoutineTabView(session: s, tab: p.tab, editor: e).id(p.key)
					} else if let v = s.privateView(tab: p.tab) {
						PrivateViewTabView(session: s, view: v).id(p.key)
					} else {
						ContentUnavailableView("테이블이 없습니다", systemImage: "tablecells", description: Text(p.tab))
					}
				}
			}
		}
	}

	/// 오른쪽에 둔 테이블 탭들의 표 공급자 (오른쪽 칸의 표 호스트가 살려 둘 것)
	private var parkedSources: [GridSource] {
		model.parkedTabs.compactMap { p in model.sessions[p.server]?.data(tab: p.tab) }
	}

	/// 분할 한쪽 최소 너비 (하단바가 잘리지 않게, 사용자 2026-11-17)
	private static let minPane: CGFloat = 600

	private func rightWidth(total: CGFloat) -> CGFloat {
		let w = splitWidth > 0 ? CGFloat(splitWidth) : total / 2
		// 둘 다 600 이 안 되면 반반
		guard total >= Self.minPane * 2 else { return total / 2 }
		return min(max(w, Self.minPane), total - Self.minPane)
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
					.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
						// 손잡이가 끄는 동안 함께 움직이므로 제 좌표로 재면 이동량이 되먹여 떨린다 → 창 좌표로 잰다
						.onChanged { v in
							if dragStartWidth == nil { dragStartWidth = Double(rightWidth(total: total)) }
							let w = (dragStartWidth ?? 0) - Double(v.translation.width)
							splitWidth = total >= Self.minPane * 2 ? min(max(w, Double(Self.minPane)), Double(total - Self.minPane)) : Double(total / 2)
						}
						.onEnded { _ in dragStartWidth = nil })
			}
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
	/// 끌어서 순서 바꾸기 (편집기 탭처럼 탭이 마우스를 따라오고 옆 탭이 비켜난다)
	@State private var reorder = TabReorder<String>()

	/// 쿼리 결과 화면이 이 탭바를 덮고 있는지
	private var covered: Bool {
		guard let q = session.queryPanel else { return false }
		return q.open && !q.outputs.isEmpty && q.resultsVisible
	}

	var body: some View {
		TabStrip(selected: session.activeTab) {
			ForEach(session.tabs, id: \.self) { id in
				TabItem(table: session.table(id), id: id, customTitle: session.privateView(tab: id)?.name,
				        active: session.activeTab == id,
				        // data(for:) 로 만들어 두고 읽어야 loading 이 관찰된다
				        loading: session.data(tab: id)?.loading
				            ?? Session.databaseOf(tab: id).map { session.overview($0).loading } ?? false,
				        stale: session.data(tab: id)?.stale ?? false,
				        unsaved: session.unsavedTables.contains(id),
				        showSchema: needsSchema(id),
				        focused: paneFocused,
				        structure: session.data(tab: id)?.mode == .structure,
				        menu: TabMenuAction.table(session.table(id), in: session)
				            + [TabMenuAction(title: "오른쪽 분할로 옮기기") { park(id) }]
				            + (session.table(id) != nil ? [TabMenuAction(title: "오른쪽 분할에 복제") { duplicate(id) }] : [])
				            + Self.orderMenu(session.data(tab: id)),
				        clickable: !covered,
				        // 다른 탭 닫기: 저장 안 한 변경이 있는 탭은 남긴다 (묻는 창을 여러 번 띄우지 않게)
				        closeOthers: session.tabs.count > 1 ? {
				            for other in session.tabs where other != id && !session.unsavedTables.contains(other) { session.closeTab(other) }
				            session.selectTab(id)
				        } : nil) {
					session.selectTab(id)
				} close: {
					close(id)
				}
				.reorderable(id, order: session.tabs, state: $reorder) { session.moveTab($0, before: $1) }
				.id(id)
			}
		}
		// 탭을 옮기면 탭바 안에서만 짧게 미끄러지게 (바깥 묶음에 animation 을 걸면 표까지 프레임마다 다시 배치된다)
		.animation(.easeOut(duration: 0.18), value: session.tabs)
		.frame(height: 36)
		// 탭이 없는 빈 곳에 놓으면 맨 뒤로
		// 색 배경은 기본으로 안전 영역(제목바 밑)까지 번진다. 탭바 안에만 칠한다
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	/// 컬럼을 끌어 순서를 바꿨거나 숨긴 탭이면 "컬럼 복원" (순서·숨김을 원래 테이블대로)
	static func orderMenu(_ d: TableData?) -> [TabMenuAction] {
		guard let d, d.columnsMoved else { return [] }
		return [TabMenuAction(title: "컬럼 복원") { d.restoreColumns?() }]
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
	@State private var reorder = TabReorder<ParkedTab>()

	var body: some View {
		HStack(spacing: 0) {
		TabStrip(selected: model.parkedActive?.key) {
			ForEach(model.parkedTabs, id: \.key) { p in
				let s = model.sessions[p.server]
				let t = s?.table(p.tab)
				TabItem(table: t, id: p.tab, customTitle: s?.privateView(tab: p.tab)?.name,
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
				        structure: s?.data(tab: p.tab)?.mode == .structure,
				        menu: TabMenuAction.table(t, in: s)
				            + [TabMenuAction(title: "왼쪽으로 옮기기") { model.unpark(p) }] + TabBar.orderMenu(s?.data(tab: p.tab)),
				        closeOthers: model.parkedTabs.count > 1 ? {
				            for q in model.parkedTabs where q != p && !(model.sessions[q.server]?.unsavedTables.contains(q.tab) ?? false) { close(q) }
				            model.focusParked(p)
				        } : nil) {
					model.focusParked(p)
				} close: {
					close(p)
				}
				.reorderable(p, order: model.parkedTabs, state: $reorder) { model.moveParked($0, before: $1) }
				.id(p.key)
			}
		}
		.animation(.easeOut(duration: 0.18), value: model.parkedTabs)
			Divider()
			// 양쪽 표 세로 스크롤 맞추기 (같은 테이블을 DB·서버끼리 비교할 때)
			let paused = leftCovered
			Button { model.scrollSync.toggle() } label: {
				Image(systemName: "arrow.up.and.down.and.sparkles")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(model.scrollSync && !paused ? Color.accentColor : Color.secondary)
					.frame(width: 30, height: 30)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 3)
			.disabled(paused)
			.help(paused ? "쿼리 결과가 왼쪽을 덮고 있어 스크롤 맞추기를 잠시 멈췄습니다 (결과를 숨기면 다시 켜집니다)"
			      : model.scrollSync ? "양쪽 세로 스크롤 맞추기 켜짐 (누르면 끔)" : "양쪽 세로 스크롤 맞추기: 왼쪽·오른쪽 표를 같이 위아래로")
			.onChange(of: paused, initial: true) { model.scrollPaused = paused }
		}
		.frame(height: 36)
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}

	/// 쿼리 결과 화면이 왼쪽 칸을 덮고 있는지
	private var leftCovered: Bool {
		guard let q = model.current?.queryPanel else { return false }
		return q.open && !q.outputs.isEmpty && q.resultsVisible
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

/// 양쪽 표의 세로 스크롤을 맞춘다: 왼쪽·오른쪽 칸에서 지금 보이는 표를 기억하고, 한쪽이 움직이면 다른 쪽을 같은 높이로.
/// 가로는 맞추지 않는다 (양쪽 칸 너비·컬럼이 다를 수 있다, 사용자 결정)
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
		// 세로만: x 는 그대로. 제목 줄 여백(contentInsets)·문서 크기는 constrainBoundsRect 가 맞춰 준다
		let want = NSPoint(x: clip.bounds.origin.x, y: a.contentView.bounds.origin.y)
		let target = clip.constrainBoundsRect(NSRect(origin: want, size: clip.bounds.size)).origin
		guard target != clip.bounds.origin else { return }
		clip.setBoundsOrigin(target)
		b.reflectScrolledClipView(clip)
	}
}

/// 탭 오른쪽 클릭 메뉴에 더할 항목
struct TabMenuAction {
	let title: String
	let run: () -> Void

	/// 메뉴 구분선 (제목이 빈 것)
	static let separator = TabMenuAction(title: "") {}

	/// 테이블 탭 공통: 이름 복사 · 이름 바꾸기 (사용자 2026-11-17)
	static func table(_ t: TableInfo?, in s: Session?) -> [TabMenuAction] {
		guard let t, let s else { return [] }
		let kind = t.isView ? "뷰" : "테이블"
		return [
			TabMenuAction(title: "테이블 이름 복사") {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(t.name, forType: .string)
			},
			TabMenuAction(title: "\(kind) 이름 바꾸기…") {
				s.tableNameRequest = TableNameRequest(kind: .rename, schema: t.schema, table: TableStat(t))
			},
			.separator,
		]
	}
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
			// 누르는 순간 초점을 옮긴다. 예전엔 탭이 떼는 순간 골라져서(탭 제스처) 초점을 뗀 뒤로 미뤘는데,
			// 표(AppKit)는 누른 뒤 떼기까지 이벤트를 직접 받아 떼기가 여기 안 와서 칸을 눌러도 초점이 안 바뀌었다 (사용자 지적).
			// 탭도 이제 누르는 순간 고르므로(MouseDownCatcher) 둘 다 누르는 순간에 맞춘다
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

/// 누르는 순간(마우스 다운)에 실행: 탭·목록 고르기.
/// SwiftUI 탭 제스처는 떼는 순간에 일어나고, 끌기(.draggable)가 붙은 탭은 오래 누르면 끌기로 여겨 아예 안 골라졌다 (사용자 지적).
/// 이벤트는 그대로 흘려보내므로 끌기·버튼은 평소대로 동작한다
struct MouseDownCatcher: NSViewRepresentable {
	/// 오른쪽 끝 이만큼은 빼고 (탭 닫기 버튼)
	var excludeTrailing: CGFloat = 0
	var enabled = true
	let action: () -> Void

	final class CatchView: NSView {
		var excludeTrailing: CGFloat = 0
		var enabled = true
		var action: () -> Void = {}
		private var monitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
				guard let self, self.enabled, e.window === self.window, !self.isHiddenOrHasHiddenAncestor,
				      !e.modifierFlags.contains(.control) else { return e }
				let p = self.convert(e.locationInWindow, from: nil)
				// 자기 탭 안(bounds)이면서 탭바 스크롤에 가려지지 않은 곳(visibleRect)만.
				// visibleRect 만 보면 SwiftUI 안에서는 탭바 전체 너비가 나와 한 번 누르면 모든 탭이 반응했다
				// (마지막에 반응한 탭이 골라져 "씹히는" 것처럼 보였다)
				if self.bounds.contains(p), self.visibleRect.contains(p), p.x < self.bounds.maxX - self.excludeTrailing {
					// 바로 실행: 뒤로 미루면(main.async) 탭 끌기 감지가 누르고 있는 동안 실행을 붙잡아
					// 오래 누르면 안 골라지고 끌어야 골라졌다 (사용자 지적)
					self.action()
				}
				return e
			}
		}

		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}

	func makeNSView(context: Context) -> CatchView {
		let v = CatchView()
		updateNSView(v, context: context)
		return v
	}

	func updateNSView(_ v: CatchView, context: Context) {
		v.excludeTrailing = excludeTrailing
		v.enabled = enabled
		v.action = action
	}

	static func dismantleNSView(_ v: CatchView, coordinator: ()) {
		v.removeFromSuperview()
	}
}

extension View {
	/// 누르는 순간 실행 (MouseDownCatcher)
	func onMouseDown(excludeTrailing: CGFloat = 0, enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
		background(MouseDownCatcher(excludeTrailing: excludeTrailing, enabled: enabled, action: action))
	}
}

struct TabItem: View {
	let table: TableInfo?
	let id: String
	/// 나만 보는 뷰처럼 id 로 이름을 알 수 없는 탭의 이름
	var customTitle: String? = nil
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
	/// 구조 보기 중인 테이블 탭 (아이콘을 제목바 [표|구조] 의 구조 아이콘으로)
	var structure = false
	/// 오른쪽 클릭 메뉴에 더할 항목 (분할로 옮기기 등)
	var menu: [TabMenuAction] = []
	/// 누를 수 있는지 (쿼리 결과 화면이 왼쪽 탭바를 덮고 있으면 꺼서 가려진 탭이 같이 눌리지 않게)
	var clickable = true
	/// 오른쪽 클릭 "다른 탭 닫기" (탭이 하나뿐이면 nil → 흐리게)
	var closeOthers: (() -> Void)? = nil
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
					Image(systemName: Session.databaseOf(tab: id) != nil ? "cylinder.split.1x2"
					      : RoutineInfo.parse(id).map(\.kind.icon) ?? (PrivateView.id(ofTab: id) != nil ? "eye.circle"
					      : (structure ? "square.stack.3d.up" : (table?.isView == true ? "eye" : "tablecells"))))
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
			         text: customTitle ?? table?.name ?? Session.databaseOf(tab: id) ?? RoutineInfo.parse(id).map { $0.name ?? "새 \($0.kind.label)" } ?? id,
			         active: active && focused)
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
		// 누르는 순간 고른다 (닫기 버튼 자리는 빼고)
		.onMouseDown(excludeTrailing: 24, enabled: clickable, perform: select)
		.help(table.map { $0.comment.isEmpty ? $0.id : "\($0.id)\n\($0.comment)" } ?? Session.databaseOf(tab: id).map { "DB \($0)" } ?? id)
		.contextMenu {
			ForEach(menu.indices, id: \.self) { i in
				if menu[i].title.isEmpty { Divider() } else { Button(menu[i].title, action: menu[i].run) }
			}
			if !menu.isEmpty { Divider() }
			Button("탭 닫기", action: close)
			Button("다른 탭 닫기") { closeOthers?() }
				.disabled(closeOthers == nil)
				.help("저장 안 한 변경이 있는 탭은 남깁니다")
		}
	}
}

/// 구조 보기 테이블 정보 패널을 그 칸 오른쪽에 붙인다 (분할이면 칸마다 따로, 사용자 2026-11-17).
/// 칸이 넉넉하면(표 최소 600 + 패널 340) 표를 밀고 나란히, 좁으면 탭바 아래에서 표 위로 떠서 덮는다.
/// SwiftUI .inspector 는 맥 26 에서 붙인 뷰가 사이드바·툴바 밑으로 파고들어(안전 영역을 잃음, 화면으로 확인) 직접 그린다
private struct InfoPanelHost: ViewModifier {
	let session: Session?
	let table: TableInfo?
	/// 덮을 때 비워 둘 위 높이 (탭바)
	let overlayTop: CGFloat
	/// 분할이 아니면 예전처럼 늘 나란히 (창 최소 너비라 표가 좁아져도 덮지 않는다)
	let alwaysBeside: Bool
	@State private var width: CGFloat = 0

	static let panelWidth: CGFloat = 340
	private var fits: Bool { alwaysBeside || width >= 600 + Self.panelWidth }

	func body(content: Content) -> some View {
		// 표(AppKit) 자리는 늘 그대로 두고 패널만 붙였다 뗀다: 표를 다른 자리로 옮기면 새로 만들어져 느리고 스크롤도 잃는다
		HStack(spacing: 0) {
			content.frame(maxWidth: .infinity)
			if fits, let session, let table {
				Divider()
				panel(session, table)
			}
		}
		.overlay(alignment: .topTrailing) {
			if !fits, let session, let table {
				HStack(spacing: 0) {
					Divider()
					panel(session, table)
				}
				.background(Color(nsColor: .windowBackgroundColor))
				.shadow(color: .black.opacity(0.25), radius: 8, x: -2)
				.padding(.top, overlayTop)
			}
		}
		.clipped()
		.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
		.animation(.easeOut(duration: 0.2), value: table?.id)
	}

	private func panel(_ s: Session, _ t: TableInfo) -> some View {
		TableInfoPanel(session: s, inspector: s.inspector(for: t), columns: s.columns[t.id] ?? [])
			.id(t.id)
			.frame(width: Self.panelWidth)
			.transition(.move(edge: .trailing))
	}
}

extension View {
	fileprivate func infoPanel(session: Session?, table: TableInfo?, overlayTop: CGFloat, alwaysBeside: Bool) -> some View {
		modifier(InfoPanelHost(session: session, table: table, overlayTop: overlayTop, alwaysBeside: alwaysBeside))
	}
}
