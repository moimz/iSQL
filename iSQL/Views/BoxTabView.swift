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
		let t = NSTabView()
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
