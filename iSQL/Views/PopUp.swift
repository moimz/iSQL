import SwiftUI
import AppKit

/// 너비를 정확히 지키는 선택 버튼 (NSPopUpButton).
/// 맥 26 의 SwiftUI Picker 는 `.frame(width:)` 를 줘도 칸을 채우지 않고 가운데에 떠서 줄이 들쭉날쭉해진다
struct PopUp<Value: Hashable>: NSViewRepresentable {
	@Binding var selection: Value
	/// (보일 글자, 값). 값이 nil 이면 구분선
	let options: [(title: String, value: Value?)]

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSPopUpButton {
		let b = NSPopUpButton(frame: .zero, pullsDown: false)
		b.target = context.coordinator
		b.action = #selector(Coordinator.changed(_:))
		b.lineBreakMode = .byTruncatingTail
		b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		b.setContentHuggingPriority(.defaultLow, for: .horizontal)
		fill(b)
		return b
	}

	func updateNSView(_ b: NSPopUpButton, context: Context) {
		context.coordinator.parent = self
		let titles = options.map { $0.value == nil ? "—" : $0.title }
		if context.coordinator.lastTitles != titles { fill(b); context.coordinator.lastTitles = titles }
		if let i = options.firstIndex(where: { $0.value == selection }), b.indexOfSelectedItem != i { b.selectItem(at: i) }
	}

	/// SwiftUI 가 준 너비를 그대로 쓴다. 높이는 한 번만 잰다
	/// (NSPopUpButton.intrinsicContentSize 는 물을 때마다 메뉴 글자를 전부 재서, 애니메이션 프레임마다 불리면 무겁다)
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
		let c = context.coordinator
		if c.cachedHeight == nil || c.cachedControlSize != nsView.controlSize { c.cachedHeight = nsView.intrinsicContentSize.height; c.cachedControlSize = nsView.controlSize }
		return CGSize(width: proposal.width ?? 120, height: c.cachedHeight ?? 24)
	}

	private func fill(_ b: NSPopUpButton) {
		b.removeAllItems()
		let menu = b.menu!
		for o in options {
			if o.value == nil { menu.addItem(.separator()) } else { menu.addItem(withTitle: o.title, action: nil, keyEquivalent: "") }
		}
		if let i = options.firstIndex(where: { $0.value == selection }) { b.selectItem(at: i) }
	}

	final class Coordinator: NSObject {
		var parent: PopUp
		var lastTitles: [String] = []
		var cachedHeight: CGFloat?
		var cachedControlSize: NSControl.ControlSize?
		init(_ p: PopUp) { parent = p; lastTitles = p.options.map { $0.value == nil ? "—" : $0.title } }
		@objc func changed(_ sender: NSPopUpButton) {
			let i = sender.indexOfSelectedItem
			guard parent.options.indices.contains(i), let v = parent.options[i].value else { return }
			parent.selection = v
		}
	}
}
