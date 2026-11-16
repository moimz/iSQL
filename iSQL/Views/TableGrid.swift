import SwiftUI
import AppKit

// MARK: - 공급자 규칙

/// 표 한 컬럼
struct GridColumn: Equatable {
	/// 정렬·메뉴에 쓰는 이름 (실제 컬럼 이름)
	var key: String
	var title: String
	var comment = ""
	var isKey = false
	/// 숫자: 오른쪽 정렬 + 고정폭 숫자
	var numeric = false
	/// 고정폭 글꼴 (타입 같은 것)
	var mono = false
	var center = false
	/// 처음 너비 (nil 이면 제목·종류로 정한다)
	var width: CGFloat?
	/// 긴 글자 컬럼 (처음 너비를 넓게)
	var long = false
}

/// 칸 하나
enum GridCellState { case clean, edited, inserted, deleted }

struct GridCell {
	/// nil 이면 NULL (회색 NULL 로 보인다)
	var text: String?
	var state: GridCellState = .clean
	var tooltip: String?
	/// 글자 앞 아이콘 (구조의 키 표시 등)
	var icon: NSImage?
	/// 흐린 글자
	var dim = false
}

enum GridMenuItem {
	case action(String, () -> Void)
	/// 흐린 항목 (아직 기능이 없거나 지금 못 하는 것)
	case disabled(String)
	case separator
}

/// 테이블 하나의 오른쪽 클릭 메뉴 (사이드바 테이블·DB 개요에서 하나 골랐을 때 같은 순서).
/// 자주 쓰는 것 위, 되돌릴 수 없는 것 맨 아래
enum TableMenu {
	static func items(isView: Bool, open: @escaping () -> Void, export: @escaping () -> Void) -> [GridMenuItem] {
		let kind = isView ? "뷰" : "테이블"
		return [
			.action("열기", open),
			.separator,
			.action("\(kind) 내보내기…", export),
			.disabled("\(kind) 복제…"),
			.disabled("\(kind) 이름 바꾸기…"),
			.separator,
		] + (isView ? [] : [GridMenuItem.disabled("테이블 비우기…")]) + [
			.disabled("\(kind) 삭제…"),
		]
	}
}

/// 공용 표(TableGrid)에 내용을 대는 쪽. 읽기 전용이면 컬럼·행·칸만 정하면 된다 (나머지는 기본값)
protocol GridSource: AnyObject {
	/// 바뀌면 컬럼을 다시 만든다
	var gridID: String { get }
	var gridColumns: [GridColumn] { get }
	/// 바뀌면 행을 다시 그린다
	var gridVersion: Int { get }
	var rowCount: Int { get }
	func cell(_ row: Int, _ col: Int) -> GridCell

	var canEdit: Bool { get }
	func setText(_ row: Int, _ col: Int, _ text: String)

	var currentSort: (key: String, ascending: Bool)? { get }
	/// 정렬 요청. 못 하면 false (삑)
	func sort(by key: String?, ascending: Bool) -> Bool

	func headerMenu(_ col: Int) -> [GridMenuItem]
	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem]
	/// cellMenu 항목을 값/행 복사보다 먼저 보일지 (DB 개요: 테이블 메뉴가 주인공)
	var cellMenuFirst: Bool { get }
	/// ⌫. 못 하면 false (삑)
	func deleteRows(_ rows: IndexSet) -> Bool
	/// 표 하나를 여러 공급자가 돌려 쓰므로 공급자마다 스크롤 위치를 기억한다
	var scrollOrigin: CGPoint { get set }
	/// 편집할 수 없는 표에서 행을 두 번 누르면 (DB 개요: 그 테이블 열기)
	func activateRow(_ row: Int)
}

extension GridSource {
	var canEdit: Bool { false }
	func setText(_ row: Int, _ col: Int, _ text: String) {}
	var currentSort: (key: String, ascending: Bool)? { nil }
	func sort(by key: String?, ascending: Bool) -> Bool { false }
	func headerMenu(_ col: Int) -> [GridMenuItem] { [] }
	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] { [] }
	var cellMenuFirst: Bool { false }
	func deleteRows(_ rows: IndexSet) -> Bool { false }
	func activateRow(_ row: Int) {}
}

// MARK: - 공용 표

/// 앱의 모든 표 (데이터, 구조, 앞으로 쿼리 결과). NSTableView: 세로선, 줄무늬, 줄 높이 24, 두 줄 대신 한 줄 제목.
/// 고칠 수 있는 공급자면 두 번 클릭·엔터로 고치고, 고친 칸은 노랑, 새 행은 초록, 지울 행은 빨강 + 취소선.
struct TableGrid: NSViewRepresentable {
	let source: GridSource
	var onSelection: ((IndexSet) -> Void)?

	func makeCoordinator() -> GridController { GridController(source: source) }

	func makeNSView(context: Context) -> NSScrollView {
		context.coordinator.onSelection = onSelection
		return context.coordinator.scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		let c = context.coordinator
		c.onSelection = onSelection
		c.setSource(source)
	}
}

/// 탭마다 AppKit 표를 하나씩 살려 두고 보이는 것만 보인다 (isHidden: 숨긴 표는 배치도 그리기도 안 한다).
/// SwiftUI 에서 투명하게 살려 두면 애니메이션 프레임마다 숨은 탭까지 다시 배치했고(패널 열기 472ms),
/// 표 하나를 돌려 쓰면 컬럼이 다른 탭으로 갈 때마다 행을 비우고 새로 만들었다(탭 전환 114ms). Time Profiler 로 확인 (Ai/iSQL.md)
struct TableGridHost: NSViewRepresentable {
	let active: GridSource
	/// 열려 있는 탭들의 공급자 (닫힌 탭의 표는 정리한다)
	let alive: [GridSource]
	/// 지금 보이는 표의 스크롤 뷰 (양쪽 스크롤 맞추기용)
	var onVisibleScroll: ((NSScrollView) -> Void)? = nil
	var onSelection: ((IndexSet) -> Void)?

	final class Coordinator {
		var controllers: [ObjectIdentifier: GridController] = [:]
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> GridHostView { GridHostView() }

	func updateNSView(_ container: GridHostView, context: Context) {
		let c = context.coordinator
		let key = ObjectIdentifier(active)
		let aliveIDs = Set(alive.map { ObjectIdentifier($0) }).union([key])
		for (id, ctl) in c.controllers where !aliveIDs.contains(id) {
			ctl.scroll.removeFromSuperview()
			c.controllers[id] = nil
		}
		let ctl: GridController
		if let existing = c.controllers[key] {
			ctl = existing
		} else {
			ctl = GridController(source: active)
			ctl.scroll.frame = container.bounds
			container.addSubview(ctl.scroll)
			c.controllers[key] = ctl
		}
		ctl.onSelection = onSelection
		for (id, other) in c.controllers {
			let show = id == key
			guard other.scroll.isHidden == show else { continue }
			if !show, let w = other.table.window, let fr = w.firstResponder as? NSView, fr.isDescendant(of: other.scroll) {
				// 숨는 표가 키 입력(⌫ 등)을 받지 않게
				w.makeFirstResponder(nil)
			}
			// 숨어 있던 표는 그동안 크기를 맞추지 않았으니 보일 때 한 번 맞춘다
			if show { other.scroll.frame = container.bounds }
			other.scroll.isHidden = !show
		}
		ctl.refresh()
		onVisibleScroll?(ctl.scroll)
	}
}

/// 보이는 표만 크기를 맞춘다. 숨은 표까지 자동 크기 조절하면 패널 애니메이션 프레임마다 숨은 표 전부가 다시 배치된다 (패널 열기 342ms, Time Profiler 로 확인)
final class GridHostView: NSView {
	override var isFlipped: Bool { true }
	override func resizeSubviews(withOldSize oldSize: NSSize) {
		for v in subviews where !v.isHidden { v.frame = bounds }
	}
}

/// 표 하나 (NSScrollView + NSTableView) 와 그 공급자를 잇는다
final class GridController: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate, NSMenuDelegate {
		let scroll = NSScrollView()
		let table = GridTableView()
		private(set) var source: GridSource
		var onSelection: ((IndexSet) -> Void)?
		var lastVersion = -1
		private var columnSignature = ""
		private var columns: [GridColumn] = []

		init(source: GridSource) {
			self.source = source
			super.init()
			table.coordinator = self
			table.style = .plain
			table.usesAlternatingRowBackgroundColors = true
			table.gridStyleMask = [.solidVerticalGridLineMask]
			table.allowsMultipleSelection = true
			table.allowsColumnReordering = true
			table.columnAutoresizingStyle = .noColumnAutoresizing
			table.rowHeight = 24
			table.intercellSpacing = NSSize(width: 0, height: 0)
			table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
			table.headerView?.menu = makeHeaderMenu()
			table.target = self
			table.doubleAction = #selector(doubleClicked(_:))
			table.menu = makeMenu()
			// 데이터 공급자를 연결하면 표가 바로 행 수를 묻는다 → 컬럼을 먼저 만든다
			syncColumns()
			table.delegate = self
			table.dataSource = self
			table.reloadData()
			lastVersion = source.gridVersion
			scroll.documentView = table
			scroll.hasVerticalScroller = true
			scroll.hasHorizontalScroller = true
			scroll.autohidesScrollers = true
		}

		/// 표 하나를 다른 공급자가 쓰게 바꾼다 (구조 화면·쿼리 결과). 공급자마다 스크롤 위치를 기억한다
		func setSource(_ new: GridSource) {
			if ObjectIdentifier(new) != ObjectIdentifier(source) {
				source.scrollOrigin = scroll.contentView.bounds.origin
				table.window?.makeFirstResponder(nil)
				table.deselectAll(nil)
				source = new
				lastVersion = -1
				refresh()
				scroll.contentView.scroll(to: new.scrollOrigin)
				scroll.reflectScrolledClipView(scroll.contentView)
			} else {
				refresh()
			}
		}

		/// 컬럼·행이 바뀌었으면 다시 그린다
		func refresh() {
			syncColumns()
			if source.gridVersion != lastVersion {
				lastVersion = source.gridVersion
				// 고치는 중인 칸이 있으면 다시 읽지 않는다 (입력이 날아감)
				if table.currentEditor() == nil { table.reloadData() }
				applySortIndicator()
			}
		}

		/// 공급자의 컬럼이 바뀌었으면 다시 만든다
		func syncColumns() {
			let cols = source.gridColumns
			let sig = source.gridID + "|" + cols.map(\.key).joined(separator: ",")
			if sig == columnSignature {
				// 이름은 같고 키·코멘트만 바뀐 경우 (구조로 만든 제목 → 실제 결과)
				if cols != columns { columns = cols; refreshHeaders() }
				return
			}
			columnSignature = sig
			columns = cols
			rebuildColumns()
		}

		/// 컬럼을 바꾸는 동안 행 수를 0 으로 둔다
		private var rebuilding = false

		private func rebuildColumns() {
			// 행이 떠 있는 채로 컬럼을 하나씩 빼고 넣으면 그때마다 보이는 행을 전부 다시 정리해서 느리다 (탭 전환 때 Time Profiler 로 확인)
			// → 행을 먼저 비우고 컬럼을 바꾼 뒤 한 번만 다시 그린다
			rebuilding = true
			table.reloadData()
			defer { rebuilding = false }
			for c in table.tableColumns { table.removeTableColumn(c) }
			for (i, col) in columns.enumerated() {
				let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
				let cell = GridHeaderCell(textCell: col.title)
				cell.representedObject = col.comment
				cell.tag = col.isKey ? GridHeaderCell.keyBit : 0
				tc.headerCell = cell
				tc.headerToolTip = col.comment.isEmpty ? col.title : "\(col.title)\n\(col.comment)"
				// 제목을 누르면 정렬 (어떻게 할지는 공급자가 정한다)
				tc.sortDescriptorPrototype = NSSortDescriptor(key: col.key, ascending: true)
				tc.width = col.width ?? Self.initialWidth(col)
				tc.minWidth = 40
				table.addTableColumn(tc)
			}
			applySortIndicator()
			table.reloadData()
		}

		private func refreshHeaders() {
			for tc in table.tableColumns {
				guard let i = Int(tc.identifier.rawValue), i < columns.count, let cell = tc.headerCell as? GridHeaderCell else { continue }
				cell.representedObject = columns[i].comment
				cell.tag = (cell.tag & ~GridHeaderCell.keyBit) | (columns[i].isKey ? GridHeaderCell.keyBit : 0)
			}
			table.headerView?.needsDisplay = true
		}

		private static func initialWidth(_ col: GridColumn) -> CGFloat {
			let nameW = (col.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
			let commentW = col.comment.isEmpty ? 0 : (col.comment as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 14
			let w = nameW + commentW + 34
			let byType: CGFloat = col.numeric ? 80 : (col.long ? 260 : 150)
			return min(320, max(w, byType))
		}

		private func font(_ col: GridColumn) -> NSFont {
			if col.numeric { return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
			if col.mono { return .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular) }
			return .systemFont(ofSize: NSFont.systemFontSize)
		}

		private func colIndex(_ tc: NSTableColumn?) -> Int? {
			guard let tc, let i = Int(tc.identifier.rawValue), i < columns.count else { return nil }
			return i
		}

		// MARK: 정렬

		private var settingSort = false

		/// 공급자의 정렬 상태를 제목에 보여 준다 (꺾쇠 + 코멘트 자리 비우기)
		func applySortIndicator() {
			settingSort = true
			defer { settingSort = false }
			let sort = source.currentSort
			table.sortDescriptors = sort.map { [NSSortDescriptor(key: $0.key, ascending: $0.ascending)] } ?? []
			for tc in table.tableColumns {
				let on = sort != nil && tc.sortDescriptorPrototype?.key == sort?.key
				if let cell = tc.headerCell as? GridHeaderCell {
					var t = cell.tag & GridHeaderCell.keyBit
					if on { t |= GridHeaderCell.sortBit; if sort?.ascending == false { t |= GridHeaderCell.descBit } }
					cell.tag = t
				}
			}
			table.headerView?.needsDisplay = true
		}

		func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
			guard !settingSort, let d = tableView.sortDescriptors.first, let key = d.key else { return }
			sort(key, ascending: d.ascending)
		}

		private func sort(_ key: String?, ascending: Bool) {
			if !source.sort(by: key, ascending: ascending) { NSSound.beep() }
			applySortIndicator()
		}

		// MARK: 너비 맞추기

		/// 컬럼 경계를 두 번 누르면: 제목(이름 + 코멘트)과 내용(앞 500행)에 맞춘다. 최대 480
		func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
			guard column < tableView.tableColumns.count, let col = colIndex(tableView.tableColumns[column]) else { return 100 }
			let c = columns[col]
			var w = (c.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
			if !c.comment.isEmpty { w += 14 + (c.comment as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width }
			if c.isKey { w += 16 }
			w += 18
			let attrs: [NSAttributedString.Key: Any] = [.font: font(c)]
			for r in 0..<min(source.rowCount, 500) {
				let cell = source.cell(r, col)
				guard let text = cell.text else { continue }
				let shown = text.count > 200 ? String(text.prefix(200)) : text
				var tw = (shown.replacingOccurrences(of: "\n", with: "⏎") as NSString).size(withAttributes: attrs).width + 14
				if let icon = cell.icon { tw += icon.size.width + 4 }
				w = max(w, tw)
				if w >= 480 { break }
			}
			return min(480, max(40, ceil(w)))
		}

		// MARK: 칸

		func numberOfRows(in tableView: NSTableView) -> Int { rebuilding ? 0 : source.rowCount }

		func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
			guard let col = colIndex(tableColumn), row < source.rowCount else { return nil }
			let id = NSUserInterfaceItemIdentifier("cell")
			let field: NSTextField
			if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
				field = reused
			} else {
				field = NSTextField()
				// 행 높이만큼 늘어난 글자 칸은 글자를 위에 붙여 그린다 → 세로 가운데로 그리는 셀
				field.cell = GridTextCell(textCell: "")
				field.identifier = id
				field.isBordered = false
				field.drawsBackground = true
				field.lineBreakMode = .byTruncatingTail
				field.cell?.usesSingleLineMode = true
				field.cell?.truncatesLastVisibleLine = true
				field.delegate = self
			}
			let c = columns[col]
			let cell = source.cell(row, col)
			let f = font(c)
			// 평소엔 편집·선택 불가: 편집 가능한 칸이 많으면 AppKit 이 행마다 키보드 이동 순서를 계산해 느려진다 (Time Profiler 로 확인)
			// 두 번 클릭·엔터 때만 그 칸을 편집 가능하게 바꾼다 (beginEditing)
			field.isEditable = false
			field.isSelectable = false
			field.font = f
			field.alignment = c.numeric ? .right : (c.center ? .center : .left)
			field.placeholderString = cell.text == nil ? "NULL" : nil
			let text = cell.text?.replacingOccurrences(of: "\n", with: "⏎") ?? ""
			// 서식 있는 글자는 field.alignment 를 덮어쓰므로 정렬도 글자에 넣는다
			let para = NSMutableParagraphStyle()
			para.alignment = field.alignment
			para.lineBreakMode = .byTruncatingTail
			var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: cell.dim ? NSColor.secondaryLabelColor : NSColor.labelColor, .paragraphStyle: para]
			switch cell.state {
			case .deleted:
				attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
				attrs[.foregroundColor] = NSColor.systemRed
				field.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
			case .edited: field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
			case .inserted: field.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18)
			case .clean: field.backgroundColor = .clear
			}
			let s = NSMutableAttributedString()
			if let icon = cell.icon {
				let a = NSTextAttachment()
				a.image = icon
				a.bounds = NSRect(x: 0, y: -1, width: icon.size.width, height: icon.size.height)
				s.append(NSAttributedString(attachment: a))
				s.append(NSAttributedString(string: " ", attributes: attrs))
			}
			s.append(NSAttributedString(string: text, attributes: attrs))
			// 문단 설정은 첫 글자 것을 따른다: 아이콘(첨부) 글자에도 넣어야 넘칠 때 … 이 붙는다
			s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
			field.attributedStringValue = s
			field.toolTip = cell.tooltip ?? ((cell.text?.count ?? 0) > 40 ? cell.text : nil)
			return field
		}

		func tableViewSelectionDidChange(_ notification: Notification) {
			guard let cb = onSelection else { return }
			let sel = table.selectedRowIndexes
			DispatchQueue.main.async { cb(sel) }
		}

		// MARK: 고치기

		@objc func doubleClicked(_ sender: NSTableView) {
			if source.canEdit { beginEditing(row: sender.clickedRow, column: sender.clickedColumn) }
			else if sender.clickedRow >= 0 { source.activateRow(sender.clickedRow) }
		}

		/// 그 칸만 편집 가능하게 바꾸고 편집을 시작한다
		func beginEditing(row: Int, column: Int) {
			guard source.canEdit, row >= 0, row < table.numberOfRows, column >= 0, column < table.numberOfColumns else { return }
			guard let col = colIndex(table.tableColumns[column]), source.cell(row, col).state != .deleted else { NSSound.beep(); return }
			if let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField {
				field.isEditable = true
				field.isSelectable = true
			}
			table.editColumn(column, row: row, with: nil, select: true)
		}

		func controlTextDidEndEditing(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			field.isEditable = false
			field.isSelectable = false
			let row = table.row(for: field), ci = table.column(for: field)
			guard row >= 0, ci >= 0, let col = colIndex(table.tableColumns[ci]) else { return }
			// Tab / Shift+Tab: 옆 칸 편집으로 (옆 칸이 평소 편집 불가라 AppKit 이 알아서 넘어가지 않는다)
			let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap { NSTextMovement(rawValue: $0) }
			defer {
				if movement == .tab { DispatchQueue.main.async { self.beginEditing(row: row, column: ci + 1) } }
				if movement == .backtab { DispatchQueue.main.async { self.beginEditing(row: row, column: ci - 1) } }
			}
			let old = source.cell(row, col).text
			let typed = field.stringValue
			// NULL 칸을 비운 채로 끝내면 그대로 NULL
			if old == nil && typed.isEmpty { return }
			if typed == (old?.replacingOccurrences(of: "\n", with: "⏎") ?? "") { return }
			source.setText(row, col, typed.replacingOccurrences(of: "⏎", with: "\n"))
			table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
		}

		// MARK: 오른쪽 클릭 메뉴

		private var headerMenu: NSMenu?

		func makeMenu() -> NSMenu {
			let m = NSMenu()
			m.delegate = self
			return m
		}

		func makeHeaderMenu() -> NSMenu {
			let m = makeMenu()
			headerMenu = m
			return m
		}

		func menuNeedsUpdate(_ menu: NSMenu) {
			menu.removeAllItems()
			if menu === headerMenu {
				// 오른쪽 클릭한 위치로 컬럼을 찾는다 (제목 메뉴에서는 clickedColumn 이 안 채워질 수 있다)
				var index = table.clickedColumn
				if let header = table.headerView, let event = NSApp.currentEvent {
					let i = header.column(at: header.convert(event.locationInWindow, from: nil))
					if i >= 0 { index = i }
				}
				guard index >= 0, index < table.tableColumns.count, let col = colIndex(table.tableColumns[index]) else { return }
				var items = source.headerMenu(col)
				// 정렬은 모든 표에 공통 (공급자가 정렬을 못 하면 메뉴만 빠진다)
				let key = columns[col].key
				let sortItems: [GridMenuItem] = [
					.action("오름차순 정렬") { self.sort(key, ascending: true) },
					.action("내림차순 정렬") { self.sort(key, ascending: false) },
				] + (source.currentSort != nil ? [.action("정렬 없애기") { self.sort(nil, ascending: true) }] : [])
				if !items.isEmpty { items.append(.separator) }
				fill(menu, items + sortItems)
				return
			}
			guard table.clickedRow >= 0 else { return }
			let row = table.clickedRow
			if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
			let col = table.clickedColumn >= 0 ? colIndex(table.tableColumns[table.clickedColumn]) : nil
			var items: [GridMenuItem] = []
			if let col {
				items.append(.action("값 복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(self.source.cell(row, col).text ?? "NULL", forType: .string)
				})
			}
			items.append(.action("행 복사 (\(table.selectedRowIndexes.count)개)") { self.copySelection() })
			let extra = source.cellMenu(row: row, col: col, selection: table.selectedRowIndexes)
			if !extra.isEmpty {
				items = source.cellMenuFirst ? extra + [.separator] + items : items + [.separator] + extra
			}
			fill(menu, items)
		}

		private func fill(_ menu: NSMenu, _ items: [GridMenuItem]) {
			for it in items {
				switch it {
				case .separator: menu.addItem(.separator())
				case .disabled(let title):
					// action 이 없으면 메뉴가 알아서 흐리게 한다 (autoenablesItems)
					menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
				case .action(let title, let run):
					let i = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: "")
					i.target = self
					i.representedObject = run
					menu.addItem(i)
				}
			}
		}

		@objc private func runMenu(_ sender: NSMenuItem) {
			(sender.representedObject as? () -> Void)?()
		}

		// ⌫ 로 선택한 행 지우기
		func deleteSelection() {
			guard !table.selectedRowIndexes.isEmpty, source.deleteRows(table.selectedRowIndexes) else { NSSound.beep(); return }
		}

		var canEdit: Bool { source.canEdit }

		/// 선택한 행을 탭으로 나눠 복사
		func copySelection() {
			let lines = table.selectedRowIndexes.map { r in
				columns.indices.map { source.cell(r, $0).text ?? "NULL" }.joined(separator: "\t")
			}
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
		}
}

/// ⌫ 로 행 삭제, ⌘C 로 선택 행 복사(탭 구분), 엔터로 고치기
final class GridTableView: NSTableView {
	weak var coordinator: GridController?

	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 51, 117:   // delete, forward delete
			coordinator?.deleteSelection()
		case 36, 76:    // return, enter
			if selectedRow >= 0, coordinator?.canEdit == true {
				// 보이는 맨 왼쪽 컬럼부터 고친다 (탭으로 옆 칸으로 간다)
				let col = max(0, column(at: NSPoint(x: visibleRect.minX + 1, y: visibleRect.minY + 1)))
				coordinator?.beginEditing(row: selectedRow, column: col)
			}
		default:
			super.keyDown(with: event)
		}
	}

	@objc func copy(_ sender: Any?) { coordinator?.copySelection() }
}

/// 컬럼 머리: [키]이름 ··· 코멘트. 둘 다 들어갈 너비가 아니면 이름만 (코멘트는 툴팁)
/// 주의: NSCell 은 복사할 때 저장 속성을 얕게 복사한다(NSCopyObject). Swift 저장 속성을 두면 두 번 해제되어 죽는다.
/// 그래서 코멘트는 representedObject, 기본 키 여부는 tag 에 둔다 (둘 다 AppKit 이 제대로 복사한다)
final class GridHeaderCell: NSTableHeaderCell {
	static let keyBit = 1
	static let sortBit = 2
	static let descBit = 4
	private var comment: String { representedObject as? String ?? "" }
	private var isKey: Bool { tag & Self.keyBit != 0 }
	/// 정렬 화살표가 오른쪽에 그려지므로 그만큼 비운다
	private var isSorted: Bool { tag & Self.sortBit != 0 }
	private var isDescending: Bool { tag & Self.descBit != 0 }

	/// 정렬 꺾쇠. 제목을 직접 그리느라 AppKit 의 정렬 화살표가 안 보여서 직접 그린다
	private static func chevron(_ down: Bool) -> NSImage? {
		let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.secondaryLabelColor]))
		return NSImage(systemSymbolName: down ? "chevron.down" : "chevron.up", accessibilityDescription: down ? "내림차순" : "오름차순")?.withSymbolConfiguration(conf)
	}

	private static let keyImage: NSImage? = {
		let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
			.applying(.init(paletteColors: [.systemYellow]))
		return NSImage(systemSymbolName: "key.fill", accessibilityDescription: "기본 키")?.withSymbolConfiguration(conf)
	}()

	override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
		// 마지막 컬럼 뒤 빈 제목 칸은 AppKit 이 이 셀을 복사해 그린다 (글자가 비어 있다) → 꺾쇠·키를 그리지 않는다
		if stringValue.isEmpty { return }
		var r = cellFrame.insetBy(dx: 7, dy: 0)
		if isSorted {
			r.size.width -= 16
			if let img = Self.chevron(isDescending) {
				let s = img.size
				img.draw(in: NSRect(x: r.maxX + 16 - s.width, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
			}
		}
		var x = r.minX
		if isKey, let img = Self.keyImage {
			let s = img.size
			img.draw(in: NSRect(x: x, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
			x += s.width + 4
		}
		let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
		let commentAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
		let name = NSAttributedString(string: stringValue, attributes: nameAttrs)
		let nameSize = name.size()
		let avail = r.maxX - x
		if !comment.isEmpty {
			let c = NSAttributedString(string: comment, attributes: commentAttrs)
			let cs = c.size()
			if nameSize.width + 14 + cs.width <= avail {
				c.draw(at: NSPoint(x: r.maxX - cs.width, y: r.midY - cs.height / 2))
			}
		}
		let nameRect = NSRect(x: x, y: r.midY - nameSize.height / 2, width: avail, height: nameSize.height)
		name.draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
	}
}

/// 글자를 세로 가운데에 그리는 셀 (표 칸은 행 높이 24 를 다 차지한다).
/// 주의: NSCell 은 복사될 때 Swift 저장 속성이 두 번 풀려 죽으므로 저장 속성을 두지 않는다
final class GridTextCell: NSTextFieldCell {
	private func centered(_ rect: NSRect) -> NSRect {
		// 한 줄 높이로 잰다: 칸 너비로 재면 넘치는 글자는 두 줄 높이로 나와 가운데로 못 옮기고 위에 붙었다 (… 도 안 붙음)
		let h = ceil(super.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height)
		guard h < rect.height else { return rect }
		var r = rect
		r.origin.y += floor((rect.height - h) / 2)
		r.size.height = h
		return r
	}

	override func drawingRect(forBounds rect: NSRect) -> NSRect {
		super.drawingRect(forBounds: centered(rect))
	}

	override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
		super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
	}

	override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
		super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
	}
}
