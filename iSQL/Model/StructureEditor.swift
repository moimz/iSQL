import Foundation
import AppKit
import Observation

/// 구조 편집에서 컬럼 하나의 정의 (이름 + 고칠 수 있는 칸들)
struct StructColumn: Equatable {
	var name = ""
	/// 대문자 종류 (INT, VARCHAR …)
	var type = "VARCHAR"
	/// 괄호 안: 255, 10,2, 'a','b'
	var length = "255"
	var unsigned = false
	var zerofill = false
	var nullable = true
	/// nil = 기본값 없음
	var defaultValue: String?
	/// 기본값이 식(CURRENT_TIMESTAMP 등, EXTRA 의 DEFAULT_GENERATED)
	var defaultExpr = false
	var autoIncrement = false
	/// "on update CURRENT_TIMESTAMP" (없으면 빈 글자)
	var onUpdate = ""
	/// 계산 컬럼: VIRTUAL / STORED 와 식
	var generated: String?
	var generationExpr = ""
	var comment = ""
	var charset: String?
	var collation: String?
	/// PRI / UNI / MUL (표시만)
	var key = ""

	static let textTypes: Set<String> = ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET"]
	var isNumeric: Bool { NewColumn.numericTypes.contains(type) }
	var takesLength: Bool { NewColumn.takesLength.contains(type) }

	/// 이름·키를 뺀 정의가 같은지
	func sameDefinition(_ o: StructColumn) -> Bool {
		var a = self, b = o
		a.name = ""; b.name = ""; a.key = ""; b.key = ""
		return a == b
	}

	/// 이름 뒤에 오는 정의: int unsigned NOT NULL DEFAULT … AUTO_INCREMENT COMMENT '…'
	var definition: String {
		var s = type
		let len = length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, takesLength { s += "(\(len))" }
		if isNumeric && unsigned { s += " UNSIGNED" }
		if isNumeric && zerofill { s += " ZEROFILL" }
		if Self.textTypes.contains(type), let co = collation, !co.isEmpty {
			if let cs = charset, !cs.isEmpty { s += " CHARACTER SET \(cs)" }
			s += " COLLATE \(co)"
		}
		if let g = generated { s += " GENERATED ALWAYS AS (\(generationExpr)) \(g)" }
		s += nullable ? " NULL" : " NOT NULL"
		if let d = defaultValue, !autoIncrement, generated == nil { s += " DEFAULT " + Self.defaultSQL(d, expr: defaultExpr, numeric: isNumeric) }
		if !onUpdate.isEmpty { s += " " + onUpdate }
		if autoIncrement { s += " AUTO_INCREMENT" }
		if !comment.isEmpty { s += " COMMENT " + literal(.text(comment)) }
		return s
	}

	/// 기본값 SQL: NULL·CURRENT_TIMESTAMP·NOW() 는 그대로, 숫자 종류의 숫자도 그대로, 이미 '…' 로 감쌌으면 그대로, 나머지는 따옴표.
	/// 서버가 식이라고 알려 준 기본값은 (식) 으로
	static func defaultSQL(_ d: String, expr: Bool, numeric: Bool) -> String {
		let t = d.trimmingCharacters(in: .whitespaces)
		let up = t.uppercased()
		if up == "NULL" { return "NULL" }
		if up.hasPrefix("CURRENT_TIMESTAMP") || up.hasPrefix("NOW(") || up.hasPrefix("LOCALTIME") { return t }
		if expr { return t.hasPrefix("(") ? t : "(\(t))" }
		if numeric, Double(t) != nil { return t }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return t }
		return literal(.text(d))
	}

	/// information_schema.COLUMNS 한 줄에서
	init(row r: QueryResult, _ i: Int) {
		func s(_ n: String) -> String? { r.string(i, n) }
		name = s("COLUMN_NAME") ?? ""
		type = (s("DATA_TYPE") ?? "").uppercased()
		let full = s("COLUMN_TYPE") ?? ""
		if let open = full.firstIndex(of: "("), let close = full.lastIndex(of: ")"), open < close {
			length = String(full[full.index(after: open)..<close])
		} else {
			length = ""
		}
		let low = full.lowercased()
		unsigned = low.contains(" unsigned")
		zerofill = low.contains(" zerofill")
		nullable = s("IS_NULLABLE") == "YES"
		defaultValue = s("COLUMN_DEFAULT")
		let extra = s("EXTRA") ?? ""
		let lowExtra = extra.lowercased()
		defaultExpr = lowExtra.contains("default_generated")
		autoIncrement = lowExtra.contains("auto_increment")
		if let r = lowExtra.range(of: "on update") { onUpdate = String(extra[r.lowerBound...]) }
		if lowExtra.contains("virtual generated") { generated = "VIRTUAL" } else if lowExtra.contains("stored generated") { generated = "STORED" }
		generationExpr = s("GENERATION_EXPRESSION") ?? ""
		comment = s("COLUMN_COMMENT") ?? ""
		charset = s("CHARACTER_SET_NAME")
		collation = s("COLLATION_NAME")
		key = s("COLUMN_KEY") ?? ""
	}

	/// 캐시된 구조(ColumnInfo)로 만든 임시 (자세한 걸 읽기 전에 보여 주기)
	init(info c: ColumnInfo) {
		name = c.name
		let full = c.type
		let base = full.split(separator: "(").first.map { String($0) } ?? full
		type = base.split(separator: " ").first.map { $0.uppercased() } ?? full.uppercased()
		if let open = full.firstIndex(of: "("), let close = full.lastIndex(of: ")"), open < close {
			length = String(full[full.index(after: open)..<close])
		} else {
			length = ""
		}
		unsigned = full.lowercased().contains(" unsigned")
		nullable = c.nullable
		defaultValue = c.defaultValue
		autoIncrement = c.extra.lowercased().contains("auto_increment")
		comment = c.comment
		key = c.key
	}

	init() {}
}

/// 구조 화면 편집: 바꾼 것을 모았다가 ALTER TABLE 하나로 반영한다.
/// 줄 순서 = 반영 뒤 컬럼 순서. 지운 줄은 빨간 줄로 남는다. 공용 표(TableGrid)의 공급자
@Observable
final class StructureEditor: GridSource {
	struct Row: Identifiable {
		let id = UUID()
		var col: StructColumn
		/// 서버에 있는 컬럼이면 읽어 온 정의 (새 줄은 nil)
		let original: StructColumn?
		var deleted = false
		var isNew: Bool { original == nil }
	}

	let table: TableInfo
	@ObservationIgnored private weak var session: Session?
	/// 저장 안 됨 표시를 알릴 곳 (TableData)
	@ObservationIgnored var onChange: (() -> Void)?

	private(set) var rows: [Row] = []
	/// 서버에서 읽은 그대로 (되돌리기·순서 비교)
	@ObservationIgnored private var originals: [StructColumn] = []
	/// SHOW CREATE TABLE 의 컬럼 줄 (이름 → 이름 뒤 정의). 이름·순서만 바뀐 컬럼은 이걸 그대로 써서 속성을 잃지 않는다
	@ObservationIgnored private var rawDefinitions: [String: String] = [:]
	/// 자세한 정의를 읽었는지 (그 전에는 고칠 수 없다)
	private(set) var loaded = false
	private(set) var loading = false
	private(set) var saving = false
	var saveError: String?
	var showSQL = false
	private(set) var gridVersion = 0
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	/// 표에게 편집을 시작해 달라는 요청 (컬럼 추가 뒤 이름 칸)
	@ObservationIgnored private var editRequest: (row: Int, col: Int)?

	init(table: TableInfo, session: Session, columns: [ColumnInfo]) {
		self.table = table
		self.session = session
		originals = columns.map { StructColumn(info: $0) }
		rows = originals.map { Row(col: $0, original: $0) }
	}

	// MARK: 읽기

	@MainActor
	func load() async {
		guard let session, !loading else { return }
		loading = true
		defer { loading = false }
		do {
			let rs = try await session.query("""
				SELECT * FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(literal(.text(table.schema))) AND TABLE_NAME = \(literal(.text(table.name))) ORDER BY ORDINAL_POSITION;
				SHOW CREATE TABLE \(table.quoted)
				""")
			guard let cols = rs.first else { return }
			let list = cols.rows.indices.map { StructColumn(row: cols, $0) }
			guard !list.isEmpty else { return }
			rawDefinitions = Self.parseCreate(rs.last?.rows.first?[safe: 1]?.string ?? "")
			originals = list
			rows = list.map { Row(col: $0, original: $0) }
			loaded = true
			saveError = nil
			changed()
		} catch {
			saveError = error.localizedDescription
		}
	}

	/// "  `name` int unsigned NOT NULL," 줄들에서 이름 → 정의
	static func parseCreate(_ ddl: String) -> [String: String] {
		var out: [String: String] = [:]
		for line in ddl.split(separator: "\n") {
			let t = line.drop { $0 == " " }
			guard t.first == "`" else { continue }
			var name = ""
			var i = t.index(after: t.startIndex)
			var closed = false
			while i < t.endIndex {
				let ch = t[i]
				if ch == "`" {
					let next = t.index(after: i)
					if next < t.endIndex, t[next] == "`" { name.append("`"); i = t.index(after: next); continue }
					i = next; closed = true; break
				}
				name.append(ch)
				i = t.index(after: i)
			}
			guard closed else { continue }
			var rest = t[i...].trimmingCharacters(in: .whitespaces)
			if rest.hasSuffix(",") { rest.removeLast() }
			out[name] = rest
		}
		return out
	}

	// MARK: 바뀐 것

	private func changed() {
		gridVersion += 1
		onChange?()
	}

	/// 원래 순서 (서버에 있던 컬럼 이름)
	private var originalOrder: [String] { originals.map(\.name) }

	var hasChanges: Bool { !clauses.isEmpty }
	var changeCount: Int { clauses.count }

	/// ALTER TABLE 의 절들 (지우기 먼저, 그다음 최종 순서대로 바꾸기·추가).
	/// MySQL 은 CHANGE 의 앞 이름을 원래 컬럼 이름으로 찾고, AFTER 는 새 이름으로 찾으며, 위치는 절 순서대로 놓는다.
	/// 그래서 이름을 서로 바꿔도(test→test5, hello→test) 꼬이지 않는다
	private var clauses: [String] {
		var out: [String] = []
		for r in rows where r.deleted { if let o = r.original { out.append("DROP COLUMN \(quoteName(o.name))") } }
		let final = rows.filter { !$0.deleted }
		// 그대로 둘 컬럼: 원래 순서를 지키는 가장 긴 줄 (나머지만 옮긴다)
		let survivors = final.compactMap(\.original?.name)
		let originalIndex = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1, $0) })
		let stay = Self.longestIncreasing(survivors.map { originalIndex[$0] ?? 0 }).map { survivors[$0] }
		let staySet = Set(stay)
		for (i, r) in final.enumerated() {
			let pos = i == 0 ? " FIRST" : " AFTER \(quoteName(final[i - 1].col.name))"
			guard let o = r.original else {
				out.append("ADD COLUMN \(quoteName(r.col.name)) \(r.col.definition)\(pos)")
				continue
			}
			let moved = !staySet.contains(o.name)
			let sameDef = r.col.sameDefinition(o)
			guard moved || !sameDef || r.col.name != o.name else { continue }
			let def = sameDef ? (rawDefinitions[o.name] ?? r.col.definition) : r.col.definition
			out.append("CHANGE COLUMN \(quoteName(o.name)) \(quoteName(r.col.name)) \(def)\(moved ? pos : "")")
		}
		return out
	}

	/// 가장 긴 증가 부분열의 위치들
	static func longestIncreasing(_ a: [Int]) -> [Int] {
		guard !a.isEmpty else { return [] }
		var len = [Int](repeating: 1, count: a.count), prev = [Int](repeating: -1, count: a.count)
		for i in a.indices {
			for j in 0..<i where a[j] < a[i] && len[j] + 1 > len[i] { len[i] = len[j] + 1; prev[i] = j }
		}
		var i = len.indices.max { len[$0] < len[$1] }!
		var out: [Int] = []
		while i >= 0 { out.append(i); i = prev[i] }
		return out.reversed()
	}

	var alterSQL: String? {
		let c = clauses
		guard !c.isEmpty else { return nil }
		return "ALTER TABLE \(table.quoted)\n  " + c.joined(separator: ",\n  ")
	}

	/// 저장 전에 막을 문제
	var problem: String? {
		let final = rows.filter { !$0.deleted }
		if final.isEmpty { return "컬럼을 모두 지울 수는 없습니다" }
		if final.contains(where: { $0.col.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "이름이 없는 컬럼이 있습니다" }
		var seen = Set<String>()
		for r in final where !seen.insert(r.col.name.lowercased()).inserted { return "컬럼 이름 \(r.col.name) 이(가) 겹칩니다" }
		if let r = final.first(where: { NewColumn.needsLength.contains($0.col.type) && $0.col.length.trimmingCharacters(in: .whitespaces).isEmpty }) {
			return "\(r.col.name) (\(r.col.type)) 은(는) 길이·값이 필요합니다"
		}
		return nil
	}

	func discard() {
		rows = originals.map { Row(col: $0, original: $0) }
		saveError = nil
		changed()
	}

	@MainActor
	func save() async {
		guard let session, let sql = alterSQL, !saving else { return }
		if let p = problem { saveError = p; return }
		saving = true
		defer { saving = false }
		saveError = nil
		do {
			_ = try await session.query(sql)
		} catch {
			saveError = error.localizedDescription
			return
		}
		try? await session.loadSchema()
		await load()
		// 테이블 정보 패널의 인덱스 목록도 (이름을 바꾼 컬럼, 지운 컬럼)
		await session.reloadInspector(table)
	}

	// MARK: 줄 고치기

	func addColumn(after row: Int?) {
		guard loaded else { NSSound.beep(); return }
		var c = StructColumn()
		c.nullable = false
		let at = row.map { min($0 + 1, rows.count) } ?? rows.count
		rows.insert(Row(col: c, original: nil), at: at)
		editRequest = (at, 0)
		changed()
	}

	func move(_ from: IndexSet, to: Int) {
		guard loaded, !from.isEmpty else { return }
		let moving = from.map { rows[$0] }
		var rest = rows
		for i in from.sorted(by: >) { rest.remove(at: i) }
		let at = to - from.filter { $0 < to }.count
		rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
		rows = rest
		changed()
	}

	func moveRows(_ from: IndexSet, to: Int) { move(from, to: to) }

	func moveUp(_ row: Int) { if row > 0 { move([row], to: row - 1) } }
	func moveDown(_ row: Int) { if row < rows.count - 1 { move([row], to: row + 2) } }

	private func update(_ row: Int, _ f: (inout StructColumn) -> Void) {
		guard rows.indices.contains(row), !rows[row].deleted else { return }
		f(&rows[row].col)
		changed()
	}

	func revert(_ row: Int) {
		guard let o = rows[row].original else { return }
		rows[row].col = o
		rows[row].deleted = false
		changed()
	}

	func takeEditRequest() -> (row: Int, col: Int)? {
		defer { editRequest = nil }
		return editRequest
	}

	// MARK: 표

	var gridID: String { "structure:" + table.id }

	@ObservationIgnored let gridColumns: [GridColumn] = [
		GridColumn(key: "name", title: "컬럼", mono: true, width: 200),
		GridColumn(key: "comment", title: "코멘트", width: 220),
		GridColumn(key: "type", title: "타입", mono: true, width: 120),
		GridColumn(key: "length", title: "길이·값", mono: true, width: 110),
		GridColumn(key: "unsigned", title: "UNSIGNED", center: true, width: 80),
		GridColumn(key: "null", title: "NULL", center: true, width: 50),
		GridColumn(key: "default", title: "기본값", width: 140),
		GridColumn(key: "extra", title: "기타", width: 200),
	]

	var rowCount: Int { rows.count }
	var canEdit: Bool { loaded && !table.isView }
	var sortable: Bool { false }
	var canMoveRows: Bool { canEdit }

	private static let keyIcons: [String: NSImage] = {
		func icon(_ name: String, _ color: NSColor) -> NSImage? {
			NSImage(systemSymbolName: name, accessibilityDescription: nil)?
				.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color])))
		}
		var d: [String: NSImage] = [:]
		d["PRI"] = icon("key.fill", .systemYellow)
		d["UNI"] = icon("key", .secondaryLabelColor)
		d["MUL"] = icon("line.3.horizontal.decrease", .secondaryLabelColor)
		return d
	}()

	private func extraText(_ c: StructColumn) -> String {
		var parts: [String] = []
		if c.autoIncrement { parts.append("auto_increment") }
		if let g = c.generated { parts.append("\(g) GENERATED") }
		if !c.onUpdate.isEmpty { parts.append(c.onUpdate) }
		return parts.joined(separator: " ")
	}

	/// 칸 글자 (고쳤는지 비교에도 쓴다)
	private func text(_ c: StructColumn, _ key: String) -> String? {
		switch key {
		case "name": c.name
		case "comment": c.comment
		case "type": c.type
		case "length": c.length
		case "unsigned": c.isNumeric ? (c.unsigned ? "예" : "") : ""
		case "null": c.nullable ? "예" : ""
		case "default": c.defaultValue ?? (c.nullable ? nil : "")
		default: extraText(c)
		}
	}

	func cell(_ row: Int, _ col: Int) -> GridCell {
		let r = rows[row]
		let key = gridColumns[col].key
		let t = text(r.col, key)
		var state: GridCellState = .clean
		if r.deleted { state = .deleted } else if r.isNew { state = .inserted } else if let o = r.original, text(o, key) != t { state = .edited }
		var cell = GridCell(text: t, state: state)
		switch key {
		case "name": cell.icon = Self.keyIcons[r.col.key]
		case "type", "extra": cell.dim = state == .clean
		case "default": cell.dim = r.col.defaultValue == nil || r.col.defaultExpr
		default: break
		}
		return cell
	}

	func isEditable(_ row: Int, _ col: Int) -> Bool {
		let c = rows[row].col
		switch gridColumns[col].key {
		case "length": return c.takesLength
		case "unsigned": return c.isNumeric
		case "default": return !c.autoIncrement && c.generated == nil
		case "extra": return c.generated == nil
		default: return true
		}
	}

	/// 두 번 누르면 글자 대신 고르기 메뉴가 나오는 칸 (nil = 구분선)
	func choices(_ row: Int, _ col: Int) -> [String?]? {
		let c = rows[row].col
		switch gridColumns[col].key {
		case "type":
			var list = NewColumn.typeOptions
			if !list.contains(c.type) { list = [c.type, nil] + list }
			return list
		case "unsigned", "null": return ["예", "아니오"]
		case "extra":
			var l: [String?] = ["없음"]
			if c.isNumeric { l.append("auto_increment") }
			if ["DATETIME", "TIMESTAMP"].contains(c.type) { l.append("on update CURRENT_TIMESTAMP") }
			return l
		default: return nil
		}
	}

	/// 고르기 메뉴에서 체크할 항목
	func currentChoice(_ row: Int, _ col: Int) -> String? {
		let c = rows[row].col
		switch gridColumns[col].key {
		case "type": return c.type
		case "unsigned": return c.unsigned ? "예" : "아니오"
		case "null": return c.nullable ? "예" : "아니오"
		case "extra": return c.autoIncrement ? "auto_increment" : (!c.onUpdate.isEmpty ? "on update CURRENT_TIMESTAMP" : "없음")
		default: return nil
		}
	}

	func setText(_ row: Int, _ col: Int, _ raw: String) {
		// 입력이 끝나면 앞뒤 공백·줄바꿈을 뺀다 (기본값을 빈 글자로 두려면 '' 로 적는다)
		let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
		switch gridColumns[col].key {
		case "name":
			guard !text.isEmpty else { NSSound.beep(); return }
			update(row) { $0.name = text }
		case "comment": update(row) { $0.comment = text }
		case "length": update(row) { $0.length = text }
		case "default": update(row) { $0.defaultValue = text; $0.defaultExpr = false }
		case "type":
			update(row) { c in
				guard c.type != text else { return }
				c.type = text
				c.length = NewColumn.defaultLength(text)
				if !c.isNumeric { c.unsigned = false; c.zerofill = false; c.autoIncrement = false }
				if !StructColumn.textTypes.contains(text) { c.charset = nil; c.collation = nil }
				if !["DATETIME", "TIMESTAMP"].contains(text) { c.onUpdate = "" }
			}
		case "unsigned": update(row) { $0.unsigned = text == "예" }
		case "null": update(row) { $0.nullable = text == "예" }
		case "extra":
			update(row) { c in
				c.autoIncrement = text == "auto_increment"
				c.onUpdate = text.hasPrefix("on update") ? "on update CURRENT_TIMESTAMP" : ""
				if c.autoIncrement { c.defaultValue = nil }
			}
		default: break
		}
	}

	func deleteRows(_ sel: IndexSet) -> Bool {
		guard canEdit else { return false }
		// 새 줄은 바로 빼고, 있던 줄은 지울 표시를 켜고 끈다
		let turnOn = sel.contains { !rows[$0].deleted }
		for i in sel.sorted(by: >) {
			if rows[i].isNew { rows.remove(at: i) } else { rows[i].deleted = turnOn }
		}
		changed()
		return true
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		guard canEdit else { return [] }
		var items: [GridMenuItem] = [
			.action("아래에 컬럼 추가") { self.addColumn(after: row) },
			.separator,
			row > 0 ? .action("위로 옮기기") { self.moveUp(row) } : .disabled("위로 옮기기"),
			row < rows.count - 1 ? .action("아래로 옮기기") { self.moveDown(row) } : .disabled("아래로 옮기기"),
		]
		if let col, gridColumns[col].key == "default", rows[row].col.defaultValue != nil, isEditable(row, col) {
			items += [.separator, .action("기본값 없애기") { self.update(row) { $0.defaultValue = nil; $0.defaultExpr = false } }]
		}
		if let o = rows[row].original, rows[row].col != o || rows[row].deleted {
			items += [.separator, .action("원래대로") { self.revert(row) }]
		}
		items += [.separator, .action(rows[row].deleted ? "삭제 취소" : "컬럼 삭제") { _ = self.deleteRows(selection.isEmpty ? [row] : selection) }]
		return items
	}
}
