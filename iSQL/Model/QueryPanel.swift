import Foundation
import AppKit
import Observation

/// 서버마다 하나인 쿼리 패널. 입력한 쿼리는 직접 지우기 전까지 남는다 (앱을 다시 켜도, UserDefaults "query.<서버id>").
/// 실행한 쿼리 기록은 따로 남기지 않는다 (사용자 결정 2026-11-15)
@Observable
final class QueryPanel {
	@ObservationIgnored private weak var session: Session?
	@ObservationIgnored private let serverID: UUID?

	var open = false
	var height: CGFloat = {
		let h = UserDefaults.standard.double(forKey: "queryPanelHeight")
		return h >= 80 ? h : 170
	}() {
		didSet { UserDefaults.standard.set(Double(height), forKey: "queryPanelHeight") }
	}
	var text: String { didSet { scheduleSave() } }
	/// 쿼리를 돌릴 기본 DB (USE)
	var database = ""

	private(set) var running = false
	private(set) var outputs: [QueryOutput] = []
	var selectedOutput = 0
	/// SELECT 결과가 탭 영역을 덮고 있는지 (×로 걷어도 패널은 열려 있다)
	var showResults = false
	private(set) var message: String?
	private(set) var isError = false

	/// 입력창에서 선택한 범위 (UTF-16, 실행할 부분을 고르려고)
	@ObservationIgnored var selection = NSRange(location: 0, length: 0)

	var resultsVisible: Bool { open && showResults && !outputs.isEmpty }

	init(session: Session, serverID: UUID?) {
		self.session = session
		self.serverID = serverID
		text = serverID.flatMap { UserDefaults.standard.string(forKey: "query.\($0.uuidString)") } ?? ""
	}

	// MARK: - 내용 저장 (입력이 멈추면 0.5초 뒤)

	@ObservationIgnored private var saveWork: DispatchWorkItem?

	private func scheduleSave() {
		guard let id = serverID else { return }
		saveWork?.cancel()
		let t = text
		let w = DispatchWorkItem { UserDefaults.standard.set(t, forKey: "query.\(id.uuidString)") }
		saveWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
	}

	// MARK: - 실행할 문장 고르기

	/// 선택한 부분이 있으면 그 부분의 문장들, 없으면 커서가 있는 문장 하나
	func statementsToRun(all: Bool) -> [String] {
		if all { return SQLSplitter.split(text).map(\.text) }
		let ns = text as NSString
		if selection.length > 0, NSMaxRange(selection) <= ns.length {
			return SQLSplitter.split(ns.substring(with: selection)).map(\.text)
		}
		let parts = SQLSplitter.split(text)
		let cursor = min(selection.location, ns.length)
		// 커서가 들어 있는 문장, 없으면 커서 바로 앞 문장 (줄 끝에서 ⌘↩ 하는 경우)
		if let p = parts.first(where: { $0.range.location <= cursor && cursor <= NSMaxRange($0.range) }) { return [p.text] }
		if let p = parts.last(where: { NSMaxRange($0.range) <= cursor }) { return [p.text] }
		return parts.first.map { [$0.text] } ?? []
	}

	// MARK: - 실행

	@MainActor
	func run(_ statements: [String]) async {
		guard let session, !statements.isEmpty, !running else { return }
		running = true
		message = nil
		isError = false
		let start = Date()
		var outs: [QueryOutput] = []
		var affected: UInt64 = 0
		var changes = 0
		var touched: [String] = []
		defer { running = false }
		do {
			if !database.isEmpty, database != session.currentDB {
				_ = try await session.query("USE \(quoteName(database))")
				session.currentDB = database
			}
			for st in statements {
				// LIMIT 없는 SELECT 는 한 쪽 행 수만큼만 (쪽을 넘기면 다시 실행)
				let paged = SQLSplitter.canAutoLimit(st)
				let size = QueryOutput.currentPageSize
				let sql = paged ? "\(st) LIMIT \(size + 1)" : st
				for r in try await session.query(sql) {
					if r.isResultSet {
						outs.append(QueryOutput(sql: st, paged: paged, result: r, pageSize: size, session: session))
					} else {
						affected += r.affectedRows
						changes += 1
						touched += SQLSplitter.writtenTables(st)
					}
				}
			}
			let secs = Date().timeIntervalSince(start)
			var parts: [String] = []
			if !outs.isEmpty { parts.append(outs.count == 1 ? outs[0].totalText : "결과 \(outs.count)개") }
			if changes > 0 { parts.append("\(affected.formatted())행 바뀜") }
			if parts.isEmpty { parts.append("완료") }
			parts.append(String(format: "%.2f초", secs))
			message = parts.joined(separator: " · ")
		} catch {
			isError = true
			message = error.localizedDescription
		}
		if !outs.isEmpty {
			outputs = outs
			selectedOutput = 0
			showResults = true
		}
		// 바꾼 테이블이 탭으로 열려 있으면 "다시 읽기 필요"
		if !touched.isEmpty { session.markStale(touched, defaultDB: session.currentDB) }
	}
}

/// SELECT 결과 하나. LIMIT 없는 SELECT 였으면 쪽을 넘길 수 있다 (그 문장에 LIMIT/OFFSET 을 붙여 다시 실행)
@Observable
final class QueryOutput: Identifiable, Pager {
	let id = UUID()
	/// 입력한 그대로의 문장
	let sql: String
	/// LIMIT 을 자동으로 붙였는지 (= 쪽을 넘길 수 있는지)
	let paged: Bool
	@ObservationIgnored private(set) weak var session: Session?
	private(set) var result: QueryResult
	private(set) var source: QueryResultSource
	private(set) var offset = 0
	private(set) var hasMore = false
	private(set) var pageSize: Int
	private(set) var loading = false
	private(set) var counting = false
	private(set) var knownTotal: Int?
	private(set) var error: String?

	static var currentPageSize: Int {
		let v = UserDefaults.standard.integer(forKey: "pageSize")
		return TableData.pageSizes.contains(v) ? v : 300
	}

	init(sql: String, paged: Bool, result: QueryResult, pageSize: Int, session: Session) {
		self.sql = sql
		self.paged = paged
		self.session = session
		self.pageSize = pageSize
		var r = result
		let more = paged && r.rows.count > pageSize
		if paged { r.rows = Array(r.rows.prefix(pageSize)) }
		self.result = r
		source = QueryResultSource(r, session: session)
		hasMore = more
		if paged && !more { knownTotal = r.rows.count }
	}

	@MainActor
	func load(offset newOffset: Int) async {
		guard paged, let session, !loading else { return }
		loading = true
		error = nil
		defer { loading = false }
		do {
			var r = try await session.query("\(sql) LIMIT \(pageSize + 1) OFFSET \(newOffset)").last ?? QueryResult()
			hasMore = r.rows.count > pageSize
			r.rows = Array(r.rows.prefix(pageSize))
			offset = newOffset
			if !hasMore { knownTotal = newOffset + r.rows.count }
			result = r
			source = QueryResultSource(r, session: session)
		} catch {
			self.error = error.localizedDescription
			NSSound.beep()
		}
	}

	// MARK: Pager

	var pageable: Bool { paged }
	var page: Int { offset / max(1, pageSize) + 1 }

	var totalText: String {
		if let t = knownTotal { return "\(t.formatted())행" }
		if !paged { return "\(result.rows.count.formatted())행" }
		return "\((offset + result.rows.count).formatted())행~"
	}

	var totalIsApprox: Bool { paged && knownTotal == nil }
	var approxHelp: String { "불러온 만큼만 셌습니다. 누르면 정확히 셉니다 (SELECT COUNT(*))" }
	var isEmptyResult: Bool { result.rows.isEmpty && !loading }

	var totalPages: (count: Int, approx: Bool)? {
		guard paged, let t = knownTotal else { return nil }
		return (max(1, Int(ceil(Double(t) / Double(pageSize)))), false)
	}

	@MainActor
	func countExact() async {
		guard paged, let session, !counting else { return }
		counting = true
		defer { counting = false }
		do {
			let r = try await session.query("SELECT COUNT(*) FROM (\(sql)) AS isql_count").last
			if let n = r?.rows.first?.first?.string.flatMap({ Int($0) }) { knownTotal = n }
		} catch {
			NSSound.beep()
		}
	}

	@MainActor
	func goPage(_ p: Int) async {
		var target = max(1, p)
		if let t = totalPages { target = min(target, t.count) }
		await load(offset: (target - 1) * pageSize)
	}

	@MainActor
	func setPageSize(_ n: Int) async {
		guard n != pageSize else { return }
		pageSize = n
		UserDefaults.standard.set(n, forKey: "pageSize")
		await load(offset: 0)
	}
}

/// 쿼리 결과를 공용 표에 댄다: 읽기 전용, 정렬은 앱 안에서, 컬럼 코멘트는 원래 테이블에서 찾아 보여 준다
@Observable
final class QueryResultSource: GridSource {
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private let result: QueryResult
	@ObservationIgnored private var order: [Int]
	@ObservationIgnored private var sortState: (key: String, ascending: Bool)?
	@ObservationIgnored let gridColumns: [GridColumn]
	private(set) var gridVersion = 0
	@ObservationIgnored let gridID = UUID().uuidString

	init(_ result: QueryResult, session: Session) {
		self.result = result
		order = Array(result.rows.indices)
		gridColumns = result.columns.enumerated().map { i, c in
			let info = session.columns["\(c.schema).\(c.orgTable)"]?.first { $0.name == c.orgName }
			// 같은 이름 컬럼이 여럿일 수 있어서(JOIN) 정렬 키는 번호
			return GridColumn(key: String(i), title: c.name, comment: info?.comment ?? "", isKey: c.isPrimaryKey,
			                  numeric: c.isNumeric, long: c.length > 255)
		}
	}

	var rowCount: Int { order.count }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		GridCell(text: result.rows[order[row]][col].string)
	}

	var currentSort: (key: String, ascending: Bool)? { sortState }

	func sort(by key: String?, ascending: Bool) -> Bool {
		sortState = key.map { ($0, ascending) }
		order = Array(result.rows.indices)
		if let k = key, let c = Int(k) {
			let numeric = result.columns[c].isNumeric
			order.sort { a, b in
				let x = result.rows[a][c].string, y = result.rows[b][c].string
				let less: Bool
				switch (x, y) {
				case (nil, nil): less = false
				case (nil, _): less = true
				case (_, nil): less = false
				case let (x?, y?):
					if numeric, let dx = Double(x), let dy = Double(y) { less = dx < dy }
					else { less = x.localizedStandardCompare(y) == .orderedAscending }
				}
				return ascending ? less : !less && x != y
			}
		}
		gridVersion += 1
		return true
	}
}

/// SQL 을 문장으로 나눈다: 따옴표·백틱·주석 안의 ; 는 나누지 않는다
enum SQLSplitter {
	struct Part {
		let text: String
		/// 원문에서의 범위 (UTF-16)
		let range: NSRange
	}

	static func split(_ sql: String) -> [Part] {
		let u = Array(sql.utf16)
		var parts: [Part] = []
		var start = 0
		var i = 0
		var quote: UInt16 = 0
		func cut(_ end: Int) {
			let r = NSRange(location: start, length: end - start)
			let t = (sql as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
			if !t.isEmpty && !onlyComments(t) { parts.append(Part(text: t, range: r)) }
		}
		while i < u.count {
			let c = u[i]
			if quote != 0 {
				if c == 92 /* \ */ && quote != 96 { i += 2; continue }
				if c == quote { quote = 0 }
				i += 1; continue
			}
			switch c {
			case 39, 34, 96: quote = c                      // ' " `
			case 35:                                           // # 줄 주석
				while i < u.count && u[i] != 10 { i += 1 }
				continue
			case 45 where i + 1 < u.count && u[i + 1] == 45:   // -- 줄 주석
				while i < u.count && u[i] != 10 { i += 1 }
				continue
			case 47 where i + 1 < u.count && u[i + 1] == 42:   // /* */
				i += 2
				while i + 1 < u.count && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
				i += 2
				continue
			case 59:                                           // ;
				cut(i)
				start = i + 1
			default: break
			}
			i += 1
		}
		cut(u.count)
		return parts
	}

	private static func onlyComments(_ t: String) -> Bool {
		stripComments(t).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	static func stripComments(_ s: String) -> String {
		var out = s
		for pattern in ["/\\*[\\s\\S]*?\\*/", "(?m)--[^\\n]*$", "(?m)#[^\\n]*$"] {
			out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
		}
		return out
	}

	/// 위험한 문장이면 그 이유. 서버와 상관없이 늘 확인한다 (사용자 결정 2026-11-15):
	/// WHERE 없는 UPDATE, DELETE(WHERE 가 있어도), DROP, TRUNCATE, ALTER
	static func danger(_ st: String) -> String? {
		let s = stripComments(st).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		func starts(_ w: String) -> Bool { s.hasPrefix(w + " ") || s.hasPrefix(w + "\n") || s.hasPrefix(w + "\t") }
		let hasWhere = s.range(of: "\\bWHERE\\b", options: .regularExpression) != nil
		if starts("UPDATE") && !hasWhere { return "WHERE 없는 UPDATE: 모든 행이 바뀝니다" }
		if starts("DELETE") { return hasWhere ? "DELETE: 행을 지웁니다" : "WHERE 없는 DELETE: 모든 행이 지워집니다" }
		if starts("DROP") { return "DROP: 되돌릴 수 없습니다" }
		if starts("TRUNCATE") { return "TRUNCATE: 모든 행이 지워집니다" }
		if starts("ALTER") { return "ALTER: 테이블 구조를 바꿉니다" }
		return nil
	}

	/// LIMIT 을 자동으로 붙여도 되는 SELECT 인지: SELECT 로 시작하고, LIMIT·INTO·FOR UPDATE·LOCK IN SHARE MODE 가 없을 때
	static func canAutoLimit(_ st: String) -> Bool {
		let s = stripComments(st).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		guard s.hasPrefix("SELECT ") || s.hasPrefix("SELECT\n") || s.hasPrefix("SELECT\t") || s.hasPrefix("(SELECT") else { return false }
		// 따옴표 안 글자는 빼고 본다
		let bare = s.replacingOccurrences(of: "'(?:[^'\\\\]|\\\\.)*'", with: "''", options: .regularExpression)
		for w in ["\\bLIMIT\\b", "\\bINTO\\b", "\\bFOR\\s+UPDATE\\b", "\\bLOCK\\s+IN\\s+SHARE\\s+MODE\\b", "\\bFOR\\s+SHARE\\b"] {
			if bare.range(of: w, options: .regularExpression) != nil { return false }
		}
		return true
	}

	/// 이 문장이 바꾸는 테이블 이름들 (db.table 또는 table)
	static func writtenTables(_ st: String) -> [String] {
		let s = stripComments(st)
		let pattern = "(?i)^\\s*(?:UPDATE(?:\\s+LOW_PRIORITY)?(?:\\s+IGNORE)?|INSERT(?:\\s+IGNORE)?\\s+INTO|INSERT\\s+(?!INTO)|REPLACE\\s+INTO|DELETE\\s+FROM|TRUNCATE(?:\\s+TABLE)?|ALTER\\s+TABLE)\\s+([`\\w.]+)"
		guard let re = try? NSRegularExpression(pattern: pattern),
		      let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
		      m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return [] }
		return [String(s[r]).replacingOccurrences(of: "`", with: "")]
	}
}
