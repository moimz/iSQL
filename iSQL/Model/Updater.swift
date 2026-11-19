import SwiftUI
import Sparkle

/// 자동 업데이트 (Sparkle, 사용자 2026-11-19).
/// 새 버전 목록(appcast.xml)은 GitHub 최신 릴리즈 파일 — Info.plist 의 SUFeedURL
/// (releases/latest/download/appcast.xml: 늘 최신 릴리즈로 이어지는 정적 주소라 GitHub API 횟수 제한이 없다).
/// 업데이트 zip 은 Sparkle EdDSA 키로 서명하고 앱에는 공개 키(SUPublicEDKey)만 둔다. 비밀 키는 배포하는 맥의 키체인에만.
/// 새 버전이 있으면 릴리즈 설명과 함께 설치 / 나중에 / 건너뛰기를 묻는다 (묻지 않고 설치하지 않음)
@MainActor @Observable
final class Updater {
	static let shared = Updater()

	@ObservationIgnored private let controller: SPUStandardUpdaterController
	@ObservationIgnored private var observation: NSKeyValueObservation?
	/// "업데이트 확인…" 을 누를 수 있는지 (확인 중이면 못 누름)
	private(set) var canCheck = false

	private init() {
		#if DEBUG
		// 디버그(시험) 빌드는 업데이트를 확인하지 않는다 — 자동 시험 중에 업데이트 창이 뜨지 않게
		controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
		#else
		controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
		#endif
		observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
			let can = u.canCheckForUpdates
			Task { @MainActor in self?.canCheck = can }
		}
	}

	/// 메뉴 iSQL > 업데이트 확인…
	func checkForUpdates() { controller.checkForUpdates(nil) }

	/// 앱 설정 > 일반 > 자동으로 업데이트 확인 (Sparkle 이 UserDefaults 에 기억한다)
	var automaticallyChecks: Bool {
		get { access(keyPath: \.automaticallyChecks); return controller.updater.automaticallyChecksForUpdates }
		set { withMutation(keyPath: \.automaticallyChecks) { controller.updater.automaticallyChecksForUpdates = newValue } }
	}
}
