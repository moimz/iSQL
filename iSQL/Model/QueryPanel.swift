import Foundation
import AppKit
import Observation

/// 서버마다 하나인 쿼리 패널. 입력한 쿼리는 직접 지우기 전까지 남는다 (앱을 다시 켜도).
/// 저장된 서버면 iCloud 파일(Queries/<서버id>.sql)에 두어 두 맥이 같이 쓴다 — 쿼리 즐겨찾기·기록을 이것으로 대신한다 (사용자 2026-11-17).
/// 저장 안 한 서버(퀵 커넥트)와 시험 앱은 이 맥에만 (UserDefaults "query.<서버id>").
/// 실행한 쿼리 기록은 따로 남기지 않는다 (사용자 결정 2026-11-15)
@Observable
final class QueryPanel {
	@ObservationIgnored private(set) weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }
	@ObservationIgnored private let serverID: UUID?

	var open = false
	var height: CGFloat = {
		let h = UserDefaults.standard.double(forKey: "queryPanelHeight")
		return h >= 80 ? h : 170
	}() {
		didSet { UserDefaults.standard.set(Double(height), forKey: "queryPanelHeight") }
	}
	var text: String { didSet { if !applyingRemote { scheduleSave() } } }

	/// 입력창에 보이는 글: 사용자 것(iCloud 동기화) / MCP 가 넣은 것(이 맥에만, 사용자 2026-11-22).
	/// 입력창은 text 하나만 보고, 바꿀 때 보이는 글과 숨은 글을 맞바꾼다
	enum Source: Int { case mine, mcp }
	var source: Source = .mine {
		didSet {
			guard oldValue != source else { return }
			flushSave()
			applyingRemote = true
			let shown = text
			text = hiddenText
			hiddenText = shown
			applyingRemote = false
			selection = NSRange(location: (text as NSString).length, length: 0)
		}
	}
	/// 지금 안 보이는 쪽의 글
	@ObservationIgnored private var hiddenText = ""
	/// 입력창이 한 번 골라 보여 줄 범위 (MCP 가 넣은 쿼리). 입력창이 보여 준 뒤 nil
	var reveal: NSRange?

	/// MCP show_query: MCP 칸 끝에 "-- ✨ 시각 · 설명" 과 SQL 을 붙이고 그 SQL 을 골라 둔다 (⌘↩ 로 바로 실행).
	/// 오래된 것은 지워 최근 50개만 남긴다. 붙인 SQL 의 범위
	@discardableResult func appendFromMCP(_ sql: String, note: String?) -> NSRange {
		source = .mcp
		let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
		let marker = "-- ✨ "
		let header = marker + f.string(from: Date()) + (note.map { $0.isEmpty ? "" : " · " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "")
		var entries = text.components(separatedBy: "\n\n" + marker)
		if entries.count > 49 { entries = Array(entries.suffix(49)); if !entries[0].hasPrefix(marker) { entries[0] = marker + entries[0] } }
		var base = entries.joined(separator: "\n\n" + marker).trimmingCharacters(in: .whitespacesAndNewlines)
		if !base.isEmpty { base += "\n\n" }
		let body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
		let prefix = base + header + "\n"
		text = prefix + body
		let r = NSRange(location: (prefix as NSString).length, length: (body as NSString).length)
		selection = r
		reveal = r
		return r
	}
	private var mcpKey: String? { serverID.map { "query.mcp.\($0.uuidString)" } }
	/// 쿼리를 돌릴 기본 DB (USE)
	var database = ""

	private(set) var running = false
	/// 실행 중에 취소 버튼으로 바뀌는 버튼 (누른 버튼)
	enum RunButton { case run, all, explain }
	private(set) var runningButton: RunButton?
	/// 취소를 눌렀다 (남은 문장은 실행하지 않는다)
	@ObservationIgnored private var cancelled = false
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
		// 패널은 접속(메인 스레드)에서 만든다
		let saved = serverID.map { id in MainActor.assumeIsolated { AppState.shared.store?.servers.contains { $0.id == id } ?? false } } ?? false
		let env = ProcessInfo.processInfo.environment
		// 시험 앱은 iCloud 에 쓰지 않는다 (동기화 시험만 ISQL_AUTOTEST_SYNC=1 로 켠다)
		synced = (saved && env["ISQL_AUTOTEST_PORT"] == nil) || env["ISQL_AUTOTEST_SYNC"] == "1"
		let key = serverID.map { "query.\($0.uuidString)" }
		let local = key.flatMap { UserDefaults.standard.string(forKey: $0) }
		if synced, let id = serverID {
			if let t = QueryStore.read(id) {
				// 다른 맥이 먼저 옮겼는데 이 맥에도 다른 내용이 있었으면 버리지 않고 뒤에 붙인다
				if let local, !local.isEmpty, local != t {
					text = t + (t.isEmpty ? "" : "\n\n") + "-- 이 맥에만 있던 쿼리\n" + local
					QueryStore.write(id, text)
				} else {
					text = t
				}
			} else {
				// 이 맥에만 있던 내용을 처음 한 번 iCloud 로 옮긴다
				text = local ?? ""
				if let local, !local.isEmpty { QueryStore.write(id, local) }
			}
			if let key { UserDefaults.standard.removeObject(forKey: key) }
			lastSynced = text
			// 다른 맥에서 바뀌면(iCloud), 앱으로 돌아오면 파일을 다시 읽는다
			for name in [CloudWatcher.didChange, NSApplication.didBecomeActiveNotification] {
				observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.pullRemote() }
				})
			}
		} else {
			text = local ?? ""
		}
		hiddenText = serverID.flatMap { UserDefaults.standard.string(forKey: "query.mcp.\($0.uuidString)") } ?? ""
	}

	deinit { observers.forEach(NotificationCenter.default.removeObserver) }

	// MARK: - 내용 저장 (입력이 멈추면 0.5초 뒤)

	@ObservationIgnored private var saveWork: DispatchWorkItem?
	/// iCloud 파일에 두는지 (저장된 서버)
	@ObservationIgnored private let synced: Bool
	/// 마지막으로 파일에 쓰거나 파일에서 읽은 내용 (다른 맥이 바꿨는지 알려고)
	@ObservationIgnored private var lastSynced = ""
	@ObservationIgnored private var applyingRemote = false
	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	/// 기다리던 저장을 지금 한다 (보이는 글을 바꾸기 전에)
	private func flushSave() {
		guard let w = saveWork else { return }
		w.cancel()
		w.perform()
	}

	private func scheduleSave() {
		guard let id = serverID else { return }
		saveWork?.cancel()
		let t = text
		let mcp = source == .mcp, mcpKey = self.mcpKey
		let w = DispatchWorkItem { [weak self] in
			guard let self else { return }
			if mcp {
				if let mcpKey { UserDefaults.standard.set(t, forKey: mcpKey) }
			} else if self.synced {
				QueryStore.write(id, t)
				self.lastSynced = t
			} else {
				UserDefaults.standard.set(t, forKey: "query.\(id.uuidString)")
			}
			self.saveWork = nil
		}
		saveWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
	}

	/// 다른 맥에서 고친 내용을 받아 넣는다. 이 맥에서 치고 있는 중(저장 대기)이면 이쪽 것이 이긴다
	func pullRemote() {
		guard synced, let id = serverID, saveWork == nil, let remote = QueryStore.read(id), remote != lastSynced else { return }
		lastSynced = remote
		// MCP 글을 보고 있으면 숨은 사용자 글만 바꾼다
		if source == .mcp { hiddenText = remote; return }
		guard remote != text else { return }
		applyingRemote = true
		text = remote
		applyingRemote = false
	}

	// MARK: - 실행할 문장 고르기

	/// 선택한 부분이 있으면 그 부분의 문장들, 없으면 커서가 있는 문장 하나
	func statementsToRun(all: Bool) -> [String] {
		if all { return SQLSplitter.split(text, dialect.syntax).map(\.text) }
		let ns = text as NSString
		if selection.length > 0, NSMaxRange(selection) <= ns.length {
			return SQLSplitter.split(ns.substring(with: selection), dialect.syntax).map(\.text)
		}
		let parts = SQLSplitter.split(text, dialect.syntax)
		let cursor = min(selection.location, ns.length)
		return SQLSplitter.statement(at: cursor, in: parts, text: ns).map { [$0.text] } ?? []
	}

	// MARK: - 실행

	/// 실행 중인 쿼리 멈추기 (서버에 취소를 보낸다)
	@MainActor
	func cancel() {
		guard running, !cancelled else { return }
		cancelled = true
		message = "취소하는 중…"
		session?.cancelQuery()
	}

	@MainActor
	func run(_ statements: [String], button: RunButton = .run) async {
		guard let session, !statements.isEmpty, !running else { return }
		running = true
		runningButton = button
		cancelled = false
		message = nil
		isError = false
		let start = Date()
		var outs: [QueryOutput] = []
		var affected: UInt64 = 0
		var changes = 0
		var touched: [String] = []
		defer { running = false; runningButton = nil }
		do {
			if !database.isEmpty, database != session.currentDB {
				_ = try await session.query(dialect.use(database))
				session.currentDB = database
			}
			for st in statements {
				if cancelled { break }
				// LIMIT 없는 SELECT 는 한 쪽 행 수만큼만 (쪽을 넘기면 다시 실행)
				let paged = SQLSplitter.canAutoLimit(st, dialect.syntax)
				let size = QueryOutput.currentPageSize
				let sql = paged ? dialect.paged(st, limit: size + 1) : st
				let t0 = Date()
				let results = try await session.query(sql)
				let took = Date().timeIntervalSince(t0)
				for r in results {
					if r.isResultSet {
						let o = QueryOutput(sql: st, paged: paged, result: r, pageSize: size, session: session)
						o.elapsed = took
						outs.append(o)
					} else {
						affected += r.affectedRows
						changes += 1
						touched += SQLSplitter.writtenTables(st, dialect.syntax)
					}
				}
			}
			let secs = Date().timeIntervalSince(start)
			// 결과만 낸 실행이면 툴바에는 아무것도 적지 않는다: 걸린 시간은 결과 탭에, 행 수는 결과 아래 쪽 줄에 (사용자 2026-11-22)
			if !outs.isEmpty && changes == 0 && !cancelled {
				message = nil
			} else {
				var parts: [String] = []
				if changes > 0 { parts.append("\(affected.formatted())행 바뀜") }
				if cancelled { parts.append("취소함 (남은 문장은 실행하지 않음)") }
				if parts.isEmpty { parts.append("완료") }
				parts.append(String(format: "%.2f초", secs))
				message = parts.joined(separator: " · ")
			}
		} catch {
			isError = true
			message = cancelled ? "취소했습니다 (\(error.localizedDescription))" : error.localizedDescription
		}
		if !outs.isEmpty {
			outputs = outs
			selectedOutput = 0
			showResults = true
		}
		// 바꾼 테이블이 탭으로 열려 있으면 "다시 읽기 필요"
		if !touched.isEmpty { session.markStale(touched, defaultDB: session.currentDB) }
	}

	// MARK: - 실행계획 (EXPLAIN)

	/// 문장마다 실행계획: 나무(FORMAT=TREE, MySQL 8) + 전통 표. EXPLAIN 은 실행하지 않으므로 위험 쿼리 확인을 묻지 않는다.
	/// EXPLAIN ANALYZE 는 진짜로 실행해서 넣지 않았다 (사용자 2026-11-17)
	@MainActor
	func explain(_ statements: [String]) async {
		guard let session, !statements.isEmpty, !running else { return }
		running = true
		runningButton = .explain
		cancelled = false
		message = nil
		isError = false
		defer { running = false; runningButton = nil }
		var outs: [QueryOutput] = []
		var warnCount = 0
		do {
			if !database.isEmpty, database != session.currentDB {
				_ = try await session.query(dialect.use(database))
				session.currentDB = database
			}
			for st in statements {
				let body = ExplainPlan.stripExplain(st)
				// 나무는 MariaDB·옛 MySQL 에 없다 → 없으면 표만
				var tree: String?
				if let t = dialect.explainTree(body) { tree = (try? await session.query(t))?.last?.rows.first?.first?.display }
				guard let table = try await session.query(dialect.explain(body)).last(where: \.isResultSet) else { continue }
				let out = QueryOutput(sql: dialect.explain(body), paged: false, result: table, pageSize: max(1, table.rows.count), session: session)
				let plan = ExplainPlan(tree: tree, result: table)
				warnCount += plan.warnings.count
				out.plan = plan
				out.source.cellTint = { plan.tint(row: $0, col: $1) }
				out.source.gridColumns = out.source.gridColumns.map { var c = $0; c.width = ExplainPlan.widths[c.title.lowercased()] ?? c.width; return c }
				outs.append(out)
			}
			message = "실행계획 \(outs.count)개" + (warnCount > 0 ? " · 경고 \(warnCount)건" : " · 경고 없음")
		} catch {
			isError = true
			message = error.localizedDescription
		}
		if !outs.isEmpty {
			outputs = outs
			selectedOutput = 0
			showResults = true
		}
	}
}

/// EXPLAIN 결과 읽기: 문제 칸 색칠과 한 줄 경고
struct ExplainPlan {
	struct Warning: Hashable {
		let text: String
		let severe: Bool
	}
	let tree: String?
	let warnings: [Warning]
	/// [행][컬럼] 경고색
	private let tints: [Int: [Int: NSColor]]

	/// 전체 훑기를 빨강으로 볼 행 수
	static let manyRows = 1000
	/// 이보다 작은 테이블의 전체 훑기는 문제 삼지 않는다 (코드표 같은 작은 테이블은 훑는 게 빠르다)
	static let fewRows = 100

	init(tree: String?, result: QueryResult) {
		// UPDATE·DELETE 는 나무 대신 "<not executable by iterator executor>" 만 준다 → 표만
		self.tree = tree.flatMap { $0.contains("not executable by iterator executor") ? nil : $0 }
		let names = result.columns.map { $0.name.lowercased() }
		func col(_ n: String) -> Int? { names.firstIndex(of: n) }
		var warns: [Warning] = []
		var tints: [Int: [Int: NSColor]] = [:]
		let red = NSColor.systemRed.withAlphaComponent(0.28), orange = NSColor.systemOrange.withAlphaComponent(0.28)
		for (r, row) in result.rows.enumerated() {
			func val(_ n: String) -> String? { col(n).flatMap { $0 < row.count ? row[$0].display : nil } }
			let table = val("table") ?? "?"
			let rows = Int(val("rows") ?? "") ?? 0
			if val("type")?.uppercased() == "ALL", rows >= Self.fewRows {
				let severe = rows >= Self.manyRows
				let c = severe ? red : orange
				if let i = col("type") { tints[r, default: [:]][i] = c }
				if severe, let i = col("rows") { tints[r, default: [:]][i] = c }
				warns.append(Warning(text: "\(table): 인덱스 없이 전체를 훑음 (약 \(rows.formatted())행)", severe: severe))
			}
			let key = val("key") ?? ""
			if key.isEmpty, rows >= Self.fewRows, let pk = val("possible_keys"), !pk.isEmpty {
				if let i = col("key") { tints[r, default: [:]][i] = orange }
				warns.append(Warning(text: "\(table): 쓸 수 있는 인덱스(\(pk))가 있는데 쓰지 않음", severe: false))
			}
			let extra = val("extra") ?? ""
			var marks: [String] = []
			if extra.contains("Using filesort") { marks.append("정렬을 따로 함 (filesort)") }
			if extra.contains("Using temporary") { marks.append("임시 테이블을 만듦") }
			if !marks.isEmpty {
				if let i = col("extra") { tints[r, default: [:]][i] = orange }
				warns.append(Warning(text: "\(table): " + marks.joined(separator: ", "), severe: false))
			}
		}
		warnings = warns
		self.tints = tints
	}

	func tint(row: Int, col: Int) -> NSColor? { tints[row]?[col] }

	/// 표 컬럼 너비: 기본 150 이면 key·rows·Extra 가 화면 밖으로 밀렸다
	static let widths: [String: CGFloat] = [
		"id": 44, "select_type": 110, "table": 110, "partitions": 84, "type": 70, "possible_keys": 150,
		"key": 120, "key_len": 66, "ref": 120, "rows": 80, "filtered": 70, "extra": 320,
	]

	/// 이미 EXPLAIN 으로 시작하면 떼고 본문만 (EXPLAIN EXPLAIN 이 되지 않게)
	static func stripExplain(_ sql: String) -> String {
		var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
		while s.hasSuffix(";") { s.removeLast() }
		let lower = s.lowercased()
		for p in ["explain format=tree ", "explain format=json ", "explain format=traditional ", "explain ", "describe ", "desc "] where lower.hasPrefix(p) {
			// DESC 테이블 같은 것은 그대로 (뒤가 SELECT·UPDATE 등일 때만 뗀다)
			let rest = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
			let head = rest.prefix(7).lowercased()
			if ["select", "update", "delete", "insert", "replace", "with", "table", "("].contains(where: { head.hasPrefix($0) }) { return rest }
		}
		return s
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
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }
	private(set) var result: QueryResult
	private(set) var source: QueryResultSource
	private(set) var offset = 0
	private(set) var hasMore = false
	private(set) var pageSize: Int
	private(set) var loading = false
	private(set) var counting = false
	private(set) var knownTotal: Int?
	private(set) var error: String?
	/// EXPLAIN 결과면 실행계획 (나무 글·경고)
	var plan: ExplainPlan?
	/// 이 결과를 낸 문장이 걸린 시간 (결과 탭에 보인다, 행 수는 아래 쪽 줄에)
	var elapsed: TimeInterval?

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
		attach()
	}

	/// 결과 표에서 저장하면 같은 쪽을 다시 읽는다
	private func attach() {
		source.onSaved = { [weak self] in await self?.reload() }
	}

	/// 지금 쪽을 다시 실행 (LIMIT 을 붙였으면 그 쪽, 아니면 문장 그대로)
	@MainActor
	func reload() async {
		source.discard()
		if paged { knownTotal = nil; await load(offset: offset); return }
		guard let session, !loading else { return }
		loading = true
		defer { loading = false }
		do {
			result = try await session.query(sql).last ?? QueryResult()
			source = QueryResultSource(result, session: session)
			attach()
		} catch {
			self.error = error.localizedDescription
		}
	}

	@MainActor
	func load(offset newOffset: Int) async {
		guard paged, let session, !loading else { return }
		// 저장 안 한 변경이 있으면 쪽을 넘기지 않는다 (사라지므로)
		guard !source.hasChanges else { NSSound.beep(); return }
		loading = true
		error = nil
		defer { loading = false }
		do {
			var r = try await session.query(dialect.paged(sql, limit: pageSize + 1, offset: newOffset)).last ?? QueryResult()
			hasMore = r.rows.count > pageSize
			r.rows = Array(r.rows.prefix(pageSize))
			offset = newOffset
			if !hasMore { knownTotal = newOffset + r.rows.count }
			result = r
			source = QueryResultSource(r, session: session)
			attach()
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
	var approxHelp: String { "정확한 행 개수 보기" }
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

/// 쿼리 결과를 공용 표에 댄다. 정렬은 앱 안에서, 컬럼 코멘트는 원래 테이블에서 찾는다.
/// 결과가 기본 키 있는 테이블 하나에서 왔고 그 기본 키 컬럼이 모두 들어 있으면 데이터 탭처럼 고칠 수 있다
/// (칸 고치기·행 추가·삭제를 모았다가 ⌘S 로 한 트랜잭션). 계산 컬럼(식·별칭 없는 값)은 고칠 수 없다.
@Observable
final class QueryResultSource: GridSource {
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private let result: QueryResult
	@ObservationIgnored private var order: [Int]
	@ObservationIgnored private var sortState: (key: String, ascending: Bool)?
	/// 실행계획 표는 만든 뒤 컬럼 너비를 정해 준다
	@ObservationIgnored var gridColumns: [GridColumn]
	private(set) var gridVersion = 0
	@ObservationIgnored let gridID = UUID().uuidString
	@ObservationIgnored private weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }

	/// 고칠 수 있으면 그 테이블
	@ObservationIgnored private(set) var editTable: TableInfo?
	/// 고칠 수 없는 까닭 (보기만)
	@ObservationIgnored private(set) var readOnlyReason: String?
	@ObservationIgnored private var keyCols: [Int] = []
	@ObservationIgnored private var editableCols: Set<Int> = []

	/// 원래 행 번호 → 컬럼 → 새 값
	private(set) var edits: [Int: [Int: Value]] = [:]
	private(set) var deleted: Set<Int> = []
	private(set) var inserted: [[Value]] = []
	private(set) var saving = false
	private(set) var saveError: String?
	var showSQL = false
	/// 저장한 뒤 결과를 다시 읽는다 (QueryOutput 이 단다)
	@ObservationIgnored var onSaved: (() async -> Void)?

	init(_ result: QueryResult, session: Session) {
		self.result = result
		self.session = session
		order = Array(result.rows.indices)
		gridColumns = result.columns.enumerated().map { i, c in
			let info = session.columns["\(c.schema).\(c.orgTable)"]?.first { $0.name == c.orgName }
			// 같은 이름 컬럼이 여럿일 수 있어서(JOIN) 정렬 키는 번호
			return GridColumn(key: String(i), title: c.name, comment: info?.comment ?? "", isKey: c.isPrimaryKey,
			                  numeric: c.isNumeric, long: c.length > 255)
		}
		decideEditable(session)
	}

	/// 한 테이블·기본 키 모두 있음 → 고칠 수 있음
	private func decideEditable(_ session: Session) {
		let cols = result.columns
		guard !cols.isEmpty else { readOnlyReason = "결과가 없습니다"; return }
		let sources = Set(cols.filter { !$0.orgTable.isEmpty }.map { "\($0.schema)\u{1}\($0.orgTable)" })
		guard sources.count == 1, let c0 = cols.first(where: { !$0.orgTable.isEmpty }) else {
			readOnlyReason = sources.isEmpty ? "테이블 컬럼이 아닌 결과라 보기만 됩니다" : "여러 테이블에서 온 결과라 보기만 됩니다"
			return
		}
		guard let t = session.tables.first(where: { $0.schema == c0.schema && $0.name == c0.orgTable }), !t.isView else {
			readOnlyReason = "뷰나 임시 결과라 보기만 됩니다"
			return
		}
		let info = session.columns[t.id] ?? []
		let pk = info.filter { $0.key == "PRI" }.map(\.name)
		guard !pk.isEmpty else { readOnlyReason = "기본 키가 없는 테이블이라 보기만 됩니다"; return }
		var keys: [Int] = []
		for k in pk {
			guard let i = cols.firstIndex(where: { $0.orgTable == t.name && $0.orgName == k }) else {
				readOnlyReason = "결과에 기본 키(\(pk.joined(separator: ", ")))가 없어 보기만 됩니다"
				return
			}
			keys.append(i)
		}
		// 같은 컬럼이 두 번 나오면(SELECT a, a) 첫 번째만 고친다
		var seen = Set<String>()
		editableCols = Set(cols.indices.filter { i in
			cols[i].orgTable == t.name && !cols[i].orgName.isEmpty && !cols[i].isBinary && seen.insert(cols[i].orgName).inserted
		})
		keyCols = keys
		editTable = t
	}

	var canEdit: Bool { editTable != nil }
	var rowCount: Int { order.count + inserted.count }
	var editCount: Int { edits.filter { !deleted.contains($0.key) }.reduce(0) { $0 + $1.value.count } }
	var changeCount: Int { editCount + deleted.count + inserted.count }
	var hasChanges: Bool { changeCount > 0 }

	private func bump() { gridVersion += 1 }

	/// 화면 줄 → 원래 행 번호 (새 행이면 nil)
	private func orig(_ row: Int) -> Int? { row < order.count ? order[row] : nil }

	func value(_ row: Int, _ col: Int) -> Value {
		guard let o = orig(row) else { return inserted[row - order.count][safe: col] ?? .null }
		return edits[o]?[col] ?? result.rows[o][col]
	}

	func cell(_ row: Int, _ col: Int) -> GridCell {
		let v = value(row, col)
		var c: GridCell
		if let o = orig(row) {
			if deleted.contains(o) { c = GridCell(text: v.display, state: .deleted) }
			else if edits[o]?[col] != nil { c = GridCell(text: v.display, state: .edited, tooltip: "원래 값: " + (result.rows[o][col].display ?? "NULL")) }
			else { c = GridCell(text: v.display, tint: cellTint?(o, col)) }
		} else {
			c = GridCell(text: v.display, state: .inserted)
		}
		// 날짜로 보는 컬럼: 숫자를 날짜로 (실제 값은 풍선 도움말에)
		if let u = unixUnit(col), case .text(let t) = v, let shown = u.display(t) {
			c.text = shown
			c.tooltip = (c.tooltip.map { $0 + "\n" } ?? "") + "유닉스 시간(\(u.name)): \(t)"
		}
		return c
	}

	// MARK: 컬럼을 날짜로 보기 (유닉스 시간). 결과는 그때뿐이라 서버마다 컬럼 이름으로 기억한다 (다음 쿼리의 같은 이름 컬럼에도)

	private var unixKey: String { "unixTime.query.\(session?.server?.id.uuidString ?? "-")" }
	private func columnName(_ col: Int) -> String { result.columns[col].name }
	func unixUnit(_ col: Int) -> UnixTimeUnit? {
		guard result.columns.indices.contains(col), result.columns[col].isNumeric else { return nil }
		return (UserDefaults.standard.dictionary(forKey: unixKey)?[columnName(col)] as? String).flatMap(UnixTimeUnit.init(rawValue:))
	}
	func setUnixView(_ col: Int, _ unit: UnixTimeUnit?) {
		guard result.columns.indices.contains(col) else { return }
		var d = UserDefaults.standard.dictionary(forKey: unixKey) as? [String: String] ?? [:]
		d[columnName(col)] = unit?.rawValue
		if d.isEmpty { UserDefaults.standard.removeObject(forKey: unixKey) } else { UserDefaults.standard.set(d, forKey: unixKey) }
		if unit != nil { fitRequests.insert(col) }
		bump()
	}
	@ObservationIgnored private var fitRequests: Set<Int> = []
	func takeFitRequests() -> [Int] { defer { fitRequests = [] }; return Array(fitRequests) }

	func headerMenu(_ col: Int) -> [GridMenuItem] {
		guard result.columns.indices.contains(col), result.columns[col].isNumeric else { return [] }
		let now = unixUnit(col)
		var sub: [GridMenuItem] = UnixTimeUnit.allCases.map { u in .action((now == u ? "✓ " : "") + u.label) { self.setUnixView(col, u) } }
		sub.append(.separator)
		sub.append(.action((now == nil ? "✓ " : "") + "숫자 그대로") { self.setUnixView(col, nil) })
		return [.submenu("날짜로 보기 (유닉스 시간)", sub)]
	}

	/// 칸 경고색 (원래 행 번호, 컬럼). 실행계획 결과에서 쓴다
	@ObservationIgnored var cellTint: ((Int, Int) -> NSColor?)?

	/// 결과 컬럼이 모두 한 테이블의 진짜 컬럼이면 INSERT 로 복사할 수 있다
	var insertTarget: InsertTarget? {
		let cols = result.columns
		guard let t = cols.first?.orgTable, !t.isEmpty,
		      cols.allSatisfy({ $0.orgTable == t && !$0.orgName.isEmpty }),
		      Set(cols.map(\.orgName)).count == cols.count else { return nil }
		return InsertTarget(table: dialect.quote(t), columns: cols.map(\.orgName),
		                    primaryKey: Set(cols.indices.filter { cols[$0].isPrimaryKey }))
	}

	func sqlValue(_ row: Int, _ col: Int) -> Value? { value(row, col) }
	var sqlDialect: any SQLDialect { dialect }
	func isBinaryColumn(_ col: Int) -> Bool { result.columns.indices.contains(col) && result.columns[col].isBinary }

	func isEditable(_ row: Int, _ col: Int) -> Bool {
		guard canEdit, editableCols.contains(col) else { return false }
		if let o = orig(row) { return !deleted.contains(o) }
		return true
	}

	func set(_ row: Int, _ col: Int, _ v: Value) {
		guard isEditable(row, col) else { NSSound.beep(); return }
		if let o = orig(row) {
			if result.rows[o][col] == v {
				edits[o]?[col] = nil
				if edits[o]?.isEmpty == true { edits[o] = nil }
			} else {
				edits[o, default: [:]][col] = v
			}
		} else {
			inserted[row - order.count][col] = v
		}
		bump()
	}

	/// 날짜로 보는 컬럼에 날짜를 넣으면 그 단위의 숫자로
	func setText(_ row: Int, _ col: Int, _ text: String) {
		if let u = unixUnit(col), let raw = u.raw(text) { set(row, col, .text(raw)); return }
		set(row, col, .text(text))
	}

	func addRow() {
		guard canEdit else { return }
		inserted.append(Array(repeating: .null, count: result.columns.count))
		bump()
	}

	/// 고른 행을 같은 값으로 새 행에 (기본 키 칸은 비워서). 고칠 수 없는 컬럼(식)은 새 행에서 안 쓰이니 비운다
	func duplicateRows(_ rows: IndexSet) {
		guard canEdit, !rows.isEmpty else { return }
		for r in rows.sorted() where !(orig(r).map { deleted.contains($0) } ?? false) {
			inserted.append(result.columns.indices.map { keyCols.contains($0) || !editableCols.contains($0) ? .null : value(r, $0) })
		}
		bump()
	}

	/// 기존 행은 지울 표시(다시 누르면 취소), 새 행은 바로 뺀다
	func toggleDelete(_ rows: IndexSet) {
		guard canEdit else { return }
		let existing = rows.compactMap(orig)
		let allDeleted = !existing.isEmpty && existing.allSatisfy { deleted.contains($0) }
		for o in existing { if allDeleted { deleted.remove(o) } else { deleted.insert(o) } }
		for r in rows.filter({ $0 >= order.count }).sorted(by: >) { inserted.remove(at: r - order.count) }
		bump()
	}

	func discard() {
		edits = [:]; deleted = []; inserted = []; saveError = nil
		bump()
	}

	func deleteRows(_ rows: IndexSet) -> Bool {
		guard canEdit else { return false }
		toggleDelete(rows)
		return true
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		guard canEdit else { return [] }
		var items: [GridMenuItem] = []
		if let col, isEditable(row, col) {
			items.append(.action("NULL 로 바꾸기") { self.set(row, col, .null) })
			items.append(.action("빈 문자열로 바꾸기") { self.set(row, col, .text("")) })
			if let o = orig(row), edits[o]?[col] != nil { items.append(.action("원래 값으로") { self.set(row, col, self.result.rows[o][col]) }) }
			items.append(.separator)
		}
		items.append(.action("행 추가") { self.addRow() })
		items.append(.action("행 복제 (\(selection.count)개)") { self.duplicateRows(selection) })
		let allDeleted = selection.allSatisfy { r in orig(r).map { deleted.contains($0) } ?? false }
		items.append(.action(allDeleted ? "삭제 취소" : "행 삭제 (\(selection.count)개)") { self.toggleDelete(selection) })
		return items
	}

	// MARK: 저장

	private func name(_ col: Int) -> String { result.columns[col].orgName }

	private func keyCondition(_ o: Int) -> String {
		keyCols.map { i in
			let v = result.rows[o][i]
			return v == .null ? "\(dialect.quote(name(i))) IS NULL" : "\(dialect.quote(name(i))) = \(dialect.literal(v))"
		}.joined(separator: " AND ")
	}

	/// 저장할 때 실행할 SQL (미리보기에도 쓴다)
	func changeSQL() -> [String] {
		guard let t = editTable else { return [] }
		var out: [String] = []
		for o in deleted.sorted() {
			out.append(dialect.deleteRow(dialect.quote(table: t), condition: keyCondition(o)) + ";")
		}
		for (o, cols) in edits.sorted(by: { $0.key < $1.key }) where !deleted.contains(o) {
			let sets = cols.sorted { $0.key < $1.key }.map { "\(dialect.quote(name($0.key))) = \(dialect.literal($0.value))" }
			out.append(dialect.updateRow(dialect.quote(table: t), sets: sets, condition: keyCondition(o)) + ";")
		}
		for row in inserted {
			// NULL 로 남은 칸은 빼서 기본값·자동 증가가 쓰이게
			let pairs = row.enumerated().filter { $0.element != .null && editableCols.contains($0.offset) }
			out.append(dialect.insertRow(dialect.quote(table: t), columns: pairs.map { dialect.quote(name($0.offset)) },
			                             values: pairs.map { dialect.literal($0.element) }) + ";")
		}
		return out
	}

	@MainActor
	func save() async {
		guard let session, let t = editTable, !saving else { return }
		let statements = changeSQL()
		guard !statements.isEmpty else { return }
		saving = true
		saveError = nil
		defer { saving = false }
		do {
			_ = try await session.query(dialect.beginTransaction)
			for s in statements {
				let r = try await session.query(s).last
				if s.hasPrefix("UPDATE") || s.hasPrefix("DELETE"), r?.affectedRows == 0, r?.info.contains("Rows matched: 1") != true {
					throw DBError.message("대상 행을 찾지 못했습니다. 다른 곳에서 바뀌었을 수 있습니다.\n\(s)")
				}
			}
			_ = try await session.query(dialect.commit)
		} catch {
			_ = try? await session.query(dialect.rollback)
			saveError = error.localizedDescription
			return
		}
		// 같은 테이블이 데이터 탭으로 열려 있으면 "다시 읽기" 표시
		session.markStale([t.id], defaultDB: "")
		await onSaved?()
	}

	var currentSort: (key: String, ascending: Bool)? { sortState }

	/// 저장 안 한 변경이 있으면 줄 순서가 바뀌지 않게 정렬하지 않는다
	func sort(by key: String?, ascending: Bool) -> Bool {
		if hasChanges { return false }
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

/// SQL 을 문장으로 나눈다: 따옴표·이름·주석 안의 ; 는 나누지 않는다 (글자 규칙은 서버 종류의 SQLSyntax)
enum SQLSplitter {
	struct Part {
		let text: String
		/// 원문에서의 범위 (UTF-16)
		let range: NSRange
	}

	static func split(_ sql: String, _ syntax: SQLSyntax) -> [Part] {
		let u = Array(sql.utf16)
		var parts: [Part] = []
		var start = 0
		var i = 0
		var quote: UInt16 = 0
		func cut(_ end: Int) {
			let r = NSRange(location: start, length: end - start)
			let t = (sql as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
			if !t.isEmpty && !onlyComments(t, syntax) { parts.append(Part(text: t, range: r)) }
		}
		while i < u.count {
			let c = u[i]
			if quote != 0 {
				if c == 92 /* \ */ && syntax.backslashEscapes && quote != syntax.identifierQuote { i += 2; continue }
				if c == quote { quote = 0 }
				i += 1; continue
			}
			if syntax.opensQuote(c) { quote = c; i += 1; continue }   // ' " `
			// T-SQL [이름]: ] 까지 건너뛴다 (]] 는 ] 글자)
			if syntax.tsqlBatches && c == 91 {
				i += 1
				while i < u.count { if u[i] == 93 { if i + 1 < u.count && u[i + 1] == 93 { i += 2; continue }; break }; i += 1 }
				i += 1; continue
			}
			// T-SQL GO 줄: 배치 끝
			if syntax.tsqlBatches && (c == 71 || c == 103), let end = TSQLScript.goLineEnd(u, at: i) {
				cut(i); start = end; i = end; continue
			}
			switch c {
			case 35 where syntax.hashComments:                 // # 줄 주석
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
				// PL/SQL 블록 안의 ; 는 문장 끝이 아니다 (블록은 / 줄이나 글 끝에서 끝난다)
				if syntax.plsqlBlocks, SQLSyntax.startsPLSQLBlock((sql as NSString).substring(with: NSRange(location: start, length: i - start))) { break }
				// SQLite 트리거 BEGIN … END 안의 ; 도
				if syntax.sqliteTriggers, SQLiteScript.insideTrigger((sql as NSString).substring(with: NSRange(location: start, length: i - start))) { break }
				// T-SQL 프로시저 정의·DECLARE 글 안의 ; 도 (GO 줄이나 글 끝에서 끝난다)
				if syntax.tsqlBatches, TSQLScript.startsBlock((sql as NSString).substring(with: NSRange(location: start, length: i - start))) { break }
				cut(i)
				start = i + 1
			case 47 where syntax.plsqlBlocks:                  // 줄에 / 하나만: 문장 끝
				var b = i - 1
				while b >= 0 && (u[b] == 32 || u[b] == 9) { b -= 1 }
				let lineStart = b < 0 || u[b] == 10
				var j = i + 1
				while j < u.count && (u[j] == 32 || u[j] == 9 || u[j] == 13) { j += 1 }
				if lineStart && (j >= u.count || u[j] == 10) {
					cut(i)
					start = j
					i = j
					continue
				}
			default: break
			}
			i += 1
		}
		cut(u.count)
		return parts
	}

	/// 커서 자리의 문장. 문장 범위는 ; 바로 뒤부터 다음 ; 앞까지라서 "쿼리1;|" 처럼 ; 바로 뒤(같은 줄)에 커서가 있으면
	/// 다음 문장 범위의 맨 앞이 된다 → 다음 문장 글자보다 앞이고 ; 와 커서 사이에 줄바꿈이 없으면 앞 문장 (사용자 2026-11-19).
	/// 어느 범위에도 없으면 커서 바로 앞 문장 (맨 끝 ; 뒤), 그것도 없으면 첫 문장
	static func statement(at cursor: Int, in parts: [Part], text ns: NSString) -> Part? {
		if let k = parts.firstIndex(where: { $0.range.location <= cursor && cursor <= NSMaxRange($0.range) }) {
			let p = parts[k]
			if k > 0 {
				let body = ns.substring(with: p.range)
				let lead = body.utf16.prefix { CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar($0) ?? " ") }.count
				let prevEnd = NSMaxRange(parts[k - 1].range)
				if cursor < p.range.location + lead, cursor >= prevEnd,
				   !ns.substring(with: NSRange(location: prevEnd, length: cursor - prevEnd)).contains(where: \.isNewline) {
					return parts[k - 1]
				}
			}
			return p
		}
		return parts.last(where: { NSMaxRange($0.range) <= cursor }) ?? parts.first
	}

	private static func onlyComments(_ t: String, _ syntax: SQLSyntax) -> Bool {
		stripComments(t, syntax).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	static func stripComments(_ s: String, _ syntax: SQLSyntax) -> String {
		var out = s
		for pattern in ["/\\*[\\s\\S]*?\\*/", "(?m)--[^\\n]*$"] + (syntax.hashComments ? ["(?m)#[^\\n]*$"] : []) {
			out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
		}
		return out
	}

	/// 위험한 문장이면 그 이유. 서버와 상관없이 늘 확인한다 (사용자 결정 2026-11-15):
	/// WHERE 없는 UPDATE, DELETE(WHERE 가 있어도), DROP, TRUNCATE, ALTER
	static func danger(_ st: String, _ syntax: SQLSyntax) -> String? {
		let s = stripComments(st, syntax).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		func starts(_ w: String) -> Bool { s.hasPrefix(w + " ") || s.hasPrefix(w + "\n") || s.hasPrefix(w + "\t") }
		let hasWhere = s.range(of: "\\bWHERE\\b", options: .regularExpression) != nil
		if starts("UPDATE") && !hasWhere { return "WHERE 없는 UPDATE: 모든 행이 바뀝니다" }
		if starts("DELETE") { return hasWhere ? "DELETE: 행을 삭제합니다" : "WHERE 없는 DELETE: 모든 행이 삭제됩니다" }
		if starts("DROP") { return "DROP: 되돌릴 수 없습니다" }
		if starts("TRUNCATE") { return "TRUNCATE: 모든 행이 삭제됩니다" }
		if starts("ALTER") { return "ALTER: 테이블 구조를 바꿉니다" }
		return nil
	}

	/// LIMIT 을 자동으로 붙여도 되는 SELECT 인지: SELECT 로 시작하고, LIMIT·INTO·FOR UPDATE·LOCK IN SHARE MODE 가 없을 때
	static func canAutoLimit(_ st: String, _ syntax: SQLSyntax) -> Bool {
		let s = stripComments(st, syntax).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		guard s.hasPrefix("SELECT ") || s.hasPrefix("SELECT\n") || s.hasPrefix("SELECT\t") || s.hasPrefix("(SELECT") else { return false }
		// 따옴표 안 글자는 빼고 본다
		let bare = s.replacingOccurrences(of: "'(?:[^'\\\\]|\\\\.)*'", with: "''", options: .regularExpression)
		// FETCH FIRST/NEXT … ROWS · OFFSET … ROWS: Oracle · MariaDB 의 행 제한
		for w in ["\\bLIMIT\\b", "\\bFETCH\\s+(FIRST|NEXT)\\b", "\\bOFFSET\\s+\\S+\\s+ROWS?\\b", "\\bINTO\\b", "\\bFOR\\s+UPDATE\\b", "\\bLOCK\\s+IN\\s+SHARE\\s+MODE\\b", "\\bFOR\\s+SHARE\\b"] {
			if bare.range(of: w, options: .regularExpression) != nil { return false }
		}
		// T-SQL: SELECT TOP … 은 OFFSET … FETCH 와 같이 못 쓴다
		if syntax.tsqlBatches, bare.range(of: #"^\(?SELECT\s+(ALL\s+|DISTINCT\s+)?TOP\b"#, options: .regularExpression) != nil { return false }
		return true
	}

	/// 이 문장이 바꾸는 테이블 이름들 (db.table 또는 table)
	static func writtenTables(_ st: String, _ syntax: SQLSyntax) -> [String] {
		let s = stripComments(st, syntax)
		let q = NSRegularExpression.escapedPattern(for: syntax.identifierQuoteString)
		let pattern = "(?i)^\\s*(?:UPDATE(?:\\s+LOW_PRIORITY)?(?:\\s+IGNORE)?|INSERT(?:\\s+IGNORE)?\\s+INTO|INSERT\\s+(?!INTO)|REPLACE\\s+INTO|DELETE\\s+FROM|TRUNCATE(?:\\s+TABLE)?|ALTER\\s+TABLE)\\s+([" + q + "\\w.]+)"
		guard let re = try? NSRegularExpression(pattern: pattern),
		      let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
		      m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return [] }
		return [String(s[r]).replacingOccurrences(of: syntax.identifierQuoteString, with: "")]
	}
}
