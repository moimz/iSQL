import SwiftUI
import AppKit

struct ContentView: View {
	@Environment(ServerStore.self) private var store
	@State private var model = WindowModel()
	@State private var confirmDisconnect: UUID?
	/// 이 창이 앞(키)에 오면 MCP "지금 보고 있는 창의 서버" 가 이 창을 따른다
	@Environment(\.controlActiveState) private var activeState

	var body: some View {
		NavigationSplitView {
			VStack(spacing: 0) {
				// 접속한 서버가 하나라도 있으면 위에 [서버 | 테이블]: 접속한 뒤에도 서버 목록을 다시 볼 수 있게
				if !model.sessions.isEmpty {
					SidebarModeSegment(selection: $model.sidebarMode)
						.frame(height: 24)
						.padding(.horizontal, 10)
						.padding(.top, 6)
				}
				if model.sidebarMode == .tables && !model.sessions.isEmpty {
					if let s = model.current, s.isConnected {
						TableSidebar(session: s)
					} else {
						ContentUnavailableView("접속한 서버가 아닙니다", systemImage: "cylinder.split.1x2",
						                       description: Text("제목바에서 접속한 서버를 고르세요."))
							.frame(maxHeight: .infinity)
					}
				} else {
					ServerSidebar(model: model)
				}
			}
			.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
		} detail: {
			if let s = model.current {
				if s.isConnected {
					ConnectedArea(session: s, model: model)
				} else {
					SessionStatusView(model: model, session: s)
				}
			} else {
				ConnectPanel(model: model)
			}
		}
		.toolbar(removing: .title)
		.onAppear { AppState.shared.register(model) }
		.onChange(of: activeState, initial: true) { if activeState == .key { AppState.shared.activeModel = model } }
		// 설정 창이 보일 서버: 이 창에서 서버를 고르면 그 서버로 (⌘, 로 열어도 마지막으로 고른 창의 서버)
		.onChange(of: model.currentID, initial: true) { SettingsTarget.shared.session = model.current?.isConnected == true ? model.current : SettingsTarget.shared.session }
		// 접속이 끝났거나 접속한 서버로 옮기면 테이블 목록으로
		.onChange(of: model.current?.isConnected == true ? model.currentID : nil) { _, id in
			if id != nil { model.sidebarMode = .tables }
		}
		// 퀵 커넥트 화면(새 접속·접속 안 한 서버)이거나 접속이 모두 닫히면 서버 목록으로
		.onChange(of: model.currentID == nil || model.sessions.isEmpty) { _, home in
			if home { model.sidebarMode = .servers }
		}
		.toolbar {
			// 제목이자 서버 바꾸기 (둥근 배경 없이 글자만)
			ToolbarItem(placement: .navigation) {
				ServerSwitcher(model: model, disconnect: askDisconnect)
			}
			.sharedBackgroundVisibility(.hidden)
			// 서버 이름 옆: 이 서버 설정 (접속했을 때만)
			if model.current?.isConnected == true {
				ToolbarItem(placement: .navigation) {
					Button {
						SettingsTarget.shared.session = model.current
						ServerSettingsWindow.shared.show(store: store)
					} label: { Image(systemName: "gearshape") }
						.help("서버 설정")
				}
			}

			// 오른쪽 버튼은 여기 두지 않는다: 창 전체에 붙이면 오른쪽 정렬·묶음 나누기가 안 먹는다.
			// 본문 뷰(TableDetailView)의 .toolbar 에 붙인다 (Ai/iSQL.md 툴바 규칙)
		}
		.navigationTitle(model.current?.server?.displayName ?? "iSQL")
		// 내보내기: 제목바에 붙는 시트 하나 (하단바 버튼·사이드바 오른쪽 클릭·DB 개요 어디서 불러도)
		.sheet(item: Binding(get: { model.current?.exportRequest }, set: { model.current?.exportRequest = $0 })) { req in
			if let s = model.current { ExportSheet(request: req, session: s) }
		}
		// 데이터베이스 복제: 제목바에 붙는 시트
		.sheet(item: Binding(get: { model.current?.duplicateRequest }, set: { model.current?.duplicateRequest = $0 })) { req in
			if let s = model.current { DuplicateDatabaseSheet(request: req, session: s) }
		}
		// 테이블 이름 바꾸기·복제, SQL 파일 가져오기 (시트가 많아 묶음으로 — 한 식이 길면 타입 검사가 끝나지 않는다)
		.modifier(MoreSheets(model: model))
		// 새 테이블 만들기: 제목바에 붙는 시트
		.sheet(item: Binding(get: { model.current?.createTableRequest }, set: { model.current?.createTableRequest = $0 })) { req in
			if let s = model.current { CreateTableSheet(request: req, session: s) }
		}
		// 테이블·데이터베이스 삭제, 테이블 비우기 확인 (어디서 불러도 여기 하나)
		.modifier(TableActionDialogs(model: model))
		// 새 데이터베이스: 제목바에 붙는 시트
		.sheet(isPresented: Binding(get: { model.current?.creatingDatabase ?? false }, set: { model.current?.creatingDatabase = $0 })) {
			if let s = model.current { CreateDatabaseSheet(session: s) }
		}
		// 그룹 추가: 제목바에 붙는 시트
		.sheet(isPresented: $model.addingGroup) {
			GroupAddSheet { model.onGroupAdded?($0) }
		}
		.confirmationDialog("저장 안 된 변경이 있습니다", isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } })) {
			Button("버리고 닫기", role: .destructive) {
				if let id = confirmDisconnect { model.disconnect(id) }
				confirmDisconnect = nil
			}
		} message: {
			Text("저장하지 않은 변경은 서버를 닫으면 사라집니다.")
		}
	}

	private func askDisconnect(_ id: UUID) {
		if model.sessions[id]?.unsavedTables.isEmpty ?? true { model.disconnect(id) } else { confirmDisconnect = id }
	}
}

/// 제목바의 서버 이름. 누르면 전체 서버 목록 (접속 중 표시).
/// SwiftUI Menu 는 라벨 모양(배경, 화살표 위치, 여백)을 마음대로 못 해서 글자 버튼 + AppKit 메뉴로 만든다
struct ServerSwitcher: View {
	@Environment(ServerStore.self) private var store
	let model: WindowModel
	let disconnect: (UUID) -> Void
	@State private var hover = false

	var body: some View {
		Button(action: showMenu) {
			HStack(spacing: 7) {
				if let s = model.current?.server {
					Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 9, height: 9)
					Text(s.displayName).font(.system(size: 15, weight: .semibold))
					if let v = model.current?.serverVersion, !v.isEmpty {
						Text(v).font(.caption).foregroundStyle(.secondary)
					}
				} else {
					Text("서버 선택").font(.system(size: 15, weight: .semibold))
				}
				Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
			}
			.padding(.horizontal, 12)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0)))
			.padding(.leading, 2)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hover = $0 }
		.fixedSize()
		.help("서버 바꾸기")
	}

	private func showMenu() {
		let menu = NSMenu()
		// 접속한 서버만 (전체 서버 목록은 왼쪽 사이드바 [서버] 에서). 왼쪽 목록 순서, 저장 안 한 접속은 뒤에
		let open = Set(model.sessions.keys)
		let saved = store.grouped.flatMap(\.servers).filter { open.contains($0.id) }
		let unsaved = model.sessions.values.compactMap(\.server).filter { s in !store.servers.contains { $0.id == s.id } }
			.sorted { $0.displayName < $1.displayName }
		if !saved.isEmpty || !unsaved.isEmpty {
			menu.addItem(.sectionHeader(title: "접속한 서버"))
			for s in saved + unsaved { menu.addItem(serverItem(s)) }
		}
		if let id = model.currentID, model.sessions[id] != nil {
			menu.addItem(.separator())
			// 퀵 커넥트로 접속하고 저장을 잊은 경우
			if !store.servers.contains(where: { $0.id == id }) {
				menu.addItem(MenuAction.item("이 접속 저장하기") { model.saveUnsaved(id, to: store) })
			}
			menu.addItem(MenuAction.item("닫기") { disconnect(id) })
		}
		// 새 접속은 왼쪽 서버 목록 맨 위에 있다
		if menu.items.isEmpty {
			let none = NSMenuItem(title: "접속한 서버 없음", action: nil, keyEquivalent: "")
			none.isEnabled = false
			menu.addItem(none)
		}
		// 버튼 바로 아래에 띄운다
		if let event = NSApp.currentEvent, let window = event.window, let view = window.contentView {
			let p = view.convert(event.locationInWindow, from: nil)
			menu.popUp(positioning: nil, at: NSPoint(x: p.x - 20, y: p.y - 18), in: view)
		} else {
			menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
		}
	}

	/// 왼쪽 목록처럼: 색 점 + 이름 (+ 접속 상태), 아래 줄에 접속 정보
	private func serverItem(_ s: Server) -> NSMenuItem {
		let item = MenuAction.item(s.displayName + status(s)) { model.open(s) }
		item.subtitle = s.subtitle
		item.state = model.currentID == s.id ? .on : .off
		let color = s.color.swiftUI.map { NSColor($0) } ?? NSColor.tertiaryLabelColor
		item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
			.withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [color])))
		return item
	}

	private func status(_ s: Server) -> String {
		switch model.state(s.id) {
		case .connected: "   · 접속 중"
		case .connecting: "   · 접속하는 중…"
		case .failed: "   · 접속 실패"
		default: ""
		}
	}
}

/// 닫는 블록을 가진 메뉴 항목
final class MenuAction: NSObject {
	let run: () -> Void
	init(_ run: @escaping () -> Void) { self.run = run }
	@objc func fire() { run() }

	static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
		let action = MenuAction(run)
		let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
		item.target = action
		item.representedObject = action   // 메뉴 항목이 살아 있는 동안 붙잡아 둔다 (target 은 약한 참조)
		return item
	}
}

extension ServerColor {
	var swiftUI: Color? {
		switch self {
		case .none: nil
		case .red: .red
		case .orange: .orange
		case .yellow: .yellow
		case .green: .green
		case .blue: .blue
		case .purple: .purple
		case .gray: .gray
		}
	}
}

/// 데이터 / 구조 아이콘 세그먼트. 칸마다 툴팁을 달려고 NSSegmentedControl 을 쓴다
struct ModeSegment: NSViewRepresentable {
	@Binding var selection: Int

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSSegmentedControl {
		let images = ["tablecells", "list.bullet.rectangle"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! }
		let c = NSSegmentedControl(images: images, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
		c.setToolTip("데이터 (⌘1)", forSegment: 0)
		c.setToolTip("구조 (⌘2)", forSegment: 1)
		c.setWidth(36, forSegment: 0)
		c.setWidth(36, forSegment: 1)
		c.selectedSegment = selection
		return c
	}

	func updateNSView(_ c: NSSegmentedControl, context: Context) {
		context.coordinator.parent = self
		if c.selectedSegment != selection { c.selectedSegment = selection }
	}

	final class Coordinator: NSObject {
		var parent: ModeSegment
		init(_ p: ModeSegment) { parent = p }
		@objc func changed(_ sender: NSSegmentedControl) { parent.selection = sender.selectedSegment }
	}
}

/// 사이드바 위 [서버 | 테이블]. SwiftUI 세그먼트 Picker 는 너비를 채우지 않아 NSSegmentedControl 로 칸을 똑같이 나눈다
struct SidebarModeSegment: NSViewRepresentable {
	@Binding var selection: SidebarMode

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSSegmentedControl {
		let c = NSSegmentedControl(labels: ["서버", "테이블"], trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
		c.segmentDistribution = .fillEqually
		c.setContentHuggingPriority(.defaultLow, for: .horizontal)
		c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		c.selectedSegment = selection == .servers ? 0 : 1
		return c
	}

	func updateNSView(_ c: NSSegmentedControl, context: Context) {
		context.coordinator.parent = self
		let i = selection == .servers ? 0 : 1
		if c.selectedSegment != i { c.selectedSegment = i }
	}

	final class Coordinator: NSObject {
		var parent: SidebarModeSegment
		init(_ p: SidebarModeSegment) { parent = p }
		@objc func changed(_ sender: NSSegmentedControl) { parent.selection = sender.selectedSegment == 0 ? .servers : .tables }
	}
}

/// 테이블·DB 삭제, 테이블 비우기 확인 창과 실패 알림 (본문 식이 길어 타입 검사가 안 끝나서 따로 뺐다)
struct TableActionDialogs: ViewModifier {
	let model: WindowModel

	func body(content: Content) -> some View {
		let r = model.current?.tableAction
		content
			.confirmationDialog(r?.title ?? "", isPresented: Binding(get: { model.current?.tableAction != nil },
			                                                          set: { if !$0 { model.current?.tableAction = nil } })) {
				Button(r?.confirmLabel ?? "삭제", role: .destructive) {
					guard let s = model.current, let r = s.tableAction else { return }
					s.tableAction = nil
					Task { await s.perform(r) }
				}
			} message: {
				Text(r?.message ?? "")
			}
			.alert("실행하지 못했습니다", isPresented: Binding(get: { model.current?.tableActionError != nil },
			                                             set: { if !$0 { model.current?.tableActionError = nil } })) {
				Button("확인") { model.current?.tableActionError = nil }
			} message: {
				Text(model.current?.tableActionError ?? "")
			}
	}
}


/// 제목바에 붙는 시트 묶음: 테이블 이름 바꾸기·복제, SQL 파일 가져오기
struct MoreSheets: ViewModifier {
	let model: WindowModel

	func body(content: Content) -> some View {
		content
			.sheet(item: Binding(get: { model.current?.tableNameRequest }, set: { model.current?.tableNameRequest = $0 })) { req in
				if let s = model.current { TableNameSheet(request: req, session: s) }
			}
			.sheet(item: Binding(get: { model.current?.importRequest }, set: { model.current?.importRequest = $0 })) { req in
				if let s = model.current { ImportSheet(request: req, session: s) }
			}
			.sheet(item: Binding(get: { model.current?.excelImportRequest }, set: { model.current?.excelImportRequest = $0 })) { req in
				if model.current != nil { ExcelImportSheet(request: req) }
			}
	}
}
