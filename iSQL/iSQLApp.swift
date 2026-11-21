import SwiftUI

@main
enum Main {
	static func main() {
		// ssh 가 비밀번호를 물으려고 이 앱을 SSH_ASKPASS 로 띄운 경우: 창 없이 답만 하고 끝난다
		if Askpass.runIfNeeded() { return }
		// 앱이 죽어서 남은 터널을 끄고(다른 iSQL 이 쓰는 터널은 그대로), 이번에 끝날 때 내 터널도 끈다
		TunnelRegistry.killOrphans()
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
			AutoConnect.terminating = true
			TunnelRegistry.killMine()
		}
		// macOS 기본 창 탭(보기 > 탭 막대 보기, 윈도우 > 이전 탭 보기 …)은 쓰지 않는다: iSQL 은 창 안에 자기 탭이 있어서
		// 메뉴의 "이전 탭 · 다음 탭"(AppMenus.swift)과 헷갈린다 (사용자 2026-11-19)
		NSWindow.allowsAutomaticWindowTabbing = false
		iSQLApp.main()
	}
}

struct iSQLApp: App {
	@State private var store: ServerStore = {
		let s = ServerStore()
		s.load()
		// 다른 맥에서 iCloud 로 바뀐 서버 파일이 오면 다시 읽는다
		CloudWatcher.shared.start { s.load() }
		Keychain.probe()
		// MCP: 서버 목록을 알려 주고, 켜 두었으면 띄운다
		AppState.shared.store = s
		MCPServer.shared.startIfEnabled()
		// 자동 업데이트: 켜 두었으면 하루 한 번 새 버전을 확인한다
		_ = Updater.shared
		return s
	}()

	var body: some Scene {
		// 창마다 서버 접속이 따로 있다 (⌘N 으로 다른 서버를 함께 연다)
		WindowGroup {
			ContentView()
				.environment(store)
				.frame(minWidth: 1200, minHeight: 600)
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
					store.load()
				}
		}
		.windowToolbarStyle(.unified)
		// .isql 파일을 열 때 새 창을 만들지 않는다 (열린 창의 onOpenURL 이 받는다)
		.handlesExternalEvents(matching: [])
		.commands {
			// iSQL에 관하여: 기본 정보 창 대신 직접 만든 창 (AboutView), 그 아래 업데이트 확인
			CommandGroup(replacing: .appInfo) {
				AboutMenuButton()
				UpdateMenuButton()
			}
			// 보기 · 파일 · 윈도우 메뉴의 탭 단축키 (AppMenus.swift)
			CommandGroup(before: .toolbar) { ViewMenuItems() }
			// 저장 · 탭 닫기(⌘W) · 창 닫기(⌘⇧W): 기본 "닫기 ⌘W" 를 바꾼다
			CommandGroup(replacing: .saveItem) { FileMenuItems() }
			CommandGroup(before: .windowList) { WindowMenuItems() }
			CommandGroup(replacing: .importExport) {
				Button("서버 설정 가져오기…") { AppState.shared.requestTransfer(.importFile(nil)) }
				Button("서버 정보 내보내기…") { AppState.shared.requestTransfer(.export) }
			}
		}

		// iSQL 정보 창
		Window("iSQL 정보", id: AboutView.windowID) {
			AboutView()
		}
		.windowResizability(.contentSize)
		.windowStyle(.hiddenTitleBar)
		.restorationBehavior(.disabled)
		.defaultPosition(.center)

		// iSQL 앱 설정 (⌘,): 일반 · MCP. 서버별 설정은 제목바 톱니로 여는 따로 된 창(ServerSettingsWindow)
		Settings {
			AppSettingsView()
				.environment(store)
		}
	}
}

/// 메뉴 iSQL > 업데이트 확인… (확인 중에는 흐리게)
private struct UpdateMenuButton: View {
	private var updater = Updater.shared
	var body: some View {
		Button("업데이트 확인…") { updater.checkForUpdates() }
			.disabled(!updater.canCheck)
	}
}
