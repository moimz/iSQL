import Foundation
import AppKit
import Observation

/// 테이블 데이터 한 쪽(페이지)과 아직 저장하지 않은 변경.
/// 셀을 고쳐도 바로 DB 에 쓰지 않는다. 변경은 색으로 보여 주고, 저장(⌘S)할 때 한 트랜잭션으로 반영한다.
@Observable
final class TableData {
	let table: TableInfo
	/// 이 데이터가 붙은 탭 id (같은 테이블을 두 탭에 열면 탭마다 따로)
	let tab: String
	let session: Session

	private(set) var columns: [Column] = []
	/// 서버에서 읽은 그대로의 행 (고친 값은 edits 에 따로 있다)
	private(set) var rows: [[Value]] = []
	private(set) var loading = false
	private(set) var error: String?
	private(set) var saveError: String?

	/// 행 번호 → (컬럼 번호 → 새 값)
	private(set) var edits: [Int: [Int: Value]] = [:]
	/// 지울 행 번호
	private(set) var deleted: Set<Int> = []
	/// 새로 넣을 행 (grid 에서는 rows 뒤에 붙어서 보인다)
	private(set) var inserted: [[Value]] = []

	/// 화면을 다시 그려야 할 때마다 오른다 (NSTableView 갱신용)
	private(set) var version = 0

	var whereClause = ""

	enum Mode { case data, structure }
	/// 데이터 / 구조 (제목바 세그먼트)
	var mode: Mode = .data
	/// WHERE 조건 줄을 보이는지 (제목바 검색 버튼)
	var showFilter = false
	/// 표 스크롤 위치 (표 하나를 탭들이 돌려 쓰므로 탭마다 기억)
	@ObservationIgnored var scrollOrigin: CGPoint = .zero

	/// 구조 편집 (구조 화면을 처음 볼 때 만든다)
	@ObservationIgnored private var structureStore: StructureEditor?
	var structure: StructureEditor? { structureStore }

	func structureEditor() -> StructureEditor {
		if let e = structureStore { return e }
		let e = StructureEditor(table: table, session: session, columns: session.columns[table.id] ?? [])
		e.onChange = { [weak self] in self?.reportUnsaved() }
		structureStore = e
		return e
	}

	/// 구조 저장: 데이터에 저장 안 한 변경이 있으면 막는다 (컬럼이 바뀌면 고친 칸이 엉뚱한 컬럼에 붙는다)
	@MainActor
	func saveStructure() async {
		guard let e = structureStore, e.hasChanges, !e.saving else { return }
		if hasChanges { e.saveError = "데이터 보기에 저장 안 한 변경이 있습니다. 먼저 저장하거나 되돌리세요."; return }
		await e.save()
		if !e.hasChanges && e.saveError == nil {
			reportUnsaved()
			// 컬럼이 바뀌었으니 데이터도 다시 (한 번이라도 읽은 탭만)
			if loaded { await load(offset: offset) }
		}
	}

	/// 데이터·구조 어느 쪽이든 저장 안 한 게 있으면 사이드바·탭에 표시
	private func reportUnsaved() {
		session.setUnsaved(tab, hasChanges || structureStore?.hasChanges == true)
	}

	/// 쿼리 패널에서 이 테이블을 바꿔서 다시 읽어야 함 (다시 읽으면 풀린다)
	var stale = false

	/// 저장하는 중 (⌘S 를 탭 묶음에서 받으므로 상태를 여기 둔다)
	private(set) var saving = false
	/// 저장 안 한 SQL 미리보기 시트
	var showSQL = false
	/// 여러 줄 글자·JSON 칸 편집 시트 (창 제목바에 붙는다)
	var longEdit: LongEditRequest?

	@MainActor
	func saveIfNeeded() async {
		guard hasChanges, !saving else { return }
		saving = true
		_ = await save()
		saving = false
	}

	/// 값 칸에 커서를 줄 조건 줄 (이 컬럼으로 찾기)
	var focusFilterID: UUID?
	/// 컬럼 제목을 눌러 고른 정렬 (서버에서 ORDER BY)
	var sort: (column: String, ascending: Bool)?

	/// 이 컬럼으로 찾기: 조건 줄을 보이고, 그 컬럼 줄이 없으면 추가해서 값 칸에 커서를 둔다.
	/// 값을 아직 안 넣은 줄 하나뿐이면 새 줄을 늘리지 않고 그 줄의 컬럼을 바꾼다
	func searchColumn(_ name: String) {
		showFilter = true
		if let row = filters.first(where: { $0.column == name }) {
			focusFilterID = row.id
			return
		}
		if filters.count == 1, filters[0].value.isEmpty, filters[0].op.needsValue {
			filters[0].column = name
			filters[0].enabled = true
			focusFilterID = filters[0].id
			return
		}
		let row = FilterRow(column: name)
		filters.append(row)
		focusFilterID = row.id
	}
	/// 필터 줄 (바꾸면 whereClause 를 다시 만든다)
	var filters: [FilterRow] = []
	/// true = 모두 만족(AND), false = 하나라도(OR)
	var matchAll = true
	/// 최근에 적용한 WHERE 절 (최대 10개)
	private(set) var history: [String] = []

	/// 필터 줄로 만든 WHERE 절
	func generatedWhere() -> String {
		let parts = filters.compactMap(\.sql)
		if parts.count <= 1 { return parts.first ?? "" }
		return parts.map { "(\($0))" }.joined(separator: matchAll ? " AND " : " OR ")
	}

	/// 처음 열 때 필터 한 줄과 최근 WHERE 절을 준비한다
	func prepareFilters() {
		guard filters.isEmpty else { return }
		let cols = session.columns[table.id] ?? []
		let first = cols.first { $0.key == "PRI" } ?? cols.first
		filters = [FilterRow(column: first?.name ?? "")]
		history = WhereHistory.load(server: session.server?.id, table: table.id)
	}

	/// WHERE 절을 적용한다 (최근 목록에 넣고 처음 쪽부터 다시 읽기)
	@MainActor
	func applyWhere() async {
		history = WhereHistory.remember(whereClause, server: session.server?.id, table: table.id)
		await load()
	}

	func forget(_ clause: String) {
		history = WhereHistory.remove(clause, server: session.server?.id, table: table.id)
	}
	/// 한 쪽 행 수 (고르면 다음에 여는 테이블도 그 값)
	static let pageSizes = [50, 100, 200, 300, 500, 1000]
	private(set) var pageSize: Int = {
		let v = UserDefaults.standard.integer(forKey: "pageSize")
		return TableData.pageSizes.contains(v) ? v : 300
	}()
	private(set) var offset = 0
	private(set) var hasMore = false
	/// 지금 보이는 행을 읽을 때 쓴 WHERE (입력 중인 whereClause 와 다를 수 있다)
	private(set) var appliedWhere = ""

	/// 지금 쪽 (1부터)
	var page: Int { offset / max(1, pageSize) + 1 }

	/// 마지막 쪽에서 알아낸 정확한 행 수 (조건이 바뀌거나 저장하면 버린다)
	private(set) var knownTotal: Int?

	/// 정확한 전체 행 수: 마지막 쪽까지 한 번 가 봤으면 안다
	var exactTotal: Int? { error == nil ? knownTotal : nil }

	/// 조건 없이 볼 때의 테이블 통계 행 수 (InnoDB 는 어림값)
	var statTotal: Int64? { appliedWhere.isEmpty ? table.rows : nil }

	/// 전체 쪽 수 (모르면 nil), 어림값인지
	var totalPages: (count: Int, approx: Bool)? {
		if let t = exactTotal { return (max(1, Int(ceil(Double(t) / Double(pageSize)))), false) }
		if let t = statTotal, t > 0 { return (max(1, Int(ceil(Double(t) / Double(pageSize)))), !table.rowsExact) }
		return nil
	}

	/// 아래 줄 행 수 글자: 정확하면 "1,234행", InnoDB 통계면 "~10,000행", 조건을 걸었는데 더 있을 수 있으면 "900행~"
	var totalText: String {
		if let t = exactTotal { return "\(t.formatted())행" }
		if let t = statTotal { return (table.rowsExact ? "" : "~") + "\(t.formatted())행" }
		if rows.isEmpty { return "" }
		return "\((offset + rows.count).formatted())행~"
	}

	/// 어림값이라 눌러서 정확히 셀 수 있는지
	var totalIsApprox: Bool {
		if exactTotal != nil { return false }
		if statTotal != nil { return !table.rowsExact }
		return !rows.isEmpty
	}

	/// COUNT(*) 로 세는 중
	private(set) var counting = false

	/// 지금 조건(appliedWhere)으로 SELECT COUNT(*) 를 돌려 정확한 행 수를 얻는다
	@MainActor
	func countExact() async {
		guard !counting else { return }
		counting = true
		defer { counting = false }
		let filter = appliedWhere
		do {
			let r = try await session.query("SELECT COUNT(*) FROM \(table.quoted)\(filter.isEmpty ? "" : " WHERE " + filter)").last
			// 세는 동안 조건이 바뀌었으면 버린다
			if filter == appliedWhere, let n = r?.rows.first?.first?.string.flatMap({ Int($0) }) { knownTotal = n }
		} catch {
			NSSound.beep()
		}
	}

	@MainActor
	func setPageSize(_ n: Int) async {
		guard n != pageSize else { return }
		pageSize = n
		UserDefaults.standard.set(n, forKey: "pageSize")
		await load(offset: 0)
	}

	@MainActor
	func goPage(_ p: Int) async {
		var target = max(1, p)
		if let t = totalPages, !t.approx { target = min(target, t.count) }
		await load(offset: (target - 1) * pageSize)
	}

	/// 기본 키 컬럼 번호. 없으면 고칠 수 없다
	private(set) var keyIndices: [Int] = []
	var canEdit: Bool { !keyIndices.isEmpty && !table.isView }
	var readOnlyReason: String? {
		if table.isView { return "뷰는 고칠 수 없습니다." }
		if keyIndices.isEmpty && !columns.isEmpty { return "기본 키가 없는 테이블이라 고칠 수 없습니다." }
		return nil
	}

	var totalRows: Int { rows.count + inserted.count }
	var editCount: Int { edits.filter { !deleted.contains($0.key) }.reduce(0) { $0 + $1.value.count } }
	var changeCount: Int { editCount + deleted.count + inserted.count }
	var hasChanges: Bool { changeCount > 0 }

	/// 다시 그리게 하고, 저장 안 한 변경 여부를 세션에 알린다 (사이드바 표시)
	private func bump() {
		version += 1
		reportUnsaved()
	}

	/// 한 번이라도 읽었는지 (제목은 구조로 먼저 만들어 두므로 columns 로는 알 수 없다)
	private(set) var loaded = false

	init(table: TableInfo, tab: String, session: Session) {
		self.tab = tab
		self.table = table
		self.session = session
		// 컬럼 제목은 접속 때 읽어 둔 구조로 바로 만든다. 행은 받아오는 대로 채운다
		let info = session.columns[table.id] ?? []
		columns = info.map(Self.placeholderColumn)
		keyIndices = info.indices.filter { info[$0].key == "PRI" }
	}

	/// 구조(COLUMN_TYPE)로 만든 임시 컬럼. 실제 결과가 오면 서버가 준 것으로 바뀐다 (이름이 같아 표는 다시 안 만든다)
	private static func placeholderColumn(_ c: ColumnInfo) -> Column {
		let t = c.type.lowercased()
		let numeric = ["int", "decimal", "numeric", "float", "double", "real", "bit"].contains { t.hasPrefix($0) || t.hasPrefix("tiny\($0)") || t.hasPrefix("small\($0)") || t.hasPrefix("medium\($0)") || t.hasPrefix("big\($0)") }
		let long = ["text", "blob", "json", "longtext", "mediumtext"].contains { t.contains($0) }
		return Column(name: c.name, orgName: c.name, table: "", orgTable: "", schema: "", charset: 45,
		              length: long ? 65535 : 255, type: numeric ? 3 : 253, flags: c.key == "PRI" ? 0x2 : 0, decimals: 0)
	}

	// MARK: - 읽기

	@MainActor
	func load(offset newOffset: Int = 0) async {
		loading = true
		error = nil
		defer { loading = false }
		let pk = (session.columns[table.id] ?? []).filter { $0.key == "PRI" }.map { quoteName($0.name) }
		// 고른 정렬이 먼저, 같은 값끼리는 기본 키 순
		var orderParts: [String] = []
		if let sort { orderParts.append(quoteName(sort.column) + (sort.ascending ? " ASC" : " DESC")) }
		orderParts += pk.filter { $0 != sort.map { quoteName($0.column) } }
		let order = orderParts.isEmpty ? "" : " ORDER BY " + orderParts.joined(separator: ", ")
		let filter = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
		if filter != appliedWhere { knownTotal = nil }
		appliedWhere = filter
		let sql = "SELECT * FROM \(table.quoted)\(filter.isEmpty ? "" : " WHERE " + filter)\(order) LIMIT \(pageSize + 1) OFFSET \(newOffset)"
		do {
			let r = try await session.query(sql).last ?? QueryResult()
			columns = r.columns
			hasMore = r.rows.count > pageSize
			rows = Array(r.rows.prefix(pageSize))
			if !hasMore { knownTotal = newOffset + rows.count }
			offset = newOffset
			let pkNames = Set((session.columns[table.id] ?? []).filter { $0.key == "PRI" }.map(\.name))
			keyIndices = columns.indices.filter { pkNames.contains(columns[$0].orgName.isEmpty ? columns[$0].name : columns[$0].orgName) }
			loaded = true
			stale = false
			discard()
		} catch {
			loaded = true
			self.error = error.localizedDescription
		}
	}

	// MARK: - 값

	/// 화면에 보일 값 (고친 값이 있으면 그것)
	func value(_ row: Int, _ col: Int) -> Value {
		if row >= rows.count { return inserted[row - rows.count][safe: col] ?? .null }
		return edits[row]?[col] ?? rows[row][col]
	}

	func original(_ row: Int, _ col: Int) -> Value? {
		row < rows.count ? rows[row][col] : nil
	}

	enum CellState { case clean, edited, inserted, deleted }

	func state(_ row: Int, _ col: Int) -> CellState {
		if row >= rows.count { return .inserted }
		if deleted.contains(row) { return .deleted }
		return edits[row]?[col] != nil ? .edited : .clean
	}

	func isDeleted(_ row: Int) -> Bool { deleted.contains(row) }

	// MARK: - 고치기

	func set(_ row: Int, _ col: Int, _ v: Value) {
		guard canEdit else { return }
		if row >= rows.count {
			inserted[row - rows.count][col] = v
		} else if rows[row][col] == v {
			edits[row]?[col] = nil
			if edits[row]?.isEmpty == true { edits[row] = nil }
		} else {
			edits[row, default: [:]][col] = v
		}
		bump()
	}

	func revert(_ row: Int, _ col: Int) {
		guard row < rows.count else { return }
		set(row, col, rows[row][col])
	}

	func addRow() {
		guard canEdit else { return }
		inserted.append(Array(repeating: .null, count: columns.count))
		bump()
	}

	/// 기존 행은 지울 표시(다시 누르면 취소), 새 행은 바로 뺀다
	func toggleDelete(_ selected: IndexSet) {
		guard canEdit else { return }
		let existing = selected.filter { $0 < rows.count }
		let allDeleted = !existing.isEmpty && existing.allSatisfy { deleted.contains($0) }
		for r in existing { if allDeleted { deleted.remove(r) } else { deleted.insert(r) } }
		for r in selected.filter({ $0 >= rows.count }).sorted(by: >) { inserted.remove(at: r - rows.count) }
		bump()
	}

	func discard() {
		edits = [:]
		deleted = []
		inserted = []
		saveError = nil
		bump()
	}

	// MARK: - 저장

	/// 저장할 때 실행할 SQL (미리보기에도 쓴다)
	func changeSQL() -> [String] {
		var out: [String] = []
		for r in deleted.sorted() {
			out.append("DELETE FROM \(table.quoted) WHERE \(keyCondition(r)) LIMIT 1;")
		}
		for (r, cols) in edits.sorted(by: { $0.key < $1.key }) where !deleted.contains(r) {
			let sets = cols.sorted { $0.key < $1.key }.map { "\(quoteName(columnName($0.key))) = \(literal($0.value))" }
			out.append("UPDATE \(table.quoted) SET \(sets.joined(separator: ", ")) WHERE \(keyCondition(r)) LIMIT 1;")
		}
		for row in inserted {
			// NULL 로 남은 칸은 빼서 기본값·자동 증가가 쓰이게 한다
			let pairs = row.enumerated().filter { $0.element != .null }
			if pairs.isEmpty { out.append("INSERT INTO \(table.quoted) () VALUES ();"); continue }
			out.append("INSERT INTO \(table.quoted) (\(pairs.map { quoteName(columnName($0.offset)) }.joined(separator: ", "))) VALUES (\(pairs.map { literal($0.element) }.joined(separator: ", ")));")
		}
		return out
	}

	@MainActor
	func save() async -> Bool {
		let statements = changeSQL()
		guard !statements.isEmpty else { return true }
		saveError = nil
		do {
			_ = try await session.query("START TRANSACTION")
			for s in statements {
				let r = try await session.query(s).last
				// 바꾼 행이 없으면(다른 사람이 먼저 지웠거나 키가 바뀜) 멈춘다
				if s.hasPrefix("UPDATE") || s.hasPrefix("DELETE"), r?.affectedRows == 0, r?.info.contains("Rows matched: 1") != true {
					throw MySQLError.protocolError("대상 행을 찾지 못했습니다. 다른 곳에서 바뀌었을 수 있습니다.\n\(s)")
				}
			}
			_ = try await session.query("COMMIT")
			knownTotal = nil   // 행을 넣거나 지웠을 수 있다
			await load(offset: offset)
			return true
		} catch {
			_ = try? await session.query("ROLLBACK")
			saveError = error.localizedDescription
			return false
		}
	}

	// MARK: - SQL 만들기

	func columnName(_ i: Int) -> String {
		columns[i].orgName.isEmpty ? columns[i].name : columns[i].orgName
	}

	private func keyCondition(_ row: Int) -> String {
		keyIndices.map { i in
			let v = rows[row][i]
			return v == .null ? "\(quoteName(columnName(i))) IS NULL" : "\(quoteName(columnName(i))) = \(literal(v))"
		}.joined(separator: " AND ")
	}
}

/// 여러 줄 칸 편집 요청 (어느 행·컬럼, 처음 글자)
struct LongEditRequest: Identifiable {
	let id = UUID()
	let row: Int
	let col: Int
	let column: String
	let isJSON: Bool
	let text: String
	let wasNull: Bool
}

func quoteName(_ s: String) -> String { "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }

/// MySQL 문자열 리터럴 (숫자 컬럼도 '123' 으로 넣으면 서버가 바꿔 준다)
func literal(_ v: Value) -> String {
	switch v {
	case .null: return "NULL"
	case .bytes(let d): return d.isEmpty ? "''" : "X'" + d.map { String(format: "%02X", $0) }.joined() + "'"
	case .text(let s):
		var out = "'"
		for ch in s.unicodeScalars {
			switch ch {
			case "\\": out += "\\\\"
			case "'": out += "\\'"
			case "\0": out += "\\0"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\u{1A}": out += "\\Z"
			default: out.unicodeScalars.append(ch)
			}
		}
		return out + "'"
	}
}

// MARK: - 공용 표(TableGrid)에 대기

extension TableData: GridSource {
	var gridID: String { tab }

	var gridColumns: [GridColumn] {
		let comments = Dictionary((session.columns[table.id] ?? []).map { ($0.name, $0.comment) }, uniquingKeysWith: { a, _ in a })
		return columns.enumerated().map { i, c in
			let key = c.orgName.isEmpty ? c.name : c.orgName
			return GridColumn(key: key, title: c.name, comment: comments[key] ?? "", isKey: keyIndices.contains(i),
			                  numeric: c.isNumeric, long: c.length > 255)
		}
	}

	var gridVersion: Int { version }
	var rowCount: Int { totalRows }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		let v = value(row, col)
		let st: GridCellState
		switch state(row, col) {
		case .clean: st = .clean
		case .edited: st = .edited
		case .inserted: st = .inserted
		case .deleted: st = .deleted
		}
		var tip: String?
		if st == .edited, let o = original(row, col) { tip = "원래 값: " + (o.string ?? "NULL") }
		return GridCell(text: v.string, state: st, tooltip: tip)
	}

	func setText(_ row: Int, _ col: Int, _ text: String) { set(row, col, .text(text)) }

	/// TEXT·JSON 칸은 칸 안이 아니라 시트에서 여러 줄로 고친다
	func opensEditor(_ row: Int, _ col: Int) -> Bool { columns.indices.contains(col) && columns[col].isLongText }

	func openEditor(_ row: Int, _ col: Int) {
		guard canEdit, !isDeleted(row) else { NSSound.beep(); return }
		let v = value(row, col)
		longEdit = LongEditRequest(row: row, col: col, column: columnName(col), isJSON: columns[col].isJSON,
		                           text: v.string ?? "", wasNull: v == .null)
	}

	var currentSort: (key: String, ascending: Bool)? { sort.map { ($0.column, $0.ascending) } }

	/// 서버에서 ORDER BY 로 다시 읽는다. 저장 안 한 변경이 있으면 사라지니 하지 않는다
	func sort(by key: String?, ascending: Bool) -> Bool {
		if hasChanges { return false }
		sort = key.map { ($0, ascending) }
		Task { @MainActor in await load() }
		return true
	}

	func headerMenu(_ col: Int) -> [GridMenuItem] {
		let key = gridColumns[col].key
		return [.action("‘\(key)’ 으로 찾기") { self.searchColumn(key) }]
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		guard canEdit else { return [] }
		var items: [GridMenuItem] = []
		if let col {
			items.append(.action("NULL 로 바꾸기") { self.set(row, col, .null) })
			items.append(.action("빈 문자열로 바꾸기") { self.set(row, col, .text("")) })
			if state(row, col) == .edited { items.append(.action("원래 값으로") { self.revert(row, col) }) }
			items.append(.separator)
		}
		let allDeleted = selection.allSatisfy { isDeleted($0) }
		items.append(.action(allDeleted ? "삭제 취소" : "행 삭제 (\(selection.count)개)") { self.toggleDelete(selection) })
		return items
	}

	func deleteRows(_ rows: IndexSet) -> Bool {
		guard canEdit else { return false }
		toggleDelete(rows)
		return true
	}
}

// MARK: - 쪽 줄(PagerBar)에 대기

extension TableData: Pager {
	var pageable: Bool { true }
	var approxHelp: String {
		statTotal != nil ? "InnoDB 통계로 어림한 행 수입니다. 누르면 정확히 셉니다 (SELECT COUNT(*))"
		                 : "불러온 만큼만 셌습니다. 누르면 정확히 셉니다 (SELECT COUNT(*))"
	}
	var isEmptyResult: Bool { loaded && !loading && error == nil && rows.isEmpty }
}
