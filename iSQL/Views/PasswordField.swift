import SwiftUI
import AppKit

/// 비밀번호 입력칸. SwiftUI SecureField 대신 AppKit NSSecureTextField 를 그대로 쓴다.
/// macOS 26 의 SwiftUI SecureField 는 보안 입력은 켜지만 입력기를 영문(ABC)으로 바꾸지 않아서
/// 한글 입력기를 쓰는 중이면 포커스를 받을 때 "한" 이 뜨고 한글이 들어가려 한다 (2026-11-17 사용자 지적, 확인함:
/// SwiftUI 칸 = 2SetKorean, AppKit 칸 = ABC). AppKit 칸은 포커스를 받으면 영문으로, 떠나면 원래 입력기로 돌아간다
struct PasswordField: NSViewRepresentable {
	var placeholder = ""
	@Binding var text: String
	/// false = 테두리·바탕 없이 (바깥에서 상자를 그릴 때)
	var bordered = true
	/// true 로 바꾸면 이 칸에 포커스를 주고 false 로 되돌린다
	var focus: Binding<Bool>? = nil
	var onSubmit: (() -> Void)? = nil

	func makeNSView(context: Context) -> Field {
		let f = Field()
		f.delegate = context.coordinator
		f.placeholderString = placeholder
		f.font = .systemFont(ofSize: NSFont.systemFontSize)
		f.lineBreakMode = .byClipping
		f.usesSingleLineMode = true
		f.cell?.isScrollable = true
		if bordered {
			f.bezelStyle = .roundedBezel
		} else {
			f.isBordered = false
			f.isBezeled = false
			f.drawsBackground = false
			f.focusRingType = .none
		}
		f.setContentHuggingPriority(.defaultLow, for: .horizontal)
		f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return f
	}

	func updateNSView(_ f: Field, context: Context) {
		context.coordinator.parent = self
		if f.stringValue != text { f.stringValue = text }
		f.placeholderString = placeholder
		f.isEnabled = context.environment.isEnabled
		if let focus, focus.wrappedValue {
			f.wantsFocus = true
			DispatchQueue.main.async {
				f.takeFocusIfWanted()
				focus.wrappedValue = false
			}
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	final class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: PasswordField
		init(_ p: PasswordField) { parent = p }

		func controlTextDidChange(_ n: Notification) {
			guard let f = n.object as? NSTextField else { return }
			parent.text = f.stringValue
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
			guard sel == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit else { return false }
			parent.text = control.stringValue
			submit()
			return true
		}
	}

	/// 창에 붙기 전에 포커스를 달라고 하면 붙을 때 준다 (시트가 뜨자마자 포커스)
	final class Field: NSSecureTextField {
		var wantsFocus = false
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			DispatchQueue.main.async { [weak self] in self?.takeFocusIfWanted() }
		}
		func takeFocusIfWanted() {
			guard wantsFocus, let w = window, isEnabled else { return }
			wantsFocus = false
			w.makeFirstResponder(self)
		}
	}
}
