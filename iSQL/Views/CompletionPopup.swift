import AppKit

/// 자동완성 목록 창: 커서 아래에 뜨는 작은 창 (키 창이 되지 않아 입력은 계속 편집기로 간다).
/// 줄 = [아이콘] 이름  흐린 타입/DB ······ 코멘트(오른쪽 끝)
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
	private final class Panel: NSPanel {
		override var canBecomeKey: Bool { false }
		override var canBecomeMain: Bool { false }
	}

	/// 창이 키가 아니어도 고른 줄을 파랗게
	private final class RowView: NSTableRowView {
		override var isEmphasized: Bool { get { true } set {} }
	}

	private let panel: Panel
	private let table = NSTableView()
	private(set) var items: [CompletionItem] = []
	/// 고르면 (두 번 누르기)
	var onPick: ((CompletionItem) -> Void)?
	private let rowHeight: CGFloat = 22
	private let maxRows = 10

	var isVisible: Bool { panel.isVisible }
	var selected: CompletionItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

	override init() {
		panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		super.init()
		panel.isFloatingPanel = true
		panel.hasShadow = true
		panel.backgroundColor = .clear
		panel.isOpaque = false
		let effect = NSVisualEffectView()
		effect.material = .menu
		effect.state = .active
		effect.wantsLayer = true
		effect.layer?.cornerRadius = 8
		effect.layer?.masksToBounds = true
		let col = NSTableColumn(identifier: .init("c"))
		col.resizingMask = .autoresizingMask
		table.addTableColumn(col)
		table.headerView = nil
		table.rowHeight = rowHeight
		table.intercellSpacing = NSSize(width: 0, height: 0)
		table.backgroundColor = .clear
		table.style = .plain
		table.selectionHighlightStyle = .regular
		table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(doubleClicked)
		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		scroll.contentView.drawsBackground = false
		scroll.translatesAutoresizingMaskIntoConstraints = false
		effect.addSubview(scroll)
		NSLayoutConstraint.activate([
			scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
			scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
			scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
		])
		panel.contentView = effect
	}

	/// 커서 사각형(화면 좌표) 아래에 띄운다. 화면 아래가 모자라면 위에
	func show(_ list: [CompletionItem], below caret: NSRect, parent: NSWindow) {
		items = list
		table.reloadData()
		table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
		table.scrollRowToVisible(0)
		let h = CGFloat(min(list.count, maxRows)) * rowHeight + 8
		var origin = NSPoint(x: caret.minX - 26, y: caret.minY - h - 2)
		if let screen = parent.screen?.visibleFrame {
			if origin.y < screen.minY { origin.y = caret.maxY + 2 }
			origin.x = min(max(origin.x, screen.minX), screen.maxX - panel.frame.width)
		}
		panel.setFrame(NSRect(origin: origin, size: NSSize(width: 520, height: h)), display: true)
		if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
		panel.orderFront(nil)
	}

	func hide() {
		guard panel.isVisible else { return }
		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	/// ↑ ↓ (끝에서 돌아간다), 쪽 단위
	func move(_ d: Int) {
		guard !items.isEmpty else { return }
		var r = table.selectedRow + d
		if abs(d) == 1 { r = (r + items.count) % items.count } else { r = min(max(r, 0), items.count - 1) }
		table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
		table.scrollRowToVisible(r)
	}

	@objc private func doubleClicked() {
		if let s = selected { onPick?(s) }
	}

	// MARK: 표

	func numberOfRows(in tableView: NSTableView) -> Int { items.count }

	func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let it = items[row]
		let v = NSView()
		let icon = NSImageView()
		icon.image = NSImage(systemSymbolName: Self.symbol(it.kind), accessibilityDescription: nil)
		icon.contentTintColor = Self.tint(it.kind)
		icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
		let name = NSTextField(labelWithString: it.label)
		name.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
		name.lineBreakMode = .byTruncatingTail
		let detail = NSTextField(labelWithString: it.detail)
		detail.font = .systemFont(ofSize: 11)
		detail.textColor = .tertiaryLabelColor
		detail.lineBreakMode = .byTruncatingTail
		let comment = NSTextField(labelWithString: it.comment)
		comment.font = .systemFont(ofSize: 12)
		comment.textColor = .secondaryLabelColor
		comment.lineBreakMode = .byTruncatingTail
		comment.alignment = .right
		for f in [icon, name, detail, comment] as [NSView] { f.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(f) }
		name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
		detail.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
		comment.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		NSLayoutConstraint.activate([
			icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
			icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
			icon.widthAnchor.constraint(equalToConstant: 16),
			name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
			name.centerYAnchor.constraint(equalTo: v.centerYAnchor),
			detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
			detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
			comment.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
			comment.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
			comment.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
		])
		return v
	}

	private static func symbol(_ k: CompletionItem.Kind) -> String {
		switch k {
		case .column: "c.square"
		case .table: "tablecells"
		case .view: "eye"
		case .database: "cylinder.split.1x2"
		case .keyword: "k.square"
		case .function: "f.square"
		}
	}

	private static func tint(_ k: CompletionItem.Kind) -> NSColor {
		switch k {
		case .column: .systemTeal
		case .table, .view: .systemBlue
		case .database: .systemPurple
		case .keyword: .systemGray
		case .function: .systemOrange
		}
	}
}
