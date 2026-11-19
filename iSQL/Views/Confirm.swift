import AppKit

/// 확인·알림 창 하나로 (사용자 2026-11-19: 확인 창 모양이 서로 달랐다).
/// 앞에 있는 창이 있으면 그 창에 붙는 시트(그 창만 멈춤), 창이 없을 때만 앱 아이콘이 붙은 따로 뜨는 창.
/// SwiftUI .confirmationDialog·.alert 도 맥에서는 같은 시트로 그려져 모양이 같다 (그대로 둔다).
/// 규칙: 첫 버튼이 기본(엔터), 되돌릴 수 없으면 destructive(빨강), 취소는 Esc. 제목 한 줄 + 설명 한 줄.
/// 예외: SSH 키 암호 창(Askpass)은 ssh 가 띄운 따로 된 프로세스라 창이 없어 늘 따로 뜬다
@MainActor
enum Confirm {
	/// 묻는다. 고른 버튼 번호(buttons 안), 취소면 nil
	@discardableResult
	static func ask(_ title: String, _ message: String = "", buttons: [String], destructive: Bool = false,
	                cancel: String? = "취소", accessory: NSView? = nil, window: NSWindow? = nil) async -> Int? {
		let a = NSAlert()
		a.messageText = title
		a.informativeText = message
		for b in buttons { a.addButton(withTitle: b) }
		if destructive { a.buttons.first?.hasDestructiveAction = true }
		if let cancel { a.addButton(withTitle: cancel).keyEquivalent = "\u{1b}" }
		if let accessory {
			a.accessoryView = accessory
			a.window.initialFirstResponder = accessory
		}
		let r = await present(a, window: window)
		let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
		return buttons.indices.contains(i) ? i : nil
	}

	/// 알리기 (확인 버튼 하나)
	static func inform(_ title: String, _ message: String = "", window: NSWindow? = nil) async {
		_ = await ask(title, message, buttons: ["확인"], cancel: nil, window: window)
	}

	/// 붙을 창: 받은 창 → 키 창 → 주 창. 이미 시트가 떠 있으면 그 시트 위에
	static func targetWindow(_ preferred: NSWindow? = nil) -> NSWindow? {
		guard var w = [preferred, NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }).first(where: { $0.isVisible }) else { return nil }
		while let s = w.attachedSheet { w = s }
		return w
	}

	private static func present(_ a: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
		guard let w = targetWindow(window) else { return a.runModal() }
		return await withCheckedContinuation { cont in
			a.beginSheetModal(for: w) { cont.resume(returning: $0) }
		}
	}
}
