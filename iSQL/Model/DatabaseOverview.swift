import Foundation
import AppKit
import Observation

/// DB 하나의 테이블 목록 (phpMyAdmin 구조 화면처럼): 행, 크기, 엔진, 정렬, 시각
struct TableStat: Hashable {
	var name: String
	var isView: Bool
	var engine: String
	var rows: Int64?
	var dataLength: Int64
	var indexLength: Int64
	var dataFree: Int64
	var autoIncrement: Int64?
	var collation: String
	var comment: String
	var updated: String
	var total: Int64 { dataLength + indexLength }
	var rowsExact: Bool { ["MYISAM", "ARIA"].contains(engine.uppercased()) }
}

/// DB 개요 탭의 내용. 공용 표(TableGrid)에 대는 공급자이기도 하다
@Observable
final class DatabaseOverview: GridSource {
	let schema: String
	@ObservationIgnored private weak var session: Session?
	private(set) var stats: [TableStat] = []
	private(set) var loading = false
	private(set) var error: String?
	private(set) var gridVersion = 0
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private var order: [Int] = []
	@ObservationIgnored private var sortState: (key: String, ascending: Bool)?
	/// 표에서 고른 행 (보이는 순서 번호)
	var selection = IndexSet()
	/// 검색 줄 보이기 (제목바 검색 버튼·⌥⌘F)
	var showSearch = false
	/// 테이블 이름·코멘트 검색 (띄어 쓴 낱말 모두 포함)
	var searchText = "" {
		didSet { if searchText != oldValue { resort() } }
	}
	/// 검색으로 걸러진 목록인지
	var isFiltered: Bool { !searchWords.isEmpty }
	private var searchWords: [String] { searchText.lowercased().split(separator: " ").map(String.init) }

	init(schema: String, session: Session) {
		self.schema = schema
		self.session = session
	}

	@MainActor
	func load() async {
		guard let session, !loading else { return }
		loading = true
		error = nil
		defer { loading = false }
		do {
			let r = try await session.query("""
				SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT,
				       TABLE_COLLATION, TABLE_COMMENT, COALESCE(UPDATE_TIME, CREATE_TIME)
				  FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal(.text(schema))) ORDER BY TABLE_NAME
				""").last ?? QueryResult()
			stats = r.rows.map { v in
				func i(_ k: Int) -> Int64? { v[safe: k]?.string.flatMap { Int64($0) } }
				let isView = v[safe: 1]?.string == "VIEW"
				return TableStat(name: v[0].string ?? "", isView: isView, engine: v[safe: 2]?.string ?? "",
				                 rows: i(3), dataLength: i(4) ?? 0, indexLength: i(5) ?? 0, dataFree: i(6) ?? 0,
				                 autoIncrement: i(7), collation: v[safe: 8]?.string ?? "",
				                 comment: isView ? "" : (v[safe: 9]?.string ?? ""), updated: v[safe: 10]?.string ?? "")
			}
			resort()
		} catch {
			self.error = error.localizedDescription
		}
	}

	// MARK: 합계

	var totalData: Int64 { stats.reduce(0) { $0 + $1.dataLength } }
	var totalIndex: Int64 { stats.reduce(0) { $0 + $1.indexLength } }
	var totalRows: Int64 { stats.reduce(0) { $0 + ($1.rows ?? 0) } }

	/// 보이는 순서의 n 번째 테이블
	func stat(at row: Int) -> TableStat? { order.indices.contains(row) ? stats[order[row]] : nil }

	/// 고른 테이블 (없으면 전체)
	var selectedStats: [TableStat] {
		let picked = selection.compactMap { stat(at: $0) }
		return picked.isEmpty ? order.map { stats[$0] } : picked
	}

	/// 보이는 순서의 전체
	var orderedStats: [TableStat] { order.map { stats[$0] } }

	/// 고른 테이블 내보내기 (하단바 버튼·여러 개 고른 오른쪽 클릭): 목록을 보이고 고른 것만 체크 (안 골랐으면 전부)
	func requestExportPicked() {
		// 검색으로 걸러져 있으면 목록에는 전체를 보이고, 보이는 것(또는 고른 것)만 체크한다
		session?.requestExport(.database(schema: schema, tables: isFiltered ? stats : orderedStats, picked: Set(selectedStats.map(\.name)), showPicker: true))
	}

	static func size(_ b: Int64) -> String {
		b == 0 ? "—" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
	}

	// MARK: GridSource

	var gridID: String { "db:" + schema }

	let gridColumns: [GridColumn] = [
		GridColumn(key: "name", title: "테이블", width: 220),
		GridColumn(key: "comment", title: "코멘트", width: 220),
		GridColumn(key: "engine", title: "엔진", width: 80),
		GridColumn(key: "rows", title: "행", numeric: true, width: 100),
		GridColumn(key: "data", title: "데이터", numeric: true, width: 90),
		GridColumn(key: "index", title: "인덱스", numeric: true, width: 90),
		GridColumn(key: "total", title: "전체", numeric: true, width: 90),
		GridColumn(key: "free", title: "여유", numeric: true, width: 80),
		GridColumn(key: "auto", title: "AUTO_INCREMENT", numeric: true, width: 130),
		GridColumn(key: "collation", title: "정렬", width: 160),
		GridColumn(key: "updated", title: "수정 시각", width: 160),
	]

	var rowCount: Int { order.count }

	private static let icons: (table: NSImage?, view: NSImage?) = {
		let conf = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
		return (NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)?.withSymbolConfiguration(conf),
		        NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(conf))
	}()

	func cell(_ row: Int, _ col: Int) -> GridCell {
		guard let s = stat(at: row) else { return GridCell(text: nil) }
		switch gridColumns[col].key {
		case "name": return GridCell(text: s.name, icon: s.isView ? Self.icons.view : Self.icons.table)
		case "comment": return GridCell(text: s.comment)
		case "engine": return GridCell(text: s.isView ? "뷰" : s.engine, dim: true)
		case "rows":
			guard let r = s.rows, !s.isView else { return GridCell(text: "", dim: true) }
			return GridCell(text: (s.rowsExact ? "" : "~") + r.formatted(), tooltip: s.rowsExact ? nil : "InnoDB 통계로 어림한 행 수")
		case "data": return GridCell(text: s.isView ? "" : Self.size(s.dataLength))
		case "index": return GridCell(text: s.isView ? "" : Self.size(s.indexLength), dim: true)
		case "total": return GridCell(text: s.isView ? "" : Self.size(s.total))
		case "free": return GridCell(text: s.isView || s.dataFree == 0 ? "" : Self.size(s.dataFree), dim: true)
		case "auto": return GridCell(text: s.autoIncrement.map { $0.formatted() } ?? "", dim: true)
		case "collation": return GridCell(text: s.collation, dim: true)
		default: return GridCell(text: s.updated, dim: true)
		}
	}

	/// 두 번 누르면 그 테이블 탭을 연다
	func activateRow(_ row: Int) {
		guard let s = stat(at: row), let session, let t = session.table(schema + "." + s.name) else { return }
		session.openTab(t)
	}

	/// 테이블 메뉴가 값/행 복사보다 먼저
	var cellMenuFirst: Bool { true }

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		let picked = selection.compactMap { stat(at: $0) }
		if picked.count > 1 {
			return [
				.action("선택 테이블 \(picked.count)개 내보내기…") { [weak self] in self?.requestExportPicked() },
				.separator,
				.action("선택 테이블 \(picked.count)개 비우기…") { [weak self] in guard let self else { return }; self.session?.requestTruncate(schema: self.schema, picked) },
				.action("선택 테이블 \(picked.count)개 삭제…") { [weak self] in guard let self else { return }; self.session?.requestDrop(schema: self.schema, picked) },
			]
		}
		guard let s = stat(at: row) else { return [] }
		return TableMenu.items(isView: s.isView,
		                       open: { [weak self] in self?.activateRow(row) },
		                       export: { [weak self] in guard let self else { return }; self.session?.requestExport(.table(self.schema, s)) },
		                       truncate: { [weak self] in guard let self else { return }; self.session?.requestTruncate(schema: self.schema, [s]) },
		                       drop: { [weak self] in guard let self else { return }; self.session?.requestDrop(schema: self.schema, [s]) })
	}

	var currentSort: (key: String, ascending: Bool)? { sortState }

	func sort(by key: String?, ascending: Bool) -> Bool {
		sortState = key.map { ($0, ascending) }
		resort()
		return true
	}

	private func resort() {
		let words = searchWords
		order = words.isEmpty ? Array(stats.indices) : stats.indices.filter { i in
			let hay = (stats[i].name + "\n" + stats[i].comment).lowercased()
			return words.allSatisfy { hay.contains($0) }
		}
		if let s = sortState {
			func num(_ t: TableStat) -> Int64? {
				switch s.key {
				case "rows": t.rows ?? -1
				case "data": t.dataLength
				case "index": t.indexLength
				case "total": t.total
				case "free": t.dataFree
				case "auto": t.autoIncrement ?? -1
				default: nil
				}
			}
			func text(_ t: TableStat) -> String {
				switch s.key {
				case "comment": t.comment
				case "engine": t.engine
				case "collation": t.collation
				case "updated": t.updated
				default: t.name
				}
			}
			order.sort { a, b in
				let x = stats[a], y = stats[b]
				if let nx = num(x), let ny = num(y), nx != ny { return s.ascending ? nx < ny : nx > ny }
				let r = text(x).localizedStandardCompare(text(y))
				return s.ascending ? r == .orderedAscending : r == .orderedDescending
			}
		}
		selection = []
		gridVersion += 1
	}
}
