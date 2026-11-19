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

	/// 이름 뒤에 오는 정의 (서버 문법으로)
	func definition(_ dialect: any SQLDialect) -> String { dialect.columnDefinition(self) }

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
	/// 이 서버 종류에 있는 기능 (열 때 정한다)
	@ObservationIgnored private let caps: SQLCapabilities
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	private var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }
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
		caps = session.capabilities
		gridColumns = Self.columns(caps)
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
			guard let (list, definitions) = try await session.meta.structure(session.query, table) else { return }
			rawDefinitions = definitions
			originals = list
			rows = list.map { Row(col: $0, original: $0) }
			loaded = true
			saveError = nil
			changed()
		} catch {
			saveError = error.localizedDescription
		}
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
		for r in rows where r.deleted { if let o = r.original { out.append(dialect.dropColumn(o.name)) } }
		let final = rows.filter { !$0.deleted }
		// 그대로 둘 컬럼: 원래 순서를 지키는 가장 긴 줄 (나머지만 옮긴다)
		let survivors = final.compactMap(\.original?.name)
		let originalIndex = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1, $0) })
		let stay = Self.longestIncreasing(survivors.map { originalIndex[$0] ?? 0 }).map { survivors[$0] }
		let staySet = Set(stay)
		for (i, r) in final.enumerated() {
			let pos: ColumnPosition = i == 0 ? .first : .after(final[i - 1].col.name)
			guard let o = r.original else {
				out.append(dialect.addColumn(r.col.name, definition: r.col.definition(dialect), position: pos))
				continue
			}
			let moved = !staySet.contains(o.name)
			let sameDef = r.col.sameDefinition(o)
			guard moved || !sameDef || r.col.name != o.name else { continue }
			let def = sameDef ? (rawDefinitions[o.name] ?? r.col.definition(dialect)) : r.col.definition(dialect)
			out.append(dialect.changeColumn(o.name, to: r.col.name, definition: def, position: moved ? pos : nil))
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
		if needsRebuild { return rebuildPreview }
		return dialect.alterTable(dialect.quote(table: table), c, multiline: true)
	}

	/// SQL 미리보기 제목
	var previewTitle: String { needsRebuild ? "SQLite 는 테이블을 새로 만들어 옮깁니다 (한 트랜잭션)" : "저장하면 ALTER TABLE 하나로 실행됩니다" }

	/// 저장 전에 막을 문제
	var problem: String? {
		let final = rows.filter { !$0.deleted }
		if final.isEmpty { return "컬럼을 모두 삭제할 수는 없습니다" }
		if final.contains(where: { $0.col.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "이름이 없는 컬럼이 있습니다" }
		var seen = Set<String>()
		for r in final where !seen.insert(r.col.name.lowercased()).inserted { return "컬럼 이름 \(r.col.name) 이(가) 겹칩니다" }
		if let r = final.first(where: { NewColumn.needsLength.contains($0.col.type) && $0.col.length.trimmingCharacters(in: .whitespaces).isEmpty }) {
			return "\(r.col.name) (\(r.col.type)) 은(는) 길이·값이 필요합니다"
		}
		return nil
	}

	/// SQLite 의 ALTER 는 컬럼 더하기(맨 뒤)·이름 바꾸기·지우기만 된다 → 정의·순서를 바꾸거나 중간에 더하면 테이블을 새로 만들어 옮긴다
	/// (사용자 2026-11-19: 예전엔 막았다)
	var needsRebuild: Bool {
		guard dialect.kind == .sqlite else { return false }
		let final = rows.filter { !$0.deleted }
		if final.contains(where: { r in r.original.map { !r.col.sameDefinition($0) } ?? false }) { return true }
		let index = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1, $0) })
		let kept = final.compactMap { $0.original.flatMap { index[$0.name] } }
		if kept != kept.sorted() { return true }
		if let last = final.lastIndex(where: { $0.original != nil }), final[..<last].contains(where: { $0.original == nil }) { return true }
		return false
	}

	/// 새로 만들 테이블의 컬럼 정의 (raw = 지금 CREATE 의 컬럼 정의, 이름 → 정의). 정의가 같으면 그대로, 바뀌면 편집기 값 + 원래 키·제약
	private func rebuildDefinitions(_ raw: [String: String]) -> (defs: [String], copy: [String]) {
		let d = dialect
		var defs: [String] = [], copy: [String] = []
		for r in rows where !r.deleted {
			let n = r.col.name
			if let o = r.original {
				let base = raw[n] ?? raw[o.name]
				let def = r.col.sameDefinition(o) ? (base ?? r.col.definition(d)) : r.col.definition(d) + SQLiteMeta.keptColumnConstraints(base ?? "")
				defs.append(d.quote(n) + " " + def)
				// 계산 컬럼은 값을 넣을 수 없다
				if o.generated == nil && r.col.generated == nil { copy.append(d.quote(n)) }
			} else {
				defs.append(d.quote(n) + " " + r.col.definition(d))
			}
		}
		return (defs, copy)
	}

	private var rebuildTemp: String { "__isql_new_" + table.name }

	/// 미리보기 (표 제약·인덱스·트리거는 저장할 때 읽어서 다시 만든다)
	private var rebuildPreview: String {
		let d = dialect, t = d.quote(table.name), tmp = d.quote(rebuildTemp)
		var out = ["-- SQLite 는 컬럼 정의·순서를 바꾸려면 테이블을 새로 만들어 데이터를 옮깁니다", "PRAGMA foreign_keys = OFF", "BEGIN"]
		for r in rows where !r.deleted { if let o = r.original, o.name != r.col.name { out.append("ALTER TABLE \(t) RENAME COLUMN \(d.quote(o.name)) TO \(d.quote(r.col.name))") } }
		var raw: [String: String] = [:]
		for r in rows where !r.deleted { if let o = r.original, let def = rawDefinitions[o.name] { raw[r.col.name] = def } }
		let (defs, copy) = rebuildDefinitions(raw)
		out.append("CREATE TABLE \(tmp) (\n  " + (defs + ["-- (원래 표 제약)"]).joined(separator: ",\n  ") + "\n)")
		out.append("INSERT INTO \(tmp) (\(copy.joined(separator: ", "))) SELECT \(copy.joined(separator: ", ")) FROM \(t)")
		out.append("DROP TABLE \(t)")
		out.append("ALTER TABLE \(tmp) RENAME TO \(t)")
		out.append("-- 원래 인덱스·트리거를 다시 만들고, 외래 키를 확인합니다 (PRAGMA foreign_key_check)")
		out.append("COMMIT")
		out.append("PRAGMA foreign_keys = ON")
		return out.joined(separator: ";\n")
	}

	/// SQLite 테이블 다시 만들기 (SQLite 문서의 순서). 한 트랜잭션, 실패하면 모두 되돌린다
	@MainActor
	private func rebuildSQLite(_ session: Session) async throws {
		let d = dialect, t = table.name, qt = d.quote(table.name), tmp = d.quote(rebuildTemp)
		func lit(_ v: String) -> String { d.literal(.text(v)) }
		func strings(_ sql: String) async throws -> [String] { (try await session.query(sql)).last?.rows.compactMap { $0.first?.string } ?? [] }
		let fkWasOn = (try await strings("PRAGMA foreign_keys")).first == "1"
		let legacyWasOn = (try await strings("PRAGMA legacy_alter_table")).first == "1"
		if fkWasOn { _ = try await session.query("PRAGMA foreign_keys = OFF") }
		_ = try await session.query("BEGIN")
		do {
			// 1. 이름 바꾸기는 SQLite 의 ALTER 로 먼저 (인덱스·트리거·뷰 안의 이름도 SQLite 가 바꿔 준다).
			//    삭제할 컬럼은 새 테이블에 넣지 않는다 (DROP COLUMN 은 UNIQUE·기본 키 컬럼을 못 지운다)
			let renames = rows.filter { !$0.deleted }.compactMap { r in r.original.flatMap { $0.name != r.col.name ? ($0.name, r.col.name) : nil } }
			let existing = Set(rows.compactMap { $0.original?.name.lowercased() })
			// 이름을 서로 맞바꾸면 겹치니 잠깐 다른 이름을 거친다
			if renames.contains(where: { existing.contains($0.1.lowercased()) && $0.1.lowercased() != $0.0.lowercased() }) {
				for (i, rn) in renames.enumerated() { _ = try await session.query("ALTER TABLE \(qt) RENAME COLUMN \(d.quote(rn.0)) TO \(d.quote("__isql_tmp_\(i)"))") }
				for (i, rn) in renames.enumerated() { _ = try await session.query("ALTER TABLE \(qt) RENAME COLUMN \(d.quote("__isql_tmp_\(i)")) TO \(d.quote(rn.1))") }
			} else {
				for rn in renames { _ = try await session.query("ALTER TABLE \(qt) RENAME COLUMN \(d.quote(rn.0)) TO \(d.quote(rn.1))") }
			}
			// 2. 지금 정의·인덱스·트리거
			guard let create = try await strings("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = \(lit(t))").first else {
				throw DBError.message("테이블 정의를 읽지 못했습니다")
			}
			let indexes = try await strings("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = \(lit(t)) AND sql IS NOT NULL")
			let triggers = try await strings("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = \(lit(t))")
			let seq = create.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil
				? (try? await strings("SELECT seq FROM sqlite_sequence WHERE name = \(lit(t))"))?.first : nil
			// 3. 새 테이블 → 옮기기 → 옛 테이블 삭제 → 이름 바꾸기
			let (defs, copy) = rebuildDefinitions(SQLiteMeta.parseCreate(create))
			let options = SQLiteMeta.tableOptions(create)
			_ = try await session.query("CREATE TABLE \(tmp) (\n  " + (defs + SQLiteMeta.tableConstraints(create)).joined(separator: ",\n  ") + "\n)" + (options.isEmpty ? "" : " " + options))
			if !copy.isEmpty {
				_ = try await session.query("INSERT INTO \(tmp) (\(copy.joined(separator: ", "))) SELECT \(copy.joined(separator: ", ")) FROM \(qt)")
			}
			_ = try await session.query("DROP TABLE \(qt)")
			// 이름을 바꿀 때 다른 뷰·트리거가 옛 테이블을 가리켜도 막히지 않게 (SQLite 문서 권장)
			if !legacyWasOn { _ = try await session.query("PRAGMA legacy_alter_table = ON") }
			_ = try await session.query("ALTER TABLE \(tmp) RENAME TO \(qt)")
			if !legacyWasOn { _ = try await session.query("PRAGMA legacy_alter_table = OFF") }
			// 4. 인덱스·트리거 다시, AUTOINCREMENT 다음 값 지키기, 외래 키 확인
			for sql in indexes + triggers { _ = try await session.query(sql) }
			if let seq, Int64(seq) != nil {
				_ = try await session.query("UPDATE sqlite_sequence SET seq = MAX(seq, \(seq)) WHERE name = \(lit(t))")
				_ = try await session.query("INSERT INTO sqlite_sequence (name, seq) SELECT \(lit(t)), \(seq) WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = \(lit(t)))")
			}
			if fkWasOn, let bad = (try await session.query("PRAGMA foreign_key_check(\(qt))")).last, !bad.rows.isEmpty {
				throw DBError.message("외래 키가 맞지 않는 행이 \(bad.rows.count)개 생겨 되돌렸습니다")
			}
			_ = try await session.query("COMMIT")
		} catch {
			_ = try? await session.query("ROLLBACK")
			if !legacyWasOn { _ = try? await session.query("PRAGMA legacy_alter_table = OFF") }
			if fkWasOn { _ = try? await session.query("PRAGMA foreign_keys = ON") }
			throw error
		}
		if fkWasOn { _ = try await session.query("PRAGMA foreign_keys = ON") }
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
			if needsRebuild { try await rebuildSQLite(session) } else { _ = try await session.query(sql) }
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

	/// 같은 정의로 바로 아래에 (이름은 _copy, 키·자동 증가는 빼고 — 테이블에 자동 증가는 하나뿐). 이름 칸을 바로 고친다
	func duplicateColumn(_ row: Int) {
		guard loaded, rows.indices.contains(row) else { NSSound.beep(); return }
		var c = rows[row].col
		let names = Set(rows.map { $0.col.name.lowercased() })
		var name = c.name + "_copy", k = 2
		while names.contains(name.lowercased()) { name = c.name + "_copy\(k)"; k += 1 }
		c.name = name
		c.key = ""
		c.autoIncrement = false
		rows.insert(Row(col: c, original: nil), at: row + 1)
		editRequest = (row + 1, 0)
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

	/// 표 컬럼 (코멘트·UNSIGNED 가 없는 서버 종류면 그 칸을 뺀다)
	@ObservationIgnored let gridColumns: [GridColumn]

	private static func columns(_ caps: SQLCapabilities) -> [GridColumn] {
		[GridColumn(key: "name", title: "컬럼", mono: true, width: 200)]
		+ (caps.columnComment ? [GridColumn(key: "comment", title: "코멘트", width: 220)] : [])
		+ [GridColumn(key: "type", title: "타입", mono: true, width: 120),
		   GridColumn(key: "length", title: "길이·값", mono: true, width: 110)]
		+ (caps.unsignedColumns ? [GridColumn(key: "unsigned", title: "UNSIGNED", center: true, width: 80)] : [])
		+ [GridColumn(key: "null", title: "NULL", center: true, width: 50),
		   GridColumn(key: "default", title: "기본값", width: 140),
		   GridColumn(key: "extra", title: "기타", width: 200)]
	}

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
		// 예/아니오는 체크박스 (UNSIGNED 는 숫자 종류일 때만)
		case "unsigned": if r.col.isNumeric { cell.check = r.col.unsigned }
		case "null": cell.check = r.col.nullable
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
		case "null": return c.key != "PRI"   // 기본 키는 NULL 을 못 받는다
		case "default": return !c.autoIncrement && c.generated == nil
		case "extra": return c.generated == nil
		default: return true
		}
	}

	/// Tab 으로 들르는 칸: 글자 칸 + 타입(고르기 메뉴가 뜨고, 고르면 다음 칸으로). 예/아니오 칸은 건너뛴다
	func tabStop(_ row: Int, _ col: Int) -> Bool {
		guard isEditable(row, col) else { return false }
		let key = gridColumns[col].key
		if key == "unsigned" || key == "null" { return false }   // 체크박스는 Tab 에서 건너뜀
		return key == "type" || choices(row, col) == nil
	}

	/// 두 번 누르면 글자 대신 고르기 메뉴가 나오는 칸 (nil = 구분선)
	func choices(_ row: Int, _ col: Int) -> [String?]? {
		let c = rows[row].col
		switch gridColumns[col].key {
		case "type":
			var list = NewColumn.typeOptions
			if !list.contains(c.type) { list = [c.type, nil] + list }
			return list
		case "extra":
			var l: [String?] = ["없음"]
			if c.isNumeric { l.append("auto_increment") }
			if caps.onUpdateTimestamp && ["DATETIME", "TIMESTAMP"].contains(c.type) { l.append("on update CURRENT_TIMESTAMP") }
			return l
		default: return nil
		}
	}

	/// 고르기 메뉴에서 체크할 항목
	func currentChoice(_ row: Int, _ col: Int) -> String? {
		let c = rows[row].col
		switch gridColumns[col].key {
		case "type": return c.type
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

	/// − 버튼: 고른 줄을 지우기로 표시 (새 줄은 바로 뺀다). 이미 지울 표시인 줄은 그대로
	func markDeleted(_ sel: IndexSet) {
		guard canEdit else { return }
		for i in sel.sorted(by: >) where rows.indices.contains(i) {
			if rows[i].isNew { rows.remove(at: i) } else { rows[i].deleted = true }
		}
		changed()
	}

	/// 고른 줄 중에 아직 지울 표시가 안 된 것이 있는지 (− 버튼 켜기)
	func canMarkDeleted(_ sel: IndexSet) -> Bool {
		canEdit && sel.contains { rows.indices.contains($0) && !rows[$0].deleted }
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
			.action("컬럼 복제") { self.duplicateColumn(row) },
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
