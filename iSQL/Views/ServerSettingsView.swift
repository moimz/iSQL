import SwiftUI
import AppKit

/// 설정 창이 보여 줄 서버 (창마다 접속이 따로라, 톱니를 누른·서버를 고른 창의 세션)
@Observable
final class SettingsTarget {
	static let shared = SettingsTarget()
	weak var session: Session?
}

/// 서버 설정 창 (Settings 장면). 맥 설정창처럼 위에 아이콘 탭.
/// 일반 = iCloud 로 동기화되는 서버별 앱 설정, 사용자 계정 = MySQL 사용자 관리, 상태·서버 설정 = 준비 중
struct ServerSettingsView: View {
	@Environment(ServerStore.self) private var store
	private var target = SettingsTarget.shared
	/// 설정 창 폭: 맥 설정창처럼 탭을 바꿔도 폭은 그대로, 높이만 바뀐다 (폭이 바뀌면 탭 버튼이 움직였다, 사용자 지적)
	static let width: CGFloat = 920
	/// 마지막으로 본 탭 (이 맥에만)
	@AppStorage("settingsTab") private var tab = "general"

	var body: some View {
		TabView(selection: $tab) {
			Tab("일반", systemImage: "gearshape", value: "general") { page { general($0) }.frame(width: Self.width, height: 440) }
			Tab("사용자 계정", systemImage: "person.2", value: "accounts") { page { accounts($0) }.frame(width: Self.width, height: 620) }
			Tab("상태", systemImage: "chart.bar.xaxis", value: "status") { page { _ in soon("상태", "chart.bar.xaxis", "서버·프로세스·질의 통계·상태 변수") }.frame(width: Self.width, height: 440) }
			Tab("서버 설정", systemImage: "slider.horizontal.3", value: "variables") { page { _ in soon("서버 설정", "slider.horizontal.3", "서버 변수(SHOW VARIABLES) 보기·고치기") }.frame(width: Self.width, height: 440) }
		}
		// 맥 앱 설정창(Mail 등)처럼 위 아이콘 탭줄은 늘 불투명한 띠 + 아래 구분선.
		// 맥 26 SwiftUI 설정창은 내용이 탭줄 밑까지 깔려(fullSizeContentView) 마우스를 올리거나 창이 비활성일 때만 띠가 보였다 (사용자 지적)
		.background(SettingsWindowStyler())
	}

	private func soon(_ title: String, _ icon: String, _ what: String) -> some View {
		ContentUnavailableView(title, systemImage: icon, description: Text("\(what)는 준비 중입니다."))
	}

	/// 접속한 서버가 없으면 안내
	@ViewBuilder private func page<C: View>(@ViewBuilder _ content: (Session) -> C) -> some View {
		if let s = target.session, s.isConnected {
			content(s)
		} else {
			ContentUnavailableView("접속한 서버가 없습니다", systemImage: "cylinder.split.1x2",
			                       description: Text("서버에 접속한 뒤 제목바의 톱니를 누르세요."))
		}
	}

	// MARK: 일반

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

	// MARK: 사용자 계정

	private func accounts(_ session: Session) -> some View {
		UserAccountsView(session: session, manager: session.accountManager())
			.id(ObjectIdentifier(session))
	}
}

/// 설정 창(NSWindow)을 직접 다듬는다: 내용이 탭줄 밑으로 들어가지 않게 하고 탭줄 아래 구분선
private struct SettingsWindowStyler: NSViewRepresentable {
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
