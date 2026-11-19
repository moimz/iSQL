import Foundation
import AppKit
import Observation

/// 테이블 데이터 한 쪽(페이지)과 아직 저장하지 않은 변경.
/// 셀을 고쳐도 바로 DB 에 쓰지 않는다. 변경은 색으로 보여 주고, 저장(⌘S)할 때 한 트랜잭션으로 반영한다.
@Observable
final class TableData: ColumnOrderTracking {
	let table: TableInfo
	/// 이 데이터가 붙은 탭 id (같은 테이블을 두 탭에 열면 탭마다 따로)
	let tab: String
	let session: Session
	var dialect: any SQLDialect { session.dialect }
	/// JSON 컬럼인지: 결과 타입(MySQL JSON) 또는 테이블 목록의 컬럼 타입 json (MariaDB 는 json_valid 검사로 알아낸 것)
	func isJSONColumn(_ col: Int) -> Bool {
		guard columns.indices.contains(col) else { return false }
		if columns[col].isJSON { return true }
		let name = columnName(col)
		return (session.columns[table.id] ?? []).contains { $0.name == name && $0.type.lowercased() == "json" }
	}

	private(set) var columns: [Column] = []
	/// 서버에서 읽은 그대로의 행 (고친 값은 edits 에 따로 있다)
	private(set) var rows: [[Value]] = []
	/// 큰 BLOB 칸: 앞부분만 읽었다 → [행: [컬럼: 전체 바이트 수]]. 내용이 필요할 때(복사·훑어보기·저장) 기본 키로 다시 읽는다
	@ObservationIgnored private(set) var partial: [Int: [Int: Int64]] = [:]
	/// 이보다 큰 BLOB 은 앞부분만 (사용자 2026-11-17: 고정)
	static let blobLimit = 65_536
	static let blobPeek = 64
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
	/// 표에서 컬럼을 끌어 순서를 바꿨는지 (탭 메뉴 "컬럼 순서 복원")
	var columnsMoved = false
	/// 표가 걸어 두는 순서 되돌리기
	@ObservationIgnored var restoreColumns: (() -> Void)?
	@ObservationIgnored var visibleColumns: [Int]?
	/// 표 컬럼 설정 (순서·숨김·너비·고정): 세션이 테이블별로 들고 저장한 서버면 iCloud 에
	var columnLayout: TableColumnLayout? {
		get { session.columnLayout(table.id) }
		set { session.setColumnLayout(table.id, newValue) }
	}
	/// 테이블 구조 (컬럼 이름·타입 차례). 구조를 아직 못 읽었으면 nil
	var layoutStructure: String? {
		guard let cols = session.columns[table.id], !cols.isEmpty else { return nil }
		return cols.map { $0.name + " " + $0.type }.joined(separator: ",")
	}

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
		let parts = filters.compactMap { $0.sql(dialect) }
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
			let r = try await session.query("SELECT COUNT(*) FROM \(dialect.quote(table: table))\(filter.isEmpty ? "" : " WHERE " + filter)").last
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
		if let d = UserDefaults.standard.dictionary(forKey: unixKey) as? [String: String] {
			unixViews = d.compactMapValues(UnixTimeUnit.init(rawValue:))
		}
	}

	// MARK: 컬럼을 날짜로 보기 (유닉스 시간, 사용자 2026-11-20)

	/// 컬럼 이름 → 유닉스 시간 단위 (날짜로 보는 컬럼). 이 맥에 테이블마다 기억한다
	private(set) var unixViews: [String: UnixTimeUnit] = [:]
	private var unixKey: String { "unixTime.\(session.server?.id.uuidString ?? "-").\(table.id)" }
	private func columnKey(_ col: Int) -> String { columns[col].orgName.isEmpty ? columns[col].name : columns[col].orgName }
	func unixUnit(_ col: Int) -> UnixTimeUnit? { col < columns.count ? unixViews[columnKey(col)] : nil }

	func setUnixView(_ col: Int, _ unit: UnixTimeUnit?) {
		guard col < columns.count else { return }
		unixViews[columnKey(col)] = unit
		if unixViews.isEmpty { UserDefaults.standard.removeObject(forKey: unixKey) }
		else { UserDefaults.standard.set(unixViews.mapValues(\.rawValue), forKey: unixKey) }
		if unit != nil { fitRequests.insert(col) }
		version += 1
	}
	@ObservationIgnored private var fitRequests: Set<Int> = []
	func takeFitRequests() -> [Int] { defer { fitRequests = [] }; return Array(fitRequests) }

	/// 구조(COLUMN_TYPE)로 만든 임시 컬럼. 실제 결과가 오면 서버가 준 것으로 바뀐다 (이름이 같아 표는 다시 안 만든다)
	private static func placeholderColumn(_ c: ColumnInfo) -> Column {
		let t = c.type.lowercased()
		let numeric = ["int", "decimal", "numeric", "float", "double", "real", "bit"].contains { t.hasPrefix($0) || t.hasPrefix("tiny\($0)") || t.hasPrefix("small\($0)") || t.hasPrefix("medium\($0)") || t.hasPrefix("big\($0)") }
		let long = ["text", "blob", "json", "longtext", "mediumtext"].contains { t.contains($0) }
		return Column(name: c.name, orgName: c.name, table: "", orgTable: "", schema: "", charset: 45,
		              length: long ? 65535 : 255, type: numeric ? 3 : 253, flags: c.key == "PRI" ? 0x2 : 0, decimals: 0)
	}

	// MARK: - 읽기

	/// 읽는 중에 멈추기 (데이터 보기 오른쪽 아래 ■). 서버에 쿼리 취소를 보낸다
	@MainActor
	func cancelLoad() {
		guard loading, !loadCancelled else { return }
		loadCancelled = true
		session.cancelQuery()
	}
	@ObservationIgnored private var loadCancelled = false

	@MainActor
	func load(offset newOffset: Int = 0) async {
		loading = true
		loadCancelled = false
		error = nil
		defer { loading = false; loadCancelled = false }
		let pk = (session.columns[table.id] ?? []).filter { $0.key == "PRI" }.map { dialect.quote($0.name) }
		// 고른 정렬이 먼저, 같은 값끼리는 기본 키 순
		var orderParts: [String] = []
		if let sort, let expr = sortExpression(sort.column) { orderParts.append(expr + (sort.ascending ? " ASC" : " DESC")) }
		orderParts += pk.filter { $0 != sort.map { dialect.quote($0.column) } }
		let order = orderParts.isEmpty ? "" : " ORDER BY " + orderParts.joined(separator: ", ")
		let filter = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
		if filter != appliedWhere { knownTotal = nil }
		appliedWhere = filter
		// BLOB 컬럼은 크면 앞부분만 + 전체 크기 (기본 키가 있어야 나중에 한 칸만 다시 읽을 수 있다)
		let infos = session.columns[table.id] ?? []
		let blobs = pk.isEmpty ? [] : infos.filter { $0.type.lowercased().hasSuffix("blob") }.map(\.name)
		let select = blobs.isEmpty ? "*" : (infos.map { c in
			let q = dialect.quote(c.name)
			return blobs.contains(c.name) ? dialect.blobPeek(q, over: Self.blobLimit, keep: Self.blobPeek) + " AS \(q)" : q
		} + blobs.map { dialect.byteLength(dialect.quote($0)) }).joined(separator: ", ")
		let sql = dialect.paged("SELECT \(select) FROM \(dialect.quote(table: table))\(filter.isEmpty ? "" : " WHERE " + filter)\(order)", limit: pageSize + 1, offset: newOffset)
		do {
			var r = try await session.query(sql).last ?? QueryResult()
			// 뒤에 붙인 길이 컬럼을 떼어 큰 칸을 적어 둔다
			var big: [Int: [Int: Int64]] = [:]
			if !blobs.isEmpty, r.columns.count == infos.count + blobs.count {
				let blobCols = blobs.compactMap { b in infos.firstIndex { $0.name == b } }
				for (ri, row) in r.rows.enumerated() {
					for (k, c) in blobCols.enumerated() {
						if let n = Int64(row[infos.count + k].string ?? ""), n > Self.blobLimit { big[ri, default: [:]][c] = n }
					}
				}
				r.columns = Array(r.columns.prefix(infos.count))
				r.rows = r.rows.map { Array($0.prefix(infos.count)) }
			}
			partial = big
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
			self.error = loadCancelled ? "읽기를 멈췄습니다. 새로고침(⌘R)으로 다시 읽습니다." : error.localizedDescription
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

	/// 고른 행을 같은 값으로 새 행에 (기본 키 칸은 비워서 — 저장할 때 새 키·자동 증가)
	func duplicateRows(_ selected: IndexSet) {
		guard canEdit, !selected.isEmpty else { return }
		for r in selected.sorted() where !isDeleted(r) {
			inserted.append(columns.indices.map { keyIndices.contains($0) ? .null : value(r, $0) })
		}
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
			out.append(dialect.deleteRow(dialect.quote(table: table), condition: keyCondition(r)) + ";")
		}
		for (r, cols) in edits.sorted(by: { $0.key < $1.key }) where !deleted.contains(r) {
			let sets = cols.sorted { $0.key < $1.key }.map { "\(dialect.quote(columnName($0.key))) = \(dialect.literal($0.value))" }
			out.append(dialect.updateRow(dialect.quote(table: table), sets: sets, condition: keyCondition(r)) + ";")
		}
		for row in inserted {
			// NULL 로 남은 칸은 빼서 기본값·자동 증가가 쓰이게 한다
			let pairs = row.enumerated().filter { $0.element != .null }
			out.append(dialect.insertRow(dialect.quote(table: table), columns: pairs.map { dialect.quote(columnName($0.offset)) },
			                             values: pairs.map { dialect.literal($0.element) }) + ";")
		}
		return out
	}

	@MainActor
	func save() async -> Bool {
		let statements = changeSQL()
		guard !statements.isEmpty else { return true }
		saveError = nil
		do {
			_ = try await session.query(dialect.beginTransaction)
			for s in statements {
				let r = try await session.query(s).last
				// 바꾼 행이 없으면(다른 사람이 먼저 지웠거나 키가 바뀜) 멈춘다
				if s.hasPrefix("UPDATE") || s.hasPrefix("DELETE"), r?.affectedRows == 0, r?.info.contains("Rows matched: 1") != true {
					throw DBError.message("대상 행을 찾지 못했습니다. 다른 곳에서 바뀌었을 수 있습니다.\n\(s)")
				}
			}
			_ = try await session.query(dialect.commit)
			knownTotal = nil   // 행을 넣거나 지웠을 수 있다
			await load(offset: offset)
			return true
		} catch {
			_ = try? await session.query(dialect.rollback)
			saveError = error.localizedDescription
			return false
		}
	}

	// MARK: - SQL 만들기

	/// 지금 보는 상태의 SELECT (뷰로 만들기): DB 까지 붙인 테이블 + 적용한 찾기 조건 + 정렬
	var viewSQL: String {
		// 컬럼을 옮기거나 숨겼으면 보이는 순서대로 이름을 적는다
		let cols = visibleColumns.map { $0.filter { columns.indices.contains($0) }.map { dialect.quote(columnName($0)) }.joined(separator: ", ") }
		var s = "SELECT \(cols.flatMap { $0.isEmpty ? nil : $0 } ?? "*") FROM \(dialect.quote(table.schema)).\(dialect.quote(table.name))"
		if !appliedWhere.isEmpty { s += " WHERE " + appliedWhere }
		if let sort { s += " ORDER BY " + dialect.quote(sort.column) + (sort.ascending ? " ASC" : " DESC") }
		return s
	}

	/// 앞부분만 읽은 큰 BLOB 칸이 이 행들에 있는지
	func hasPartial(rows sel: IndexSet) -> Bool { sel.contains { partial[$0] != nil } }

	/// 이 행들의 큰 BLOB 칸 내용을 기본 키로 읽어 채운다
	@MainActor
	func loadFull(rows sel: IndexSet) async {
		let pk = keyIndices
		guard !pk.isEmpty else { return }
		for r in sel.sorted() {
			guard let cols = partial[r], r < rows.count else { continue }
			let names = cols.keys.sorted()
			let whereSQL = pk.map { "\(dialect.quote(columnName($0))) = \(dialect.literal(rows[r][$0]))" }.joined(separator: " AND ")
			let sql = dialect.paged("SELECT \(names.map { dialect.quote(columnName($0)) }.joined(separator: ", ")) FROM \(dialect.quote(table: table)) WHERE \(whereSQL)", limit: 1)
			guard let got = try? await session.query(sql).last?.rows.first, got.count == names.count else { continue }
			for (k, c) in names.enumerated() { rows[r][c] = got[k] }
			partial[r] = nil
		}
		version += 1
	}

	func columnName(_ i: Int) -> String {
		columns[i].orgName.isEmpty ? columns[i].name : columns[i].orgName
	}

	private func keyCondition(_ row: Int) -> String {
		keyIndices.map { i in
			let v = rows[row][i]
			return v == .null ? "\(dialect.quote(columnName(i))) IS NULL" : "\(dialect.quote(columnName(i))) = \(dialect.literal(v))"
		}.joined(separator: " AND ")
	}
}

/// 여러 줄 칸 편집 요청 (어느 행·컬럼, 처음 글자)
struct LongEditRequest: Identifiable {
	let id = UUID()
	let row: Int
	let col: Int
	let column: String
	/// JSON 편집기로 연다 (JSON 컬럼이거나 "JSON 으로 편집…")
	let isJSON: Bool
	let text: String
	let wasNull: Bool
	/// 컬럼 타입이 JSON (서버가 다시 쓰므로 한 줄로 저장)
	var jsonColumn = false
}

// MARK: - 공용 표(TableGrid)에 대기

extension TableData: GridSource {
	var gridID: String { tab }

	var gridColumns: [GridColumn] {
		let comments = Dictionary((session.columns[table.id] ?? []).map { ($0.name, $0.comment) }, uniquingKeysWith: { a, _ in a })
		return columns.enumerated().map { i, c in
			let key = c.orgName.isEmpty ? c.name : c.orgName
			let chars = Self.charLength(types[key])
			return GridColumn(key: key, title: c.name, comment: comments[key] ?? "", isKey: keyIndices.contains(i),
			                  numeric: c.isNumeric, mono: chars != nil, long: c.length > 255, monoChars: chars)
		}
	}

	/// 컬럼 이름 → 정의된 타입 (`enum('a','b')`, `char(32)` …)
	private var types: [String: String] {
		Dictionary((session.columns[table.id] ?? []).map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
	}

	private func columnType(_ col: Int) -> String? {
		guard columns.indices.contains(col) else { return nil }
		let c = columns[col]
		return types[c.orgName.isEmpty ? c.name : c.orgName]
	}

	/// CHAR(n) 이면 n: 고정 길이 글자(해시·코드 등)는 고정폭 글꼴로 보이고 그 너비에 맞춘다 (사용자 2026-11-17)
	static func charLength(_ type: String?) -> Int? {
		guard let t = type?.lowercased(), t.hasPrefix("char("), let end = t.firstIndex(of: ")") else { return nil }
		return Int(t[t.index(t.startIndex, offsetBy: 5)..<end])
	}

	/// `enum('a','b''c')` 의 값들 (아니면 nil)
	static func enumValues(_ type: String?) -> [String]? {
		guard let t = type, t.lowercased().hasPrefix("enum(") else { return nil }
		var out: [String] = []
		var cur = ""
		var inQuote = false
		var it = Array(t.dropFirst(5))[...]
		while let ch = it.popFirst() {
			if inQuote {
				if ch == "\\", let n = it.popFirst() { cur.append(n) }
				else if ch == "'" {
					if it.first == "'" { it.removeFirst(); cur.append("'") } else { inQuote = false; out.append(cur); cur = "" }
				} else { cur.append(ch) }
			} else if ch == "'" { inQuote = true }
			else if ch == ")" { break }
		}
		return out
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
		// 앞부분만 읽은 큰 BLOB: 형식은 앞부분으로, 크기는 전체로
		if st == .clean, let n = partial[row]?[col], case .bytes(let d) = v {
			return GridCell(text: BinaryInfo.describe(d, total: n), state: st, tooltip: "크기가 커서 앞부분만 읽었습니다. 복사·훑어보기·저장할 때 전체를 읽습니다")
		}
		// 날짜로 보는 컬럼: 숫자를 날짜로 (실제 값은 풍선 도움말에)
		if let u = unixUnit(col), case .text(let t) = v, let shown = u.display(t) {
			return GridCell(text: shown, state: st, tooltip: (tip.map { $0 + "\n" } ?? "") + "유닉스 시간(\(u.name)): \(t)")
		}
		return GridCell(text: v.display, state: st, tooltip: tip)
	}

	/// 날짜로 보는 컬럼에 날짜를 넣으면 그 단위의 숫자로 바꿔 넣는다 (숫자를 넣으면 그대로)
	func setText(_ row: Int, _ col: Int, _ text: String) {
		if let u = unixUnit(col), let raw = u.raw(text) { set(row, col, .text(raw)); return }
		set(row, col, .text(text))
	}

	var insertTarget: InsertTarget? {
		guard !table.isView else { return nil }
		return InsertTarget(table: dialect.quote(table.name), columns: columns.map(\.name),
		                    primaryKey: Set(keyIndices))
	}

	func sqlValue(_ row: Int, _ col: Int) -> Value? { value(row, col) }
	var sqlDialect: any SQLDialect { dialect }
	func hasPartialRows(_ rows: IndexSet) -> Bool { hasPartial(rows: rows) }
	func loadFullRows(_ rows: IndexSet) async { await loadFull(rows: rows) }
	func isBinaryColumn(_ col: Int) -> Bool { columns.indices.contains(col) && columns[col].isBinary }
	func setBinary(_ row: Int, _ col: Int, _ data: Data) -> Bool {
		guard canEdit, isBinaryColumn(col), !isDeleted(row) else { return false }
		set(row, col, .bytes(data))
		return true
	}

	/// ENUM 칸은 글자 입력 대신 값 고르기 메뉴 (사용자 2026-11-17)
	func choices(_ row: Int, _ col: Int) -> [String?]? {
		Self.enumValues(columnType(col)).map { $0.map(Optional.some) }
	}

	func currentChoice(_ row: Int, _ col: Int) -> String? { value(row, col).display }

	/// 바이너리(BLOB·BINARY) 칸은 고치지 않는다: 보이는 글자는 "(6 바이트)" 같은 표시라 고치면 그 글자로 덮어썼다
	func isEditable(_ row: Int, _ col: Int) -> Bool { !(columns.indices.contains(col) && columns[col].isBinary) }

	/// TEXT·JSON 칸은 칸 안이 아니라 시트에서 여러 줄로 고친다
	func opensEditor(_ row: Int, _ col: Int) -> Bool { columns.indices.contains(col) && columns[col].isLongText }

	func openEditor(_ row: Int, _ col: Int) { openEditor(row, col, asJSON: false) }

	/// asJSON: varchar·text 라도 JSON 편집기로 (JSON 처럼 보이는 값의 "JSON 으로 편집…")
	func openEditor(_ row: Int, _ col: Int, asJSON: Bool) {
		guard canEdit, !isDeleted(row) else { NSSound.beep(); return }
		let v = value(row, col)
		longEdit = LongEditRequest(row: row, col: col, column: columnName(col), isJSON: isJSONColumn(col) || asJSON,
		                           text: v.string ?? "", wasNull: v == .null, jsonColumn: isJSONColumn(col))
	}

	var currentSort: (key: String, ascending: Bool)? { sort.map { ($0.column, $0.ascending) } }

	/// 서버에서 ORDER BY 로 다시 읽는다. 저장 안 한 변경이 있으면 사라지니 하지 않는다
	/// 그 컬럼으로 정렬할 식 (정렬할 수 없는 형식이면 nil — Oracle 의 JSON · LONG 등)
	private func sortExpression(_ column: String) -> String? {
		let type = (session.columns[table.id] ?? []).first { $0.name == column }?.type ?? ""
		return dialect.sortExpression(dialect.quote(column), type: type)
	}

	func sort(by key: String?, ascending: Bool) -> Bool {
		if hasChanges { return false }
		if let key, sortExpression(key) == nil { return false }
		sort = key.map { ($0, ascending) }
		Task { @MainActor in await load() }
		return true
	}

	func headerMenu(_ col: Int) -> [GridMenuItem] {
		let key = gridColumns[col].key
		var items: [GridMenuItem] = [.action("‘\(key)’ 으로 찾기") { self.searchColumn(key) }]
		// 숫자 컬럼: 유닉스 시간이면 날짜로 보기 (단위를 고른다)
		if col < columns.count, columns[col].isNumeric {
			let now = unixUnit(col)
			var sub: [GridMenuItem] = UnixTimeUnit.allCases.map { u in
				.action((now == u ? "✓ " : "") + u.label) { self.setUnixView(col, u) }
			}
			sub.append(.separator)
			sub.append(.action((now == nil ? "✓ " : "") + "숫자 그대로") { self.setUnixView(col, nil) })
			items.append(.submenu("날짜로 보기 (유닉스 시간)", sub))
		}
		return items
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		var filterItems: [GridMenuItem] = []
		if let col, col < columns.count, !columns[col].isBinary {
			let name = columns[col].orgName.isEmpty ? columns[col].name : columns[col].orgName
			let text = value(row, col).string
			var ops: [(String, FilterOp)] = text == nil
				? [("IS NULL", .isNull), ("IS NOT NULL", .notNull)]
				: [("=", .eq), ("≠", .ne), ("LIKE", .like), ("NOT LIKE", .notLike), ("IS NULL", .isNull), ("IS NOT NULL", .notNull)]
			if text == nil { ops = ops.filter { !$0.1.needsValue } }
			// LIKE 는 앞뒤에 % 를 붙여 조건 줄에 그대로 보인다 (값 안의 % _ 는 글자로). 거기서 % 를 지워 고칠 수 있다 (사용자 2026-11-18: 포함·포함 안 함 대신)
			func filterValue(_ op: FilterOp) -> String {
				guard let text else { return "" }
				return op == .like || op == .notLike ? "%" + dialect.likeEscaped(text) + "%" : text
			}
			var sub: [GridMenuItem] = ops.map { title, op in .action(title) { self.filterBy(name, op, filterValue(op)) } }
			// JSON 칸: 그 JSON 의 값들로 바로 거르기를 먼저 (함수 이름을 몰라도 되게, 사용자 2026-11-18)
			if let text, isJSONColumn(col), session.capabilities.jsonPathFilter {
				let json = Self.jsonFilterChoices(text)
				if !json.isEmpty {
					sub = json.map { c in .action(c.title) { self.filterBy(name, c.op, c.value, path: c.path) } } + [.separator] + sub
				}
			}
			filterItems = [.submenu("현재 값으로 검색", sub)]
		}
		guard canEdit else { return filterItems }
		var items: [GridMenuItem] = []
		if let col {
			// JSON 컬럼이 아닌데 값이 JSON 처럼 보이면 (일반 편집은 그대로 글자 편집)
			if !isJSONColumn(col), !columns[col].isBinary, let t = value(row, col).string, JSONFormat.looksLikeJSON(t) {
				items.append(.action("JSON 으로 편집…") { self.openEditor(row, col, asJSON: true) })
			}
			items.append(.action("NULL 로 바꾸기") { self.set(row, col, .null) })
			items.append(.action("빈 문자열로 바꾸기") { self.set(row, col, .text("")) })
			if state(row, col) == .edited { items.append(.action("원래 값으로") { self.revert(row, col) }) }
			items.append(.separator)
		}
		items.append(.action("행 추가") { self.addRow() })
		items.append(.action("행 복제 (\(selection.count)개)") { self.duplicateRows(selection) })
		let allDeleted = selection.allSatisfy { isDeleted($0) }
		items.append(.action(allDeleted ? "삭제 취소" : "행 삭제 (\(selection.count)개)") { self.toggleDelete(selection) })
		return filterItems.isEmpty ? items : filterItems + [.separator] + items
	}

	/// 칸 값으로 거르기: 찾기 줄을 이 조건 하나로 채우고 바로 적용 (찾기 줄을 보여 준다)
	func filterBy(_ column: String, _ op: FilterOp, _ value: String, path: String = "") {
		filters = [FilterRow(column: column, op: op, value: op.needsValue ? value : "", path: path)]
		matchAll = true
		whereClause = generatedWhere()
		showFilter = true
		Task { @MainActor in await applyWhere() }
	}

	/// JSON 칸 메뉴의 고를 거리: 끝 값마다 "$.경로 = 값", 글자·숫자 배열은 "$.경로 에 값 포함", 끝에 "JSON 어디든" (많으면 앞쪽만)
	static func jsonFilterChoices(_ text: String, limit: Int = 15) -> [(title: String, op: FilterOp, value: String, path: String)] {
		guard let data = text.data(using: .utf8),
		      let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
		var out: [(title: String, op: FilterOp, value: String, path: String)] = []
		var firstText: String?
		func scalar(_ v: Any) -> String? {
			if let n = v as? NSNumber {
				if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
				return n.stringValue
			}
			return v as? String
		}
		func key(_ k: String) -> String {
			k.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) } && !(k.first?.isNumber ?? true) ? "." + k : ".\"" + k.replacingOccurrences(of: "\"", with: "\\\"") + "\""
		}
		func walk(_ v: Any, _ path: String) {
			guard out.count < limit else { return }
			if let d = v as? [String: Any] {
				for k in d.keys.sorted() { walk(d[k]!, path + key(k)) }
			} else if let a = v as? [Any] {
				let scalars = a.compactMap(scalar)
				if scalars.count == a.count, !a.isEmpty {
					for s in scalars.prefix(3) where out.count < limit {
						out.append(("\(path) 에 \"\(s)\" 포함", .jsonContains, s, path))
						if firstText == nil, Double(s) == nil { firstText = s }
					}
				} else {
					for (i, e) in a.prefix(3).enumerated() { walk(e, path + "[\(i)]") }
				}
			} else if let s = scalar(v) {
				out.append(("\(path) = \(s.count > 40 ? String(s.prefix(40)) + "…" : s)", .eq, s, path))
				if firstText == nil, Double(s) == nil, s != "true", s != "false" { firstText = s }
			}
		}
		walk(root, "$")
		if let t = firstText { out.append(("JSON 어디든 \"\(t.count > 40 ? String(t.prefix(40)) + "…" : t)\"", .jsonAnywhere, t, "")) }
		return out
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
		statTotal != nil ? "정확한 행 개수 보기"
		                 : "정확한 행 개수 보기"
	}
	var isEmptyResult: Bool { loaded && !loading && error == nil && rows.isEmpty }
}
