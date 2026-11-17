import SwiftUI
import AppKit

/// 설정 창이 보여 줄 서버 (창마다 접속이 따로라, 톱니를 누른·서버를 고른 창의 세션)
@Observable
final class SettingsTarget {
	static let shared = SettingsTarget()
	weak var session: Session?
}

/// 서버 설정 창 (제목바 서버 이름 옆 톱니). ⌘, 는 iSQL 앱 설정(AppSettingsView)이라 이건 따로 된 AppKit 창이다.
/// 맥 설정창처럼 위에 아이콘 탭 = NSTabViewController(.toolbar). 폭은 탭마다 같고 높이만 바뀐다 (사용자 지적: 폭이 바뀌면 탭 버튼이 움직였다)
@MainActor
final class ServerSettingsWindow: NSObject, NSWindowDelegate {
	static let shared = ServerSettingsWindow()
	static let width: CGFloat = 920

	private var window: NSWindow?

	/// 탭: (값, 이름, 아이콘, 높이)
	private static let pages: [(key: String, title: String, symbol: String, height: CGFloat)] = [
		("general", "일반", "gearshape", 440),
		("accounts", "사용자 계정", "person.2", 620),
		("status", "상태", "chart.bar.xaxis", 720),
		("variables", "서버 설정", "slider.horizontal.3", 640),
	]

	func show(store: ServerStore) {
		if window == nil { build(store) }
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}

	private func build(_ store: ServerStore) {
		let tabs = SizingTabViewController()
		tabs.tabStyle = .toolbar
		for p in Self.pages {
			let host = NSHostingController(rootView: AnyView(ServerSettingsPage(key: p.key).environment(store)))
			// 내용 크기를 따라 창이 늘어나지 않게 하고 탭마다 정한 크기를 쓴다
			host.sizingOptions = []
			host.preferredContentSize = NSSize(width: Self.width, height: p.height)
			host.title = p.title
			let item = NSTabViewItem(viewController: host)
			item.label = p.title
			item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
			tabs.addTabViewItem(item)
		}
		// 마지막으로 본 탭 (이 맥에만)
		let last = UserDefaults.standard.string(forKey: "serverSettingsTab") ?? "general"
		tabs.selectedTabViewItemIndex = Self.pages.firstIndex { $0.key == last } ?? 0
		tabs.onSelect = { i in UserDefaults.standard.set(Self.pages[i].key, forKey: "serverSettingsTab") }

		let w = NSWindow(contentViewController: tabs)
		w.styleMask = [.titled, .closable, .miniaturizable]
		w.toolbarStyle = .preference
		w.titlebarSeparatorStyle = .line
		w.isReleasedWhenClosed = false
		w.setContentSize(NSSize(width: Self.width, height: Self.pages[tabs.selectedTabViewItemIndex].height))
		w.center()
		w.setFrameAutosaveName("iSQL.ServerSettings")
		w.delegate = self
		window = w
	}
}

/// 탭을 바꾸면 그 탭 크기로 창을 맞춘다 (위쪽 모서리는 그대로)
private final class SizingTabViewController: NSTabViewController {
	var onSelect: ((Int) -> Void)?

	override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
		super.tabView(tabView, didSelect: tabViewItem)
		guard let item = tabViewItem, let vc = item.viewController, let w = view.window else { return }
		onSelect?(tabView.indexOfTabViewItem(item))
		let content = vc.preferredContentSize
		var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: content))
		frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
		w.setFrame(frame, display: true, animate: true)
	}
}

/// 서버 설정 창의 탭 하나
struct ServerSettingsPage: View {
	let key: String
	@Environment(ServerStore.self) private var store
	private var target = SettingsTarget.shared

	init(key: String) { self.key = key }

	var body: some View {
		Group {
			if let s = target.session, s.isConnected {
				switch key {
				case "accounts":
					UserAccountsView(session: s, manager: s.accountManager()).id(ObjectIdentifier(s))
				case "status":
					ServerStatusTab(session: s).id(ObjectIdentifier(s))
				case "variables":
					ServerVariablesTab(session: s).id(ObjectIdentifier(s))
				default:
					general(s)
				}
			} else {
				ContentUnavailableView("접속한 서버가 없습니다", systemImage: "cylinder.split.1x2",
				                       description: Text("서버에 접속한 뒤 제목바의 톱니를 누르세요."))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func general(_ session: Session) -> some View {
		Form {
			Section {
				if let s = session.server {
					LabeledContent("서버") {
						HStack(spacing: 6) {
							Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 8, height: 8)
							Text(s.displayName)
						}
					}
					LabeledContent("접속", value: s.subtitle)
				}
				if !session.serverVersion.isEmpty { LabeledContent("서버 버전", value: session.serverVersion) }
				LabeledContent("데이터베이스", value: "\(session.databases.count.formatted())개 · 테이블 \(session.tables.count.formatted())개")
			}
			Section {
				Toggle(isOn: Binding(get: { session.server?.warnsDangerousSQL ?? true }, set: { on in
					guard var s = session.server else { return }
					s.warnDangerousSQL = on
					session.updateServer(s)
					// 목록에 저장한 서버면 iCloud 파일에도 (퀵 커넥트로 저장 안 한 접속은 이 창을 닫으면 잊는다)
					if store.servers.contains(where: { $0.id == s.id }) { store.save(s) }
				})) {
					Text("위험한 SQL 실행 전에 경고")
					Text("쿼리 패널에서 DROP·TRUNCATE·ALTER·DELETE·WHERE 없는 UPDATE 를 실행하기 전에 묻습니다")
				}
			} header: {
				Text("이 서버 설정")
			} footer: {
				Text("서버마다 따로이고, iCloud 로 다른 맥과 같이 맞춰집니다.").foregroundStyle(.tertiary)
			}
		}
		.formStyle(.grouped)
	}
}

/// SwiftUI 설정 창(NSWindow)을 직접 다듬는다: 내용이 탭줄 밑으로 들어가지 않게 하고 탭줄 아래 구분선.
/// 맥 26 SwiftUI 설정창은 내용이 탭줄 밑까지 깔려(fullSizeContentView) 마우스를 올리거나 창이 비활성일 때만 띠가 보였다 (사용자 지적)
struct SettingsWindowStyler: NSViewRepresentable {
	final class Probe: NSView {
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let w = window else { return }
			DispatchQueue.main.async {
				w.styleMask.remove(.fullSizeContentView)
				w.titlebarAppearsTransparent = false
				w.titlebarSeparatorStyle = .line
				w.toolbarStyle = .preference
			}
		}
	}
	func makeNSView(context: Context) -> Probe { Probe() }
	func updateNSView(_ v: Probe, context: Context) {}
}
