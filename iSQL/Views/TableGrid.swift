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
	/// 글자 대신 체크박스 (nil 이면 글자 칸). 누르면 setText(예/아니오)
	var check: Bool? = nil
}

enum GridMenuItem {
	case action(String, () -> Void)
	/// 흐린 항목 (아직 기능이 없거나 지금 못 하는 것)
	case disabled(String)
	case separator
	/// 하위 메뉴 (고른 값으로 거르기 ▸ …)
	case submenu(String, [GridMenuItem])
}

/// 테이블 하나의 오른쪽 클릭 메뉴 (사이드바 테이블·DB 개요에서 하나 골랐을 때 같은 순서).
/// 자주 쓰는 것 위, 되돌릴 수 없는 것 맨 아래
enum TableMenu {
	static func items(isView: Bool, name: String? = nil, open: @escaping () -> Void, export: @escaping () -> Void,
	                  importExcel: (() -> Void)? = nil,
	                  duplicate: (() -> Void)? = nil, rename: (() -> Void)? = nil,
	                  truncate: (() -> Void)? = nil, drop: (() -> Void)? = nil) -> [GridMenuItem] {
		let kind = isView ? "뷰" : "테이블"
		func item(_ title: String, _ run: (() -> Void)?) -> GridMenuItem { run.map { .action(title, $0) } ?? .disabled(title) }
		return [
			.action("열기", open),
		] + (name.map { n in [GridMenuItem.action("테이블 이름 복사") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(n, forType: .string)
		}] } ?? []) + [
			.separator,
			.action("\(kind) 내보내기…", export),
		] + (isView ? [] : [item("엑셀에서 가져오기…", importExcel)]) + [
			item("\(kind) 복제…", duplicate),
			item("\(kind) 이름 바꾸기…", rename),
			.separator,
		] + (isView ? [] : [item("테이블 비우기…", truncate)]) + [
			item("\(kind) 삭제…", drop),
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

	/// 칸마다 고칠 수 있는지 (canEdit 인 표에서)
	func isEditable(_ row: Int, _ col: Int) -> Bool
	/// 두 번 누르면 글자 입력 대신 고르기 메뉴를 띄울 칸의 항목 (nil = 구분선). 고르면 setText
	func choices(_ row: Int, _ col: Int) -> [String?]?
	/// 고르기 메뉴에서 체크할 항목
	func currentChoice(_ row: Int, _ col: Int) -> String?
	/// 제목을 눌러 정렬하는 표인지 (구조 편집은 줄 순서가 곧 컬럼 순서라 정렬하지 않는다)
	var sortable: Bool { get }
	/// 줄을 끌어 옮길 수 있는지
	var canMoveRows: Bool { get }
	func moveRows(_ rows: IndexSet, to: Int)
	/// 공급자가 표에게 맡긴 편집 시작 (새 줄의 이름 칸 등). 한 번 꺼내면 사라진다
	func takeEditRequest() -> (row: Int, col: Int)?
	/// 칸 안에서 고치지 않고 따로 편집 창(시트)을 여는 칸 (여러 줄 글자·JSON)
	func opensEditor(_ row: Int, _ col: Int) -> Bool
	func openEditor(_ row: Int, _ col: Int)
	/// Tab 으로 들르는 칸 (기본: 글자로 고치는 칸만)
	func tabStop(_ row: Int, _ col: Int) -> Bool
	/// "INSERT 문으로 복사" 에 쓰는 테이블 (nil 이면 그 메뉴 없음): SQL 이름, 컬럼 이름(공급자 컬럼 순서), 기본 키 컬럼
	var insertTarget: InsertTarget? { get }
	/// SQL 리터럴로 바꿀 칸 값 (바이너리는 X'..'). nil 이면 보이는 글자로
	func sqlValue(_ row: Int, _ col: Int) -> Value?
}

struct InsertTarget {
	var table: String
	var columns: [String]
	/// 기본 키 컬럼 ("PK 없이" 복사에서 뺀다)
	var primaryKey: Set<Int> = []
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
	func isEditable(_ row: Int, _ col: Int) -> Bool { true }
	func choices(_ row: Int, _ col: Int) -> [String?]? { nil }
	func currentChoice(_ row: Int, _ col: Int) -> String? { nil }
	var sortable: Bool { true }
	var canMoveRows: Bool { false }
	func moveRows(_ rows: IndexSet, to: Int) {}
	func takeEditRequest() -> (row: Int, col: Int)? { nil }
	func opensEditor(_ row: Int, _ col: Int) -> Bool { false }
	func openEditor(_ row: Int, _ col: Int) {}
	func tabStop(_ row: Int, _ col: Int) -> Bool { isEditable(row, col) && choices(row, col) == nil && !opensEditor(row, col) }
	var insertTarget: InsertTarget? { nil }
	func sqlValue(_ row: Int, _ col: Int) -> Value? { nil }
}

/// 컬럼을 끌어 순서를 바꾼 걸 알아 두고 되돌릴 수 있는 공급자 (데이터 탭)
protocol ColumnOrderTracking: AnyObject {
	var columnsMoved: Bool { get set }
	var restoreColumns: (() -> Void)? { get set }
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

		// MARK: 컬럼 고정 (왼쪽 n개)
		/// 고정 칸만 그리는 표: 스크롤 영역에 가로로만 떠 있다(세로로는 같이 움직인다). 본 표의 같은 컬럼 위를 덮는다
		private lazy var frozen: GridTableView = makeFrozenTable()
		private var frozenHeaderMenu: NSMenu?
		private var frozenMenu: NSMenu?
		/// 고정한 컬럼 수 (본 표의 보이는 순서로 왼쪽부터). 0 이면 고정 없음
		private(set) var frozenCount = 0
		/// 공급자마다 고정 수를 기억한다 (쿼리 결과처럼 표 하나를 돌려 쓰는 곳)
		private var frozenBySource: [String: Int] = [:]
		private var syncingSelection = false

		init(source: GridSource) {
			self.source = source
			super.init()
			table.coordinator = self
			table.style = .plain
			table.usesAlternatingRowBackgroundColors = true
			table.gridStyleMask = []
			table.allowsMultipleSelection = true
			table.allowsColumnReordering = true
			table.columnAutoresizingStyle = .noColumnAutoresizing
			table.rowHeight = 24
			table.intercellSpacing = NSSize(width: 0, height: 0)
			table.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
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
			syncRowDragging()
			bindOrderTracking()
			scroll.documentView = table
			scroll.hasVerticalScroller = true
			scroll.hasHorizontalScroller = true
			scroll.autohidesScrollers = true
			// 본 표 컬럼 너비·순서·표 크기가 바뀌면 고정 칸을 맞춘다
			let nc = NotificationCenter.default
			nc.addObserver(self, selector: #selector(mainColumnsChanged(_:)), name: NSTableView.columnDidResizeNotification, object: table)
			nc.addObserver(self, selector: #selector(mainColumnsChanged(_:)), name: NSTableView.columnDidMoveNotification, object: table)
			table.postsFrameChangedNotifications = true
			nc.addObserver(self, selector: #selector(mainColumnsChanged(_:)), name: NSView.frameDidChangeNotification, object: table)
			scroll.postsFrameChangedNotifications = true
			nc.addObserver(self, selector: #selector(mainColumnsChanged(_:)), name: NSView.frameDidChangeNotification, object: scroll)
			nc.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
			nc.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
		}

		deinit { NotificationCenter.default.removeObserver(self) }

		/// 표 하나를 다른 공급자가 쓰게 바꾼다 (구조 화면·쿼리 결과). 공급자마다 스크롤 위치를 기억한다
		func setSource(_ new: GridSource) {
			if ObjectIdentifier(new) != ObjectIdentifier(source) {
				frozenBySource[source.gridID] = frozenCount
				setFrozen(0)
				source.scrollOrigin = scroll.contentView.bounds.origin
				table.window?.makeFirstResponder(nil)
				table.deselectAll(nil)
				source = new
				cursorKey = nil
				bindOrderTracking()
				lastVersion = -1
				refresh()
				scroll.contentView.scroll(to: new.scrollOrigin)
				scroll.reflectScrolledClipView(scroll.contentView)
				setFrozen(frozenBySource[new.gridID] ?? 0)
			} else {
				refresh()
			}
		}

		/// 줄 끌기는 줄을 옮길 수 있는 표(구조 편집)에만 켠다.
		/// 모든 표에 .gap 을 켰더니 데이터 표에서 줄을 끌면 그 줄이 숨겨진 채 돌아오지 않았다 (사용자 보고)
		private var rowDragging: Bool?
		private func syncRowDragging() {
			let on = source.canMoveRows
			guard on != rowDragging else { return }
			rowDragging = on
			if on {
				table.registerForDraggedTypes([Self.rowDragType])
				table.draggingDestinationFeedbackStyle = .gap
				table.verticalMotionCanBeginDrag = true
			} else {
				table.unregisterDraggedTypes()
				table.draggingDestinationFeedbackStyle = .regular
				// 위아래로 끌면 줄 고르기만 (끌기를 시작하지 않는다)
				table.verticalMotionCanBeginDrag = false
			}
		}

		/// 컬럼·행이 바뀌었으면 다시 그린다
		func refresh() {
			syncRowDragging()
			syncColumns()
			if source.gridVersion != lastVersion {
				lastVersion = source.gridVersion
				// 고치는 중인 칸이 있으면 다시 읽지 않는다 (입력이 날아감)
				if table.currentEditor() == nil { table.reloadData() }
				if frozenCount > 0, frozen.currentEditor() == nil { frozen.reloadData() }
				applySortIndicator()
			}
			if let req = source.takeEditRequest(), req.row < table.numberOfRows {
				// 새 줄: 보이게 하고 고르고 편집 시작 (화면에 붙은 뒤에)
				DispatchQueue.main.async { [self] in
					table.scrollRowToVisible(req.row)
					table.selectRowIndexes([req.row], byExtendingSelection: false)
					if let ci = table.tableColumns.firstIndex(where: { colIndex($0) == req.col }) { beginEditing(row: req.row, column: ci) }
				}
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
			cursorKey = nil
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
				let cell = GridHeaderCell(textCell: Self.oneLine(col.title))
				cell.representedObject = col.comment
				cell.tag = col.isKey ? GridHeaderCell.keyBit : 0
				tc.headerCell = cell
				tc.headerToolTip = col.comment.isEmpty ? col.title : "\(col.title)\n\(col.comment)"
				// 제목을 누르면 정렬 (어떻게 할지는 공급자가 정한다)
				tc.sortDescriptorPrototype = source.sortable ? NSSortDescriptor(key: col.key, ascending: true) : nil
				tc.width = col.width ?? Self.initialWidth(col)
				tc.minWidth = 40
				table.addTableColumn(tc)
			}
			applySortIndicator()
			table.reloadData()
			refreshGridLines()
			noteColumnOrder()
			if frozenCount > 0 { setFrozen(min(frozenCount, columns.count)) }
		}

		private func refreshHeaders() {
			for tc in table.tableColumns {
				guard let i = Int(tc.identifier.rawValue), i < columns.count, let cell = tc.headerCell as? GridHeaderCell else { continue }
				cell.representedObject = columns[i].comment
				cell.tag = (cell.tag & ~GridHeaderCell.keyBit) | (columns[i].isKey ? GridHeaderCell.keyBit : 0)
			}
			table.headerView?.needsDisplay = true
			if frozenCount > 0 { rebuildFrozen() }
		}

		/// 제목 안 줄바꿈은 띄어쓰기로 (엑셀에서 가져온 컬럼 이름 등에 줄바꿈이 들어 있으면 제목이 두 줄로 그려졌다)
		static func oneLine(_ s: String) -> String {
			s.rangeOfCharacter(from: .newlines) == nil ? s : s.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
		}

		private static func initialWidth(_ col: GridColumn) -> CGFloat {
			let nameW = (oneLine(col.title) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
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

		// MARK: 컬럼 고정

		private func makeFrozenTable() -> GridTableView {
			let f = GridTableView()
			f.coordinator = self
			f.style = .plain
			f.usesAlternatingRowBackgroundColors = true
			f.gridStyleMask = []
			f.allowsMultipleSelection = true
			f.allowsColumnReordering = false
			f.columnAutoresizingStyle = .noColumnAutoresizing
			f.rowHeight = table.rowHeight
			f.intercellSpacing = table.intercellSpacing
			let fh = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: table.headerView?.frame.height ?? 28))
			fh.drawsBottomLine = true
			// 제 층(layer)이 없으면 스크롤 뷰 층에 그려져 스크롤 뷰의 다른 층(가장자리 흐림) 밑에 깔려 검게 보였다
			fh.wantsLayer = true
			f.headerView = fh
			let hm = makeMenu()
			frozenHeaderMenu = hm
			f.headerView?.menu = hm
			let m = makeMenu()
			frozenMenu = m
			f.menu = m
			f.target = self
			f.doubleAction = #selector(doubleClicked(_:))
			f.verticalMotionCanBeginDrag = false
			f.isFrozenPart = true
			// 스크롤 뷰 밖에 떠 있는 표라 AppKit 이 표 둘레에 포커스 테두리를 그렸다
			f.focusRingType = .none
			// 맥 14 부터 뷰는 기본으로 영역 밖에도 그린다 → 고정 표 배경·경계선이 본 표를 덮었다
			f.clipsToBounds = true
			f.headerView?.clipsToBounds = true
			NotificationCenter.default.addObserver(self, selector: #selector(frozenColumnResized(_:)), name: NSTableView.columnDidResizeNotification, object: f)
			return f
		}

		/// 왼쪽 n개 컬럼 고정 (0 = 풀기)
		func setFrozen(_ n: Int) {
			let n = max(0, min(n, table.numberOfColumns - 1 < 0 ? 0 : table.numberOfColumns))
			frozenCount = n
			applyResizing()
			if n == 0 {
				frozen.headerView?.removeFromSuperview()
				frozen.removeFromSuperview()
				frozenEdge.removeFromSuperview()
				frozenWidthWatch = []
				refreshEmphasis()
				return
			}
			if frozen.superview == nil {
				scroll.addFloatingSubview(frozen, for: .horizontal)
			}
			if let hv = frozen.headerView, hv.superview == nil { scroll.addSubview(hv) }
			// 경계선은 머리·표 위에 (머리와 행이 따로 그리면 머리에서 끊겨 보였다)
			if frozenEdge.superview == nil { scroll.addSubview(frozenEdge) }
			rebuildFrozen()
			refreshEmphasis()
		}

		/// 본 표의 왼쪽 n개 컬럼을 고정 표에 그대로 (같은 식별자라 칸 그리기·편집이 같은 길을 탄다)
		private func rebuildFrozen() {
			guard frozenCount > 0 else { return }
			let wanted = Array(table.tableColumns.prefix(frozenCount))
			let same = frozen.tableColumns.map(\.identifier) == wanted.map(\.identifier)
			if !same {
				frozen.dataSource = nil
				frozen.delegate = nil
				for c in frozen.tableColumns { frozen.removeTableColumn(c) }
				for src in wanted {
					let tc = NSTableColumn(identifier: src.identifier)
					if let h = src.headerCell as? GridHeaderCell {
						let cell = GridHeaderCell(textCell: h.stringValue)
						cell.representedObject = h.representedObject
						cell.tag = h.tag
						tc.headerCell = cell
					}
					tc.headerToolTip = src.headerToolTip
					tc.sortDescriptorPrototype = src.sortDescriptorPrototype
					tc.minWidth = src.minWidth
					tc.width = src.width
					frozen.addTableColumn(tc)
				}
				// 너비를 끄는 동안에도 바로 본 표를 맞춘다 (끝날 때만 맞추면 끄는 동안 고정 칸 뒤의 본 표 제목·칸이 비어져 나왔다)
				frozenWidthWatch = frozen.tableColumns.map { tc in
					tc.observe(\.width, options: [.new]) { [weak self] _, _ in
						MainActor.assumeIsolated { self?.syncFrozenWidths() }
					}
				}
				frozen.delegate = self
				frozen.dataSource = self
				frozen.sortDescriptors = table.sortDescriptors
				frozen.reloadData()
			} else {
				for (f, src) in zip(frozen.tableColumns, wanted) {
					if f.width != src.width { f.width = src.width }
					if let fh = f.headerCell as? GridHeaderCell, let sh = src.headerCell as? GridHeaderCell {
						fh.stringValue = sh.stringValue; fh.representedObject = sh.representedObject; fh.tag = sh.tag
					}
				}
			}
			syncingSelection = true
			frozen.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: false)
			syncingSelection = false
			layoutFrozen()
		}

		/// 고정 표 자리: 스크롤 영역 왼쪽 끝(가로 고정), 높이는 본 표와 같게. 머리는 본 표 머리 위 같은 자리
		private func layoutFrozen() {
			guard frozenCount > 0 else { return }
			let width = frozen.tableColumns.reduce(0) { $0 + $1.width }
			// 떠 있는 칸의 좌표는 스크롤 영역 안쪽(머리 아래 여백 포함) 기준이라 0 이 아니다
			// → 본 표의 맨 위와 스크롤 영역의 왼쪽 끝을 그 좌표로 바꿔 맞춘다
			var origin = NSPoint.zero
			if let container = frozen.superview {
				let top = table.convert(NSPoint(x: 0, y: 0), to: container)
				let left = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.minX, y: 0), to: container)
				origin = NSPoint(x: left.x, y: top.y)
			}
			// 표는 스스로 높이를 행 수만큼으로 줄이므로(clip 안이 아니라서) 최소 높이를 따로 준다 → 빈 줄 무늬까지 이어진다
			// 본 표는 보이는 영역만큼 늘어나 있으니 그 높이면 된다 (clip 높이를 쓰면 머리 높이만큼 하단바로 넘쳤다)
			frozen.minimumHeight = table.frame.height
			frozen.superview?.clipsToBounds = true
			frozen.frame = NSRect(x: origin.x, y: origin.y, width: width, height: frozen.minimumHeight)
			if let hv = frozen.headerView, let mainHeaderClip = table.headerView?.superview {
				let r = mainHeaderClip.convert(mainHeaderClip.bounds, to: scroll)
				hv.frame = NSRect(x: r.minX, y: r.minY, width: width, height: r.height)
				hv.needsDisplay = true
			}
			// 경계선: 머리 위부터 보이는 행 영역 아래까지, 고정 칸 오른쪽 끝에
			let clip = scroll.contentView.convert(scroll.contentView.bounds, to: scroll)
			let head = table.headerView?.superview.map { $0.convert($0.bounds, to: scroll) } ?? clip
			let right = frozen.convert(NSRect(x: 0, y: 0, width: width, height: 1), to: scroll).maxX
			frozenEdge.frame = NSRect(x: right - 1, y: min(head.minY, clip.minY), width: 1, height: max(head.maxY, clip.maxY) - min(head.minY, clip.minY))
		}

		/// 세로선(직접 그림) 다시 그리기 (한 번에 모아서)
		private var gridLinesPending = false
		private func refreshGridLines() {
			guard !gridLinesPending else { return }
			gridLinesPending = true
			DispatchQueue.main.async { [self] in
				gridLinesPending = false
				for t in frozenCount > 0 ? [table, frozen] : [table] {
					t.needsDisplay = true
					t.headerView?.needsDisplay = true
				}
			}
		}

		/// 고정 칸 오른쪽 경계선 (어디까지 고정인지). 마우스는 밑으로 그대로 보낸다
		private lazy var frozenEdge = GridEdgeLine()

		/// 고정한 컬럼은 본 표 머리에서 너비를 못 바꾸게: 본 표의 그 경계는 고정 칸 밑에 가려져 있어서
		/// 끌면(<|> 커서) 고정 칸 뒤에서 움직여 어색했다. 너비는 고정 칸 머리(<| 커서)에서만 바꾼다
		private func applyResizing() {
			for (i, tc) in table.tableColumns.enumerated() {
				let mask: NSTableColumn.ResizingOptions = i < frozenCount ? [] : [.autoresizingMask, .userResizingMask]
				if tc.resizingMask != mask { tc.resizingMask = mask }
			}
			if let hv = table.headerView { hv.window?.invalidateCursorRects(for: hv) }
		}

		// MARK: 선택색 (두 표를 한 표처럼)

		/// 두 표 중 하나가 키 입력을 받고 있으면 둘 다 파란 선택색. AppKit 은 표마다 따로 정해서 고정 칸만 회색(비활성)으로 보였다
		var groupFocused: Bool {
			guard let w = table.window, w.isKeyWindow, let fr = w.firstResponder else { return false }
			if fr === table || fr === frozen { return true }
			if let v = fr as? NSView, v.isDescendant(of: table) || (frozenCount > 0 && v.isDescendant(of: frozen)) { return true }
			return false
		}

		/// 고정이 있을 때만 선택색을 함께 정한다 (nil = AppKit 에 맡김)
		var emphasisOverride: Bool? { frozenCount > 0 ? groupFocused : nil }

		func refreshEmphasis() {
			DispatchQueue.main.async { [self] in
				for t in frozenCount > 0 ? [table, frozen] : [table] {
					t.enumerateAvailableRowViews { rv, _ in
						rv.isEmphasized = emphasisOverride ?? (self.groupFocused && t === self.table)
					}
				}
			}
		}

		@objc private func windowKeyChanged(_ n: Notification) {
			guard frozenCount > 0, (n.object as? NSWindow) === table.window else { return }
			refreshEmphasis()
		}

		func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
			let id = NSUserInterfaceItemIdentifier("row")
			let rv = tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView ?? GridRowView()
			rv.identifier = id
			rv.controller = self
			return rv
		}

		/// 고정 칸 경계를 넘는 컬럼 끌기는 막는다 (고정 칸 안으로 끌어 넣으면 두 표의 컬럼이 꼬였다)
		func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
			guard tableView === table, frozenCount > 0 else { return true }
			if columnIndex < frozenCount { return false }
			return newColumnIndex < 0 || newColumnIndex >= frozenCount
		}

		// MARK: 지금 칸 (엑셀처럼: 좌우 방향키로 옮기고 엔터로 그 칸 고치기)

		/// 지금 칸의 컬럼 (NSTableColumn 식별자 = 공급자 컬럼 번호). 고른 행의 이 칸에 테두리
		private(set) var cursorKey: String?

		func setCursor(_ key: String?) {
			guard key != cursorKey else { return }
			cursorKey = key
			redrawCursor()
		}

		/// 보이는 순서(본 표)에서 지금 칸 자리
		private var cursorIndex: Int? { table.tableColumns.firstIndex { $0.identifier.rawValue == cursorKey } }

		/// 지금 칸이 없을 때: 보이는 맨 왼쪽 컬럼
		private var leftmostVisible: Int {
			if frozenCount > 0 { return 0 }
			let b = scroll.contentView.bounds
			return max(0, table.column(at: NSPoint(x: b.minX + 1, y: b.minY + 1)))
		}

		func moveCursor(_ step: Int) {
			let n = table.numberOfColumns
			guard n > 0, table.selectedRow >= 0 else { NSSound.beep(); return }
			let i = cursorIndex.map { min(max($0 + step, 0), n - 1) } ?? leftmostVisible
			setCursor(table.tableColumns[i].identifier.rawValue)
			revealColumn(i)
		}

		/// 그 컬럼이 보이게 옆으로 (고정 칸 밑에 가려지지 않게)
		private func revealColumn(_ i: Int) {
			guard i >= frozenCount, i < table.numberOfColumns else { return }
			let r = table.rect(ofColumn: i), clip = scroll.contentView.bounds
			let cover = frozenCount > 0 ? frozen.frame.width : 0
			var x = clip.minX
			if r.minX < clip.minX + cover { x = r.minX - cover }
			else if r.maxX > clip.maxX { x = min(r.minX - cover, r.maxX - clip.width) }
			if x != clip.minX { table.scroll(NSPoint(x: max(0, x), y: clip.minY)) }
		}

		/// 엔터: 지금 칸(없으면 보이는 맨 왼쪽)을 고친다
		func editAtCursor() {
			guard table.selectedRow >= 0, canEdit else { return }
			let i = cursorIndex ?? leftmostVisible
			revealColumn(i)
			beginEditing(row: table.selectedRow, column: i, in: table)
		}

		/// 이 칸이 지금 칸인지 (고른 행 · 지금 컬럼)
		func isCursor(_ view: NSView, in tv: NSTableView) -> Bool {
			guard let key = cursorKey, tv.selectedRow >= 0 else { return false }
			let c = tv.column(for: view)
			return c >= 0 && tv.row(for: view) == tv.selectedRow && tv.tableColumns[c].identifier.rawValue == key
		}

		private func redrawCursor() {
			for t in frozenCount > 0 ? [table, frozen] : [table] {
				t.enumerateAvailableRowViews { rv, _ in if rv.isSelected { rv.subviews.forEach { $0.needsDisplay = true } } }
			}
		}

		// MARK: 컬럼 순서

		private func bindOrderTracking() {
			(source as? ColumnOrderTracking)?.restoreColumns = { [weak self] in self?.restoreColumnOrder() }
		}

		/// 처음 순서와 다른지 (식별자가 공급자 컬럼 번호)
		private var columnsOutOfOrder: Bool {
			table.tableColumns.enumerated().contains { $0.element.identifier.rawValue != String($0.offset) }
		}

		private func noteColumnOrder() {
			guard let t = source as? ColumnOrderTracking else { return }
			let moved = columnsOutOfOrder
			if t.columnsMoved != moved { t.columnsMoved = moved }
		}

		/// 컬럼을 처음 순서로 (고정은 잠깐 풀었다가 같은 수로 다시)
		func restoreColumnOrder() {
			let f = frozenCount
			if f > 0 { setFrozen(0) }
			for i in 0..<table.numberOfColumns {
				if let cur = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(i) }), cur != i {
					table.moveColumn(cur, toColumn: i)
				}
			}
			if f > 0 { setFrozen(f) }
			noteColumnOrder()
		}

		@objc private func mainColumnsChanged(_ n: Notification) {
			if n.name == NSTableView.columnDidMoveNotification { noteColumnOrder() }
			// 너비·순서가 바뀌면 표 전체를 다시 그린다: 바뀐 곳만 다시 그려서 예전 자리 세로선이 남았다
			if n.name != NSView.frameDidChangeNotification { refreshGridLines() }
			guard frozenCount > 0 else { return }
			rebuildFrozen()
		}

		/// 고정 표에서 너비를 끌면 본 표의 같은 컬럼도 (밑에 깔린 칸과 어긋나지 않게)
		@objc private func frozenColumnResized(_ n: Notification) { syncFrozenWidths() }

		private var frozenWidthWatch: [NSKeyValueObservation] = []

		private func syncFrozenWidths() {
			guard frozenCount > 0 else { return }
			for f in frozen.tableColumns {
				if let m = table.tableColumns.first(where: { $0.identifier == f.identifier }), m.width != f.width { m.width = f.width }
			}
			layoutFrozen()
			refreshGridLines()
		}

		// MARK: 정렬

		private var settingSort = false

		/// 공급자의 정렬 상태를 제목에 보여 준다 (꺾쇠 + 코멘트 자리 비우기)
		func applySortIndicator() {
			settingSort = true
			defer { settingSort = false }
			let sort = source.currentSort
			table.sortDescriptors = sort.map { [NSSortDescriptor(key: $0.key, ascending: $0.ascending)] } ?? []
			if frozenCount > 0 { frozen.sortDescriptors = table.sortDescriptors }
			for tc in table.tableColumns + (frozenCount > 0 ? frozen.tableColumns : []) {
				let on = sort != nil && tc.sortDescriptorPrototype?.key == sort?.key
				if let cell = tc.headerCell as? GridHeaderCell {
					var t = cell.tag & GridHeaderCell.keyBit
					if on { t |= GridHeaderCell.sortBit; if sort?.ascending == false { t |= GridHeaderCell.descBit } }
					cell.tag = t
				}
			}
			table.headerView?.needsDisplay = true
			if frozenCount > 0 { frozen.headerView?.needsDisplay = true }
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
			let cellInfo = source.cell(row, col)
			if let on = cellInfo.check {
				let cid = NSUserInterfaceItemIdentifier("check")
				let v: GridCheckView
				if let reused = tableView.makeView(withIdentifier: cid, owner: nil) as? GridCheckView {
					v = reused
				} else {
					v = GridCheckView()
					v.identifier = cid
					v.button.target = self
					v.button.action = #selector(checkToggled(_:))
				}
				v.button.state = on ? .on : .off
				v.button.isEnabled = source.canEdit && cellInfo.state != .deleted && source.isEditable(row, col)
				v.fill = Self.fill(cellInfo.state)
				v.toolTip = cellInfo.tooltip
				return v
			}
			let id = NSUserInterfaceItemIdentifier("cell")
			let field: GridField
			if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? GridField {
				field = reused
			} else {
				field = GridField()
				// 행 높이만큼 늘어난 글자 칸은 글자를 위에 붙여 그린다 → 세로 가운데로 그리는 셀
				field.cell = GridTextCell(textCell: "")
				field.identifier = id
				field.isBordered = false
				// 고칠 때 파란 포커스 링은 그리지 않는다 (지금 칸 흰 테두리가 이미 있다)
				field.focusRingType = .none
				// 배경은 GridField 가 칸 전체에 칠한다 (글자 칸이 칠하면 글자 높이만큼 한 번 더 겹쳤다)
				field.drawsBackground = false
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
			if cell.state == .deleted {
				attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
				attrs[.foregroundColor] = NSColor.systemRed
			}
			field.fill = Self.fill(cell.state)
			let s = NSMutableAttributedString()
			if let icon = cell.icon {
				let a = NSTextAttachment()
				a.image = icon
				// 글자(대문자 높이) 가운데에 맞춘다. 고정 -1 이면 아이콘이 글자보다 위로 떴다
				a.bounds = NSRect(x: 0, y: round((f.capHeight - icon.size.height) / 2), width: icon.size.width, height: icon.size.height)
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

		/// 칸 상태 배경: 고친 칸 노랑, 새 행 초록, 지울 행 빨강
		static func fill(_ state: GridCellState) -> NSColor? {
			switch state {
			case .deleted: NSColor.systemRed.withAlphaComponent(0.12)
			case .edited: NSColor.systemYellow.withAlphaComponent(0.35)
			case .inserted: NSColor.systemGreen.withAlphaComponent(0.18)
			case .clean: nil
			}
		}

		/// 체크박스 칸을 누름: 바로 예/아니오
		@objc func checkToggled(_ sender: NSButton) {
			let tv = owner(of: sender)
			let row = tv.row(for: sender), ci = tv.column(for: sender)
			guard row >= 0, ci >= 0, let col = colIndex(tv.tableColumns[ci]) else { return }
			source.setText(row, col, sender.state == .on ? "예" : "아니오")
			reloadRow(row)
		}

		/// 칸이 들어 있는 표 (본 표 / 고정 표)
		private func owner(of view: NSView) -> NSTableView {
			var v: NSView? = view
			while let x = v { if let t = x as? NSTableView { return t }; v = x.superview }
			return table
		}

		/// 한 줄 다시 그리기 (두 표 모두)
		private func reloadRow(_ row: Int) {
			table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
			if frozenCount > 0 { frozen.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<frozen.numberOfColumns)) }
		}

		func tableViewSelectionDidChange(_ notification: Notification) {
			// 여러 행을 고르면 지금 칸은 없앤다 (테두리가 어색했다, 사용자) → ⌘C 는 행 전체
			if table.selectedRowIndexes.count > 1 { setCursor(nil) }
			// 지금 칸 테두리는 고른 행에만: 이미 골라져 있던 행은 다시 그려지지 않아 테두리가 남았다
			else if cursorKey != nil { redrawCursor() }
			// 두 표의 선택을 맞춘다
			if frozenCount > 0, !syncingSelection, let from = notification.object as? NSTableView {
				syncingSelection = true
				let other: NSTableView = from === frozen ? table : frozen
				if other.selectedRowIndexes != from.selectedRowIndexes { other.selectRowIndexes(from.selectedRowIndexes, byExtendingSelection: false) }
				syncingSelection = false
			}
			guard let cb = onSelection else { return }
			let sel = table.selectedRowIndexes
			DispatchQueue.main.async { cb(sel) }
		}

		// MARK: 고치기

		@objc func doubleClicked(_ sender: NSTableView) {
			if source.canEdit { beginEditing(row: sender.clickedRow, column: sender.clickedColumn, in: sender) }
			else if sender.clickedRow >= 0 { source.activateRow(sender.clickedRow) }
		}

		/// 그 칸만 편집 가능하게 바꾸고 편집을 시작한다
		/// step: Tab(1)·Shift+Tab(-1) 으로 들어왔으면 그 방향. 고르기 메뉴에서 고르면 그 방향 다음 칸으로 이어 간다
		func beginEditing(row: Int, column: Int, step: Int = 0, in tv: NSTableView? = nil) {
			var table = tv ?? self.table
			if frozenCount > 0, table === self.table {
				// 고정한 컬럼은 고정 칸에서 고친다 (본 표의 그 칸은 고정 칸 밑에 가려져 있다)
				if column < frozenCount { table = frozen }
				else {
					// 고정 칸 밑에 가려진 칸이면 보이게 옆으로
					let r = self.table.rect(ofColumn: column)
					let left = scroll.contentView.bounds.minX + frozen.frame.width
					if r.minX < left { self.table.scroll(NSPoint(x: max(0, r.minX - frozen.frame.width), y: scroll.contentView.bounds.minY)) }
				}
			}
			guard source.canEdit, row >= 0, row < table.numberOfRows, column >= 0, column < table.numberOfColumns else { return }
			setCursor(table.tableColumns[column].identifier.rawValue)
			guard let col = colIndex(table.tableColumns[column]), source.cell(row, col).state != .deleted,
			      source.isEditable(row, col) else { NSSound.beep(); return }
			// 체크박스 칸은 누르면 바로 바뀐다 (글자 편집 없음)
			if source.cell(row, col).check != nil { return }
			if source.opensEditor(row, col) {
				source.openEditor(row, col)
				return
			}
			if let items = source.choices(row, col) {
				let picked = showChoices(items, row: row, column: column, col: col, in: table)
				if picked, step != 0, let next = nextTextColumn(row: row, from: column, step: step, in: table) {
					DispatchQueue.main.async { self.beginEditing(row: row, column: next, step: step, in: table) }
				}
				return
			}
			if let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField {
				field.isEditable = true
				field.isSelectable = true
				// 고칠 때는 글자만: 앞의 키 아이콘(첨부 글자)과 띄어쓰기가 입력에 섞여 이름 앞에 붙었다
				let cell = source.cell(row, col)
				if cell.icon != nil {
					field.attributedStringValue = NSAttributedString(string: cell.text?.replacingOccurrences(of: "\n", with: "⏎") ?? "",
					                                                 attributes: [.font: font(columns[col])])
				}
			}
			table.editColumn(column, row: row, with: nil, select: true)
		}

		func controlTextDidEndEditing(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			field.isEditable = false
			field.isSelectable = false
			let table = owner(of: field)
			let row = table.row(for: field), ci = table.column(for: field)
			guard row >= 0, ci >= 0, let col = colIndex(table.tableColumns[ci]) else { return }
			// Tab / Shift+Tab: 옆 칸 편집으로 (옆 칸이 평소 편집 불가라 AppKit 이 알아서 넘어가지 않는다)
			let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap { NSTextMovement(rawValue: $0) }
			defer {
				if movement == .tab, let next = nextTextColumn(row: row, from: ci, step: 1, in: table) { DispatchQueue.main.async { self.beginEditing(row: row, column: next, step: 1, in: table) } }
				// 고정 칸 끝에서 Tab: 본 표의 고정 다음 칸으로
				else if movement == .tab, table === frozen, let next = nextTextColumn(row: row, from: frozenCount - 1, step: 1, in: self.table) {
					DispatchQueue.main.async { self.beginEditing(row: row, column: next, step: 1, in: self.table) }
				}
				if movement == .backtab, let next = nextTextColumn(row: row, from: ci, step: -1, in: table) { DispatchQueue.main.async { self.beginEditing(row: row, column: next, step: -1, in: table) } }
			}
			let old = source.cell(row, col).text
			// 혹시 남은 첨부 글자(아이콘)는 뺀다
			let typed = field.stringValue.replacingOccurrences(of: "\u{FFFC}", with: "")
			// NULL 칸을 비운 채로 끝내면 그대로 NULL
			if old == nil && typed.isEmpty { return }
			if typed == (old?.replacingOccurrences(of: "\n", with: "⏎") ?? "") { return }
			source.setText(row, col, typed.replacingOccurrences(of: "⏎", with: "\n"))
			reloadRow(row)
		}

		/// Tab 으로 옮겨 갈 옆 칸 (공급자가 정한 Tab 칸만: 못 고치는 칸·예/아니오 칸·시트로 고치는 칸은 건너뛴다)
		private func nextTextColumn(row: Int, from: Int, step: Int, in tv: NSTableView? = nil) -> Int? {
			let table = tv ?? self.table
			var c = from + step
			while c >= 0 && c < table.numberOfColumns {
				if let col = colIndex(table.tableColumns[c]), source.tabStop(row, col) { return c }
				c += step
			}
			return nil
		}

		/// 고르기 칸: 칸 바로 아래에 메뉴
		/// 고르기 메뉴. 무언가 골랐으면 true (Esc 로 닫으면 false)
		@discardableResult
		private func showChoices(_ items: [String?], row: Int, column: Int, col: Int, in table: NSTableView) -> Bool {
			let menu = NSMenu()
			let current = source.currentChoice(row, col)
			for it in items {
				guard let it else { menu.addItem(.separator()); continue }
				let mi = NSMenuItem(title: it, action: #selector(choicePicked(_:)), keyEquivalent: "")
				mi.target = self
				mi.representedObject = ChoiceTarget(row: row, col: col, value: it)
				mi.state = it == current ? .on : .off
				menu.addItem(mi)
			}
			let rect = table.frameOfCell(atColumn: column, row: row)
			let selected = menu.items.first { $0.state == .on }
			// 지금 값이 칸 위에 겹치게 (팝업 버튼처럼)
			return menu.popUp(positioning: selected, at: NSPoint(x: rect.minX, y: selected == nil ? rect.maxY : rect.minY), in: table)
		}

		private final class ChoiceTarget {
			let row: Int, col: Int, value: String
			init(row: Int, col: Int, value: String) { self.row = row; self.col = col; self.value = value }
		}

		@objc private func choicePicked(_ sender: NSMenuItem) {
			guard let t = sender.representedObject as? ChoiceTarget, t.row < source.rowCount else { return }
			source.setText(t.row, t.col, t.value)
			reloadRow(t.row)
		}

		// MARK: 줄 끌어 옮기기 (구조 편집: 컬럼 순서)

		static let rowDragType = NSPasteboard.PasteboardType("net.moimz.isql.grid-row")

		func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
			guard source.canMoveRows, table.currentEditor() == nil else { return nil }
			let item = NSPasteboardItem()
			item.setString(String(row), forType: Self.rowDragType)
			return item
		}

		/// 끌기 시작할 때 고스트를 그 줄 자리에 둔다. 그림은 AppKit 이 만든 것을 그대로 쓰고 자리만 옮긴다.
		/// AppKit 이 정한 자리는 커서보다 한 줄 높이만큼 위였다 (사용자 보고).
		/// 그림을 직접 만들면(cacheDisplay) 칸 글자가 빠져 투명해 보여서 그림은 건드리지 않는다
		func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
			session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
				guard let s = (item.item as? NSPasteboardItem)?.string(forType: Self.rowDragType), let row = Int(s), row < tableView.numberOfRows else { return }
				var frame = item.draggingFrame
				frame.origin.y = tableView.rect(ofRow: row).minY
				item.draggingFrame = frame
			}
		}

		func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
			guard source.canMoveRows, (info.draggingSource as? NSTableView) === tableView else { return [] }
			if op == .on { tableView.setDropRow(row, dropOperation: .above) }
			return .move
		}

		func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
			guard source.canMoveRows else { return false }
			var rows = IndexSet()
			info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
				if let s = (item.item as? NSPasteboardItem)?.string(forType: Self.rowDragType), let r = Int(s) { rows.insert(r) }
			}
			guard !rows.isEmpty else { return false }
			source.moveRows(rows, to: row)
			// 옮긴 줄을 고른 채로
			let at = row - rows.filter { $0 < row }.count
			table.selectRowIndexes(IndexSet(integersIn: at..<(at + rows.count)), byExtendingSelection: false)
			return true
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
			let table: NSTableView = (menu === frozenMenu || menu === frozenHeaderMenu) ? frozen : self.table
			if menu === headerMenu || menu === frozenHeaderMenu {
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
				let sortItems: [GridMenuItem] = !source.sortable ? [] : [
					.action("오름차순 정렬") { self.sort(key, ascending: true) },
					.action("내림차순 정렬") { self.sort(key, ascending: false) },
				] + (source.currentSort != nil ? [.action("정렬 없애기") { self.sort(nil, ascending: true) }] : [])
				if !items.isEmpty { items.append(.separator) }
				// 컬럼 고정: 본 표 보이는 순서로 이 컬럼까지
				let display = self.table.tableColumns.firstIndex { colIndex($0) == col } ?? 0
				var freezeItems: [GridMenuItem] = [.separator]
				if frozenCount != display + 1 { freezeItems.append(.action("‘\(columns[col].title)’ 까지 고정") { self.setFrozen(display + 1) }) }
				if frozenCount > 0 { freezeItems.append(.action("컬럼 고정 풀기") { self.setFrozen(0) }) }
				let name = columns[col].key
				let copyItems: [GridMenuItem] = [.action("컬럼 이름 복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(name, forType: .string)
				}, .separator]
				fill(menu, copyItems + items + sortItems + freezeItems)
				return
			}
			guard table.clickedRow >= 0 else { return }
			let row = table.clickedRow
			if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
			let col = table.clickedColumn >= 0 ? colIndex(table.tableColumns[table.clickedColumn]) : nil
			var items: [GridMenuItem] = []
			let sel = table.selectedRowIndexes
			if let col {
				items.append(.action("값 복사") { self.writeClipboard(rows: [[self.source.cell(row, col).text]], columns: [col]) })
			}
			items.append(.action("행 복사 (\(sel.count)개)") { self.copySelection() })
			items.append(.action("컬럼 이름 포함 복사") { self.copySelection(withNames: true) })
			if let t = source.insertTarget {
				items.append(.action("INSERT 문으로 복사") { self.copyInsert(t, skipAuto: false) })
				if !t.primaryKey.isEmpty {
					items.append(.action("INSERT 문으로 복사 (PK 없이)") { self.copyInsert(t, skipAuto: true) })
				}
			}
			if let col {
				let name = columns[col].key
				items.append(.separator)
				items.append(.action("‘\(name)’ 값 복사") { self.writeClipboard(rows: sel.map { [self.source.cell($0, col).text] }, columns: [col]) })
				items.append(.action("‘\(name)’ 값을 SQL 로 복사 (IN 목록)") {
					// IN 목록: NULL 은 빼고(IN 으로는 안 맞는다) 같은 값은 한 번만
					var seen = Set<String>()
					let list = sel.map { self.sqlLiteral($0, col) }.filter { $0 != "NULL" && seen.insert($0).inserted }.joined(separator: ", ")
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(list, forType: .string)
				})
			}
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
				case .submenu(let title, let sub):
					let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
					let m = NSMenu(title: title)
					fill(m, sub)
					i.submenu = m
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
		/// 고른 행 복사. withNames 면 첫 줄에 컬럼 이름 (엑셀 표에도)
		func copySelection(withNames: Bool = false) {
			let cols = Array(columns.indices)
			let rows = table.selectedRowIndexes.map { r in cols.map { source.cell(r, $0).text } }
			writeClipboard(rows: rows, columns: cols, header: withNames ? cols.map { columns[$0].key } : nil)
		}

		/// SQL 리터럴: 숫자 컬럼의 숫자는 따옴표 없이, 나머지는 '…' (바이너리는 X'..')
		func sqlLiteral(_ row: Int, _ col: Int) -> String {
			let v = source.sqlValue(row, col) ?? (source.cell(row, col).text.map(Value.text) ?? .null)
			if case .text(let t) = v, columns[col].numeric, Double(t) != nil, !t.isEmpty { return t }
			return literal(v)
		}

		/// 고른 행을 INSERT 문 하나로 (VALUES 를 줄마다). skipKey 면 기본 키 컬럼은 빼서 새 키로 들어가게
		func copyInsert(_ t: InsertTarget, skipAuto skipKey: Bool) {
			let cols = t.columns.indices.filter { !(skipKey && t.primaryKey.contains($0)) && $0 < columns.count }
			guard !cols.isEmpty, !table.selectedRowIndexes.isEmpty else { return }
			let values = table.selectedRowIndexes.map { r in "(" + cols.map { sqlLiteral(r, $0) }.joined(separator: ", ") + ")" }
			let sql = "INSERT INTO \(t.table) (" + cols.map { quoteName(t.columns[$0]) }.joined(separator: ", ") + ") VALUES\n"
				+ values.joined(separator: ",\n") + ";"
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(sql, forType: .string)
		}

		/// ⌘C: 지금 칸이 있으면 그 컬럼 값만 (여러 행이면 줄마다 하나), 없으면 행 전체
		func copyShortcut() {
			guard let key = cursorKey, let col = Int(key), col < columns.count else { copySelection(); return }
			writeClipboard(rows: table.selectedRowIndexes.map { [source.cell($0, col).text] }, columns: [col])
		}

		/// 클립보드에 두 가지로: 글자(탭·줄 구분, 메모장용 — 예전 그대로)와 HTML 표(엑셀·Numbers 는 이걸 먼저 쓴다).
		/// 글자만 주면 칸 안 줄바꿈이 엑셀에서 행을 쪼갰다. HTML 표는 줄바꿈을 같은 칸 안 줄로,
		/// 숫자 컬럼이 아니거나 15자리를 넘는 숫자는 글자 서식으로 (01234 → 1234, 큰 번호 → 1.8E+19 가 되지 않게; 엑셀로 확인)
		private func writeClipboard(rows: [[String?]], columns cols: [Int], header: [String]? = nil) {
			guard !rows.isEmpty else { return }
			let plain = ((header.map { [$0.joined(separator: "\t")] } ?? []) + rows.map { $0.map { $0 ?? "NULL" }.joined(separator: "\t") }).joined(separator: "\n")
			func esc(_ t: String) -> String {
				t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
					.replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
					.replacingOccurrences(of: "\r\n", with: "\n")
					.replacingOccurrences(of: "\n", with: "<br style=\"mso-data-placement:same-cell\">")
			}
			var html = "<html><head><meta charset=\"utf-8\"></head><body><table>"
			if let header { html += "<tr>" + header.map { "<td style=\"mso-number-format:'\\@'\"><b>\(esc($0))</b></td>" }.joined() + "</tr>" }
			for r in rows {
				html += "<tr>"
				for (i, v) in r.enumerated() {
					let text = v ?? "NULL"
					let numeric = i < cols.count && cols[i] < columns.count && columns[cols[i]].numeric && v != nil
						&& text.filter(\.isNumber).count <= 15
					html += numeric ? "<td>\(esc(text))</td>" : "<td style=\"mso-number-format:'\\@'\">\(esc(text))</td>"
				}
				html += "</tr>"
			}
			html += "</table></body></html>"
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(plain, forType: .string)
			pb.setString(html, forType: .html)
		}
}

/// ⌫ 로 행 삭제, ⌘C 로 지금 칸 값 복사(지금 칸이 없으면 행, 탭 구분), 엔터로 지금 칸 고치기
final class GridTableView: NSTableView {
	weak var coordinator: GridController?
	/// 컬럼 고정용 표
	var isFrozenPart = false
	/// 고정 표의 최소 높이 (본 표만큼)
	var minimumHeight: CGFloat = 0

	override func setFrameSize(_ newSize: NSSize) {
		var s = newSize
		if isFrozenPart { s.height = max(s.height, minimumHeight) }
		super.setFrameSize(s)
	}

	/// 줄을 끌 수 있는 표는 AppKit 이 고르기를 떼는 순간으로 미룬다 → 누르자마자 끌면 안 고른 색으로 끌렸다.
	/// 고르지 않은 줄을 그냥(⌘·⇧ 없이) 누르면 바로 고른다
	override func mouseDown(with event: NSEvent) {
		let p = convert(event.locationInWindow, from: nil)
		let r = row(at: p)
		// 누른 칸이 지금 칸
		let c = column(at: p)
		if r >= 0, c >= 0 { coordinator?.setCursor(tableColumns[c].identifier.rawValue) }
		if verticalMotionCanBeginDrag, r >= 0, !selectedRowIndexes.contains(r),
		   event.modifierFlags.intersection([.command, .shift, .control]).isEmpty {
			selectRowIndexes([r], byExtendingSelection: false)
		}
		super.mouseDown(with: event)
	}

	/// 줄무늬·세로선을 직접 그린다 (행이 없는 아래쪽도 같은 줄무늬로 이어서).
	/// 불투명하게: 고정 표 밑에 깔린 본 표가 비치지 않게 (다크 모드 둘째 줄무늬 색은 반투명이다)
	override func drawBackground(inClipRect clipRect: NSRect) {
		let colors = NSColor.alternatingContentBackgroundColors
		let r = clipRect.intersection(bounds)
		colors[0].setFill()
		r.fill()
		let h = rowHeight + intercellSpacing.height
		if h > 0, colors.count > 1 {
			colors[1].setFill()
			var i = Int(floor(r.minY / h))
			while CGFloat(i) * h < r.maxY {
				if i % 2 == 1 { NSRect(x: r.minX, y: CGFloat(i) * h, width: r.width, height: h).fill(using: .sourceOver) }
				i += 1
			}
		}
		drawColumnLines(in: clipRect)
	}

	/// 세로선은 직접 그린다 (마지막 컬럼 오른쪽까지). 맥 26 의 세로선(gridStyleMask)은 따로 된 뷰라
	/// 컬럼을 옮기거나 너비를 바꾸면 예전 자리에 남아 칸과 어긋났다
	/// 세로선 색: 표·칸이 같은 값으로. gridColor 는 칸 안에서 그리면 배경보다 어둡게(34 대 40) 나와 데이터 줄 선이 안 보였다
	static let lineColor = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.12)
	}

	func drawColumnLines(in clipRect: NSRect) {
		Self.lineColor.setFill()
		var x: CGFloat = 0
		for c in tableColumns {
			x += c.width + intercellSpacing.width
			let line = NSRect(x: x - 1, y: clipRect.minY, width: 1, height: clipRect.height)
			if line.minX > clipRect.maxX { break }
			if line.intersects(clipRect) { line.fill(using: .sourceOver) }
		}
	}

	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 53:        // esc: 지금 칸을 없애고 행만 고른 상태로 (⌘C 가 행 전체를 복사)
			if coordinator?.cursorKey != nil { coordinator?.setCursor(nil) } else { super.keyDown(with: event) }
		case 51, 117:   // delete, forward delete
			coordinator?.deleteSelection()
		case 36, 76:    // return, enter: 지금 칸을 고친다 (없으면 보이는 맨 왼쪽)
			coordinator?.editAtCursor()
		case 123 where event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty:   // ←
			coordinator?.moveCursor(-1)
		case 124 where event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty:   // →
			coordinator?.moveCursor(1)
		default:
			super.keyDown(with: event)
		}
	}

	@objc func copy(_ sender: Any?) { coordinator?.copyShortcut() }

	/// 끄는 컬럼 묶음 (머리를 다시 그릴 때마다 테두리 자리를 맞춘다)
	weak var ghost: NSView?

	/// 컬럼을 끄는 동안 AppKit 이 끄는 컬럼의 칸들을 따로 묶어 불투명도 60% 로 띄운다(뒤가 비쳐 어수선했다) → 불투명하게
	override func didAddSubview(_ subview: NSView) {
		super.didAddSubview(subview)
		guard !(subview is NSTableRowView), !(subview is GridGhostEdge) else { return }
		ghost = subview
		solidifyGhost()
		// AppKit 이 붙인 뒤에 불투명도·크기를 정할 수 있어 한 번 더 (끄는 동안은 이벤트 추적 모드)
		RunLoop.main.perform(inModes: [.eventTracking, .default]) { MainActor.assumeIsolated { self.solidifyGhost() } }
	}

	/// 끄는 컬럼 묶음: 불투명·그림자, 양옆 테두리는 위아래 끝까지 (AppKit 의 테두리 선과 칸의 선은 데이터 줄에만 있어 빈 줄에서 끊겼다)
	func solidifyGhost() {
		// 컬럼 칸이 든 묶음만: 오른쪽 클릭하면 AppKit 이 테두리 표시용 뷰를 붙이는데 그것까지 칠해 표 전체를 덮었다
		guard let g = ghost, g.superview === self,
		      g.subviews.contains(where: { $0 is GridField || $0 is GridCheckView }) else { return }
		g.alphaValue = 1
		g.layer?.opacity = 1
		g.layer?.backgroundColor = NSColor.alternatingContentBackgroundColors[0].cgColor
		g.layer?.shadowOpacity = 0.35
		g.layer?.shadowRadius = 6
		g.layer?.shadowOffset = .zero
		for v in g.subviews where !(v is GridField) && !(v is GridCheckView) && !(v is GridGhostEdge) { v.isHidden = true }
		if !g.subviews.contains(where: { $0 is GridGhostEdge }) {
			g.addSubview(GridGhostEdge(frame: .zero))
			g.addSubview(GridGhostEdge(frame: .zero))
		}
		// 붙는 순간엔 크기가 0 일 수 있어 부를 때마다 자리를 다시 잡는다
		let edges = g.subviews.compactMap { $0 as? GridGhostEdge }
		let b = g.bounds
		if edges.count == 2 {
			edges[0].frame = NSRect(x: 0, y: 0, width: 1, height: b.height)
			edges[1].frame = NSRect(x: b.width - 1, y: 0, width: 1, height: b.height)
			edges.forEach { $0.needsDisplay = true }
		}
	}

	override func becomeFirstResponder() -> Bool {
		let ok = super.becomeFirstResponder()
		coordinator?.refreshEmphasis()
		return ok
	}

	override func resignFirstResponder() -> Bool {
		let ok = super.resignFirstResponder()
		coordinator?.refreshEmphasis()
		return ok
	}
}

/// 행 배경. 고정이 있으면 선택색(파랑/회색)을 두 표가 함께 정한다
final class GridRowView: NSTableRowView {
	weak var controller: GridController?

	/// 행 배경은 그리지 않는다: 줄무늬·세로선은 표(GridTableView.drawBackground)와 칸(GridCell.drawBackground)이 그린다.
	/// 행 전체를 칠하면 그 행이 표의 세로선을 덮었고, 컬럼 너비를 바꿔도 행은 다시 그려지지 않아 예전 자리 선이 남았다
	override func drawBackground(in dirtyRect: NSRect) {}

	// 고름·줄무늬 색이 바뀌면 칸들이 배경을 다시 칠한다
	override var isSelected: Bool {
		didSet { if isSelected != oldValue { subviews.forEach { $0.needsDisplay = true } } }
	}
	override var backgroundColor: NSColor {
		didSet { subviews.forEach { $0.needsDisplay = true } }
	}

	override var isEmphasized: Bool {
		get { super.isEmphasized }
		set { super.isEmphasized = controller?.emphasisOverride ?? newValue }
	}
}

/// 고정 칸 오른쪽 경계선. 일반 세로선보다 조금 진하게 (흰 2pt 선은 너무 튀었다). 마우스는 받지 않는다
final class GridEdgeLine: NSView {
	static let color = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.25)
	}
	override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
	required init?(coder: NSCoder) { fatalError() }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
	override func draw(_ dirtyRect: NSRect) {
		Self.color.setFill()
		bounds.fill()
	}
}

/// 끄는 컬럼 묶음의 양옆 테두리 (위아래 끝까지)
final class GridGhostEdge: NSView {
	override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
	required init?(coder: NSCoder) { fatalError() }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
	// 크기 0 으로 붙은 뒤 늘어나므로 그림 대신 층 바탕색으로 (그림은 크기가 바뀌어도 다시 안 그려졌다)
	override var wantsUpdateLayer: Bool { true }
	override func updateLayer() {
		effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = GridTableView.lineColor.cgColor }
	}
}

/// 컬럼 머리 줄. 배경을 직접 칠한다: 맥 26 은 머리 배경을 스크롤 가장자리 효과(흐림)로 그리는데
/// 고정 칸 머리는 그 효과 밖이라 검게 나왔고, 본 표 머리도 가끔 검게 나와 컬럼 구분선이 안 보였다(가로 스크롤하면 돌아옴)
final class GridHeaderView: NSTableHeaderView {
	static let background = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 45 / 255, green: 46 / 255, blue: 48 / 255, alpha: 1) : NSColor(white: 0.965, alpha: 1)
	}
	/// 고정 칸 머리: 검게 (고정됐다는 게 한눈에, 사용자가 좋다고 함)
	static let frozenBackground = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(white: 0.88, alpha: 1)
	}
	/// 컬럼 구분선 (AppKit 구분선이 안 그려질 때가 있어 직접)
	static let separator = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.18)
	}
	/// 아래 경계선 (고정 칸 머리: 본 표 머리는 스크롤 가장자리 효과가 그린다)
	var drawsBottomLine = false

	override var wantsUpdateLayer: Bool { false }

	/// 끄는 컬럼 머리 바탕 (머리보다 조금 밝게, 불투명)
	static let dragBackground = NSColor(name: nil) { a in
		a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 62 / 255, green: 63 / 255, blue: 66 / 255, alpha: 1) : NSColor(white: 0.9, alpha: 1)
	}

	override func draw(_ dirtyRect: NSRect) {
		(drawsBottomLine ? Self.frozenBackground : Self.background).setFill()
		dirtyRect.intersection(bounds).fill()
		guard let tv = tableView else { super.draw(dirtyRect); return }
		// 모두 직접 그린다: AppKit 은 배경을 투명하게 지우고 그려서 밑이 비면 검게 나왔고,
		// 끄는 컬럼 머리는 반투명에 위가 4pt 쯤 비어 보였다
		let dragged = draggedColumn
		for (i, tc) in tv.tableColumns.enumerated() where i != dragged {
			let r = headerRect(ofColumn: i)
			guard r.intersects(dirtyRect) else { continue }
			tc.headerCell.drawInterior(withFrame: r, in: self)
			Self.separator.setFill()
			NSRect(x: r.maxX - 1, y: r.minY + 6, width: 1, height: r.height - 12).fill()
		}
		if dragged >= 0, dragged < tv.numberOfColumns {
			// 끄는 동안 순서는 이미 바뀌어 있다(그 컬럼 자리 + 끈 거리). 표도 새 순서로 세로선을 다시 그리게
			let r = headerRect(ofColumn: dragged).offsetBy(dx: draggedDistance, dy: 0)
			Self.dragBackground.setFill()
			r.fill()
			tv.tableColumns[dragged].headerCell.drawInterior(withFrame: r, in: self)
			Self.separator.setFill()
			NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
			NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
			RunLoop.main.perform(inModes: [.eventTracking, .default]) { MainActor.assumeIsolated {
				tv.needsDisplay = true
				(tv as? GridTableView)?.solidifyGhost()
			} }
		}
		if drawsBottomLine {
			NSColor.gridColor.setFill()
			NSRect(x: dirtyRect.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: dirtyRect.width, height: 1).fill()
		}
	}
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
	/// 좌우 여백: 오른쪽 정렬 숫자와 옆 칸 왼쪽 정렬 글자가 세로선에 붙어 빽빽했다 (배경·세로선은 칸 전체라 그대로)
	static let padding: CGFloat = 4

	private func centered(_ rect: NSRect) -> NSRect {
		let rect = rect.insetBy(dx: Self.padding, dy: 0)
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

/// 칸 배경: 줄무늬 색(불투명) + 오른쪽 세로선. 칸이 직접 칠해야 컬럼을 끌 때 끄는 칸(고스트)이 비치지 않고,
/// 밀려나는 칸의 세로선도 칸과 같이 움직인다 (표 배경에 그린 선은 놓을 때까지 제자리였다).
/// 고른 행이면 줄무늬는 칠하지 않는다 (밑의 선택색이 보이게)
enum GridCellBackground {
	/// 지금 칸이면: 바탕은 고른 행 색 그대로, 테두리만 (편집 중처럼 보이지 않게)
	static func isCursor(_ view: NSView) -> Bool {
		guard let tv = view.superview?.superview as? GridTableView, let c = tv.coordinator else { return false }
		return c.isCursor(view, in: tv)
	}

	static func draw(in view: NSView, fill: NSColor?) {
		let b = view.bounds
		let cursor = isCursor(view)
		if let rv = view.superview as? NSTableRowView, !rv.isSelected {
			NSColor.alternatingContentBackgroundColors[0].setFill()
			b.fill()
			rv.backgroundColor.setFill()
			b.fill(using: .sourceOver)
		}
		if let fill {
			fill.setFill()
			b.fill(using: .sourceOver)
		}
		// 끄는 컬럼 묶음 안이면 선은 묶음 테두리가 위아래 끝까지 그린다 (겹치면 데이터 줄만 진했다)
		guard view.superview is NSTableRowView else { return }
		GridTableView.lineColor.setFill()
		NSRect(x: b.maxX - 1, y: b.minY, width: 1, height: b.height).fill(using: .sourceOver)
		if cursor {
			// 파란 선택색 위에서 잘 보이게 흰색 (선택이 회색일 때도 보인다)
			NSColor.white.withAlphaComponent(0.85).setStroke()
			let path = NSBezierPath(roundedRect: b.insetBy(dx: 1.5, dy: 1.5), xRadius: 2, yRadius: 2)
			path.lineWidth = 1.5
			path.stroke()
		}
	}
}

/// 표 칸 하나. 상태 배경(고친 칸 노랑·새 행 초록·지울 행 빨강)을 칸 전체에 칠한다.
/// 글자 칸(NSTextFieldCell)의 배경은 세로 가운데 맞춘 글자 높이만 칠해서 따로 그린다
final class GridField: NSTextField {
	var fill: NSColor? {
		didSet { if fill != oldValue { needsDisplay = true } }
	}

	override func draw(_ dirtyRect: NSRect) {
		GridCellBackground.draw(in: self, fill: fill)
		super.draw(dirtyRect)
	}
}

/// 체크박스 칸 (구조의 UNSIGNED·NULL). 상태 배경은 칸 전체에
final class GridCheckView: NSView {
	let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
	var fill: NSColor? {
		didSet { if fill != oldValue { needsDisplay = true } }
	}

	override init(frame: NSRect) {
		super.init(frame: frame)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.controlSize = .small
		addSubview(button)
		NSLayoutConstraint.activate([
			button.centerXAnchor.constraint(equalTo: centerXAnchor),
			button.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	required init?(coder: NSCoder) { fatalError() }

	override func draw(_ dirtyRect: NSRect) {
		GridCellBackground.draw(in: self, fill: fill)
	}
}
