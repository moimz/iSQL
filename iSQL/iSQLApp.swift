import SwiftUI

@main
enum Main {
	static func main() {
		// ssh 가 비밀번호를 물으려고 이 앱을 SSH_ASKPASS 로 띄운 경우: 창 없이 답만 하고 끝난다
		if Askpass.runIfNeeded() { return }
		// 앱이 죽어서 남은 터널을 끄고(다른 iSQL 이 쓰는 터널은 그대로), 이번에 끝날 때 내 터널도 끈다
		TunnelRegistry.killOrphans()
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
			TunnelRegistry.killMine()
		}
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
		return s
	}()

	var body: some Scene {
		// 창마다 서버 접속이 따로 있다 (⌘N 으로 다른 서버를 함께 연다)
		WindowGroup {
			ContentView()
				.environment(store)
				.frame(minWidth: 960, minHeight: 600)
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
					store.load()
				}
		}
		.windowToolbarStyle(.unified)

		// 서버 설정 창 (제목바 톱니·⌘,): 맥 설정창처럼 위에 아이콘 탭. 내용은 마지막으로 고른 창의 서버
		Settings {
			ServerSettingsView()
				.environment(store)
		}
	}
}
