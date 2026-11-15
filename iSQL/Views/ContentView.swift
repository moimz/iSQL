import SwiftUI
import AppKit

struct ContentView: View {
	@Environment(ServerStore.self) private var store
	@State private var model = WindowModel()
	@State private var confirmDisconnect: UUID?

	var body: some View {
		NavigationSplitView {
			Group {
				if let s = model.current, s.isConnected {
					TableSidebar(session: s)
				} else {
					ServerSidebar(model: model)
				}
			}
			.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
		} detail: {
			if let s = model.current {
				if s.isConnected {
					ConnectedArea(session: s)
				} else {
					SessionStatusView(model: model, session: s)
				}
			} else {
				ConnectPanel(model: model)
			}
		}
		.toolbar(removing: .title)
		.toolbar {
			// 제목이자 서버 바꾸기 (둥근 배경 없이 글자만)
			ToolbarItem(placement: .navigation) {
				ServerSwitcher(model: model, disconnect: askDisconnect)
			}
			.sharedBackgroundVisibility(.hidden)

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
		// 그룹 추가: 제목바에 붙는 시트
		.sheet(isPresented: $model.addingGroup) {
			GroupAddSheet { model.onGroupAdded?($0) }
		}
		.confirmationDialog("저장 안 된 변경이 있습니다", isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } })) {
			Button("버리고 연결 끊기", role: .destructive) {
				if let id = confirmDisconnect { model.disconnect(id) }
				confirmDisconnect = nil
			}
		} message: {
			Text("저장하지 않은 변경은 연결을 끊으면 사라집니다.")
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
		for g in store.grouped {
			menu.addItem(.sectionHeader(title: g.group.isEmpty ? "서버" : g.group))
			for s in g.servers { menu.addItem(serverItem(s)) }
		}
		// 저장하지 않고 접속한 서버
		let unsaved = model.sessions.values.compactMap(\.server).filter { s in !store.servers.contains { $0.id == s.id } }
		if !unsaved.isEmpty {
			menu.addItem(.sectionHeader(title: "저장 안 한 접속"))
			for s in unsaved.sorted(by: { $0.displayName < $1.displayName }) { menu.addItem(serverItem(s)) }
		}
		menu.addItem(.separator())
		if let id = model.currentID, model.sessions[id] != nil {
			// 퀵 커넥트로 접속하고 저장을 잊은 경우
			if !store.servers.contains(where: { $0.id == id }) {
				menu.addItem(MenuAction.item("이 접속 저장하기") { model.saveUnsaved(id, to: store) })
			}
			menu.addItem(MenuAction.item("이 서버 연결 끊기") { disconnect(id) })
		}
		menu.addItem(MenuAction.item("새 접속…") { model.newConnection() })
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
