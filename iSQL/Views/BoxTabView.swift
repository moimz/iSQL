import SwiftUI
import AppKit

/// AppKit 탭 상자 (NSTabView, 상자 위 테두리에 걸친 탭 — Mail 계정 설정과 같은 것).
/// 설정 창(Settings 장면) 안에서 SwiftUI TabView 를 쓰면 안쪽 탭이 창 위 아이콘 탭줄로 끌려 올라가고,
/// 세그먼트로 흉내 내면 배경이 투명해 뒤 테두리 선이 비쳐서 AppKit 것을 그대로 쓴다
struct BoxTabView: NSViewRepresentable {
	let titles: [String]
	@Binding var selection: Int
	let content: (Int) -> AnyView

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSTabView {
		let t = RetilingTabView()
		t.tabViewType = .topTabsBezelBorder
		for (i, title) in titles.enumerated() {
			let item = NSTabViewItem(identifier: i)
			item.label = title
			let host = NSHostingView(rootView: content(i))
			// 탭 칸 크기를 따르게 (SwiftUI 내용 크기로 탭 상자가 늘어나지 않게)
			host.sizingOptions = []
			item.view = host
			t.addTabViewItem(item)
		}
		t.selectTabViewItem(at: min(selection, titles.count - 1))
		t.delegate = context.coordinator
		return t
	}

	func updateNSView(_ t: NSTabView, context: Context) {
		context.coordinator.parent = self
		for (i, item) in t.tabViewItems.enumerated() {
			(item.view as? NSHostingView<AnyView>)?.rootView = content(i)
		}
		if let sel = t.selectedTabViewItem, t.indexOfTabViewItem(sel) != selection, selection < t.numberOfTabViewItems {
			t.selectTabViewItem(at: selection)
		}
	}

	final class Coordinator: NSObject, NSTabViewDelegate {
		var parent: BoxTabView
		init(_ p: BoxTabView) { parent = p }
		func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
			guard let item else { return }
			let i = tabView.indexOfTabViewItem(item)
			if parent.selection != i { DispatchQueue.main.async { self.parent.selection = i } }
		}
	}
}

/// 탭 너비를 다시 재는 NSTabView.
/// 설정 창에서 다른 탭을 봤다 오면 이 상자가 거의 0 크기로 줄었다 커지는데, NSTabView 는 줄었을 때 잰 탭 너비("전…")를 그대로 둔다 (사용자 지적)
/// → 폭이 바뀌거나, 창에 다시 붙거나, 다시 보이면 탭을 다시 깐다 (시험에서는 재현이 안 돼 어느 경로든 다시 재게 했다)
final class RetilingTabView: NSTabView {
	/// 마지막으로 탭을 깐 폭
	private var tiledWidth: CGFloat = -1

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		if newSize.width >= 200, abs(newSize.width - tiledWidth) > 0.5 { retile() }
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window != nil { DispatchQueue.main.async { self.retile() } }
	}

	override func viewDidUnhide() {
		super.viewDidUnhide()
		retile()
	}

	/// 탭 종류를 잠깐 바꿨다 되돌리고 이름을 다시 넣으면 탭 너비를 새로 잰다
	func retile() {
		tiledWidth = frame.width
		let type = tabViewType
		let selected = selectedTabViewItem
		tabViewType = .noTabsNoBorder
		tabViewType = type
		for item in tabViewItems { let l = item.label; item.label = ""; item.label = l }
		if let selected { selectTabViewItem(selected) }
		needsLayout = true
		needsDisplay = true
	}
}
