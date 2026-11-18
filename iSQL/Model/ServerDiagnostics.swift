import Foundation
import AppKit
import Observation

/// 서버 진단: 상태 요약·프로세스 목록·쿼리 통계를 읽는다. 설정 창 "상태" 탭과 MCP(server_status·top_queries)가 같이 쓴다.
/// 쿼리를 돌릴 방법만 받아서(앱 연결이든 MCP 연결이든) 같은 SQL 을 쓴다
enum ServerDiagnostics {
	typealias Run = (String) async throws -> QueryResult

	/// SHOW GLOBAL STATUS / VARIABLES → 이름: 값
	static func pairs(_ run: Run, _ sql: String) async throws -> [String: String] {
		let r = try await run(sql)
		var d: [String: String] = [:]
		for row in r.rows { if let k = row[safe: 0]?.string { d[k.lowercased()] = row[safe: 1]?.string ?? "" } }
		return d
	}

	struct Summary {
		var version = ""
		var uptime = 0
		var connected = 0
		var running = 0
		var maxConnections = 0
		var questions = 0
		var slowQueries = 0
		var bufferHit: Double?
		var bufferUsed: Int64 = 0
		var bufferSize: Int64 = 0
		var received: Int64 = 0
		var sent: Int64 = 0
		var longQueryTime = ""

		/// 시작한 뒤 평균 초당 쿼리
		var avgQPS: Double { uptime > 0 ? Double(questions) / Double(uptime) : 0 }
		var connectionsTight: Bool { maxConnections > 0 && Double(connected) / Double(maxConnections) >= 0.8 }
		var bufferLow: Bool { (bufferHit ?? 1) < 0.95 }
	}

	static func summary(_ run: Run) async throws -> Summary {
		let st = try await pairs(run, "SHOW GLOBAL STATUS")
		let v = try await pairs(run, "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('version','version_comment','max_connections','innodb_buffer_pool_size','innodb_page_size','long_query_time')")
		func i(_ k: String) -> Int64 { Int64(st[k] ?? "") ?? 0 }
		var s = Summary()
		s.version = [v["version"], v["version_comment"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
		s.uptime = Int(i("uptime"))
		s.connected = Int(i("threads_connected"))
		s.running = Int(i("threads_running"))
		s.maxConnections = Int(v["max_connections"] ?? "") ?? 0
		s.questions = Int(i("questions"))
		s.slowQueries = Int(i("slow_queries"))
		let req = i("innodb_buffer_pool_read_requests"), disk = i("innodb_buffer_pool_reads")
		if req > 0 { s.bufferHit = 1 - Double(disk) / Double(req) }
		let page = Int64(v["innodb_page_size"] ?? "") ?? 16384
		s.bufferUsed = i("innodb_buffer_pool_pages_data") * page
		s.bufferSize = Int64(v["innodb_buffer_pool_size"] ?? "") ?? 0
		s.received = i("bytes_received")
		s.sent = i("bytes_sent")
		s.longQueryTime = v["long_query_time"] ?? ""
		return s
	}

	struct Process {
		let id: Int64
		let user: String
		let host: String
		let db: String
		let command: String
		let time: Int
		let state: String
		let info: String

		/// 잠금을 기다림 (빨강)
		var waitingLock: Bool { state.lowercased().contains("lock") && command != "Sleep" }
		/// 10초 넘게 도는 쿼리 (노랑)
		var long: Bool { command == "Query" && time >= 10 }
	}

	static func processes(_ run: Run) async throws -> [Process] {
		let r = try await run("SHOW FULL PROCESSLIST")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			return Process(id: Int64(s(0)) ?? 0, user: s(1), host: s(2), db: s(3), command: s(4), time: Int(s(5)) ?? 0, state: s(6), info: s(7))
		}
	}

	struct Digest {
		let sql: String
		let schema: String
		let count: Int64
		let totalSeconds: Double
		let avgSeconds: Double
		let rowsExamined: Int64
		let rowsSent: Int64
	}

	/// performance_schema 의 쿼리별 요약 (오래 걸린 순). 꺼져 있으면 오류
	static func topQueries(_ run: Run, limit: Int = 20) async throws -> [Digest] {
		let r = try await run("""
			SELECT DIGEST_TEXT, SCHEMA_NAME, COUNT_STAR, SUM_TIMER_WAIT / 1e12, AVG_TIMER_WAIT / 1e12, SUM_ROWS_EXAMINED, SUM_ROWS_SENT
			  FROM performance_schema.events_statements_summary_by_digest
			 WHERE DIGEST_TEXT IS NOT NULL ORDER BY SUM_TIMER_WAIT DESC LIMIT \(max(1, min(limit, 200)))
			""")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			return Digest(sql: s(0), schema: s(1), count: Int64(s(2)) ?? 0, totalSeconds: Double(s(3)) ?? 0,
			              avgSeconds: Double(s(4)) ?? 0, rowsExamined: Int64(s(5)) ?? 0, rowsSent: Int64(s(6)) ?? 0)
		}
	}

	/// "10.000000" → "10", "0.500000" → "0.5"
	static func trimNumber(_ s: String) -> String {
		guard s.contains(".") else { return s }
		var t = s
		while t.hasSuffix("0") { t.removeLast() }
		if t.hasSuffix(".") { t.removeLast() }
		return t
	}

	/// JSON 에 넣을 소수 (0.1 이 0.10000000000000001 로 나오지 않게)
	static func decimal(_ v: Double, _ places: Int) -> NSDecimalNumber {
		NSDecimalNumber(string: String(format: "%.\(places)f", v))
	}

	static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .binary) }

	static func duration(_ seconds: Int) -> String {
		let d = seconds / 86400, h = seconds % 86400 / 3600, m = seconds % 3600 / 60
		if d > 0 { return "\(d)일 \(h)시간" }
		if h > 0 { return "\(h)시간 \(m)분" }
		return "\(m)분 \(seconds % 60)초"
	}

	static func seconds(_ s: Double) -> String {
		s >= 1 ? String(format: "%.2fs", s) : String(format: "%.1fms", s * 1000)
	}
}

/// 설정 창 "상태" 탭: 따로 된 연결로 5초마다 읽는다 (콘솔에 남기지 않는다 — 5초마다 쌓이면 콘솔이 묻힌다).
/// 쿼리 멈추기·연결 끊기는 앱 연결로 보내 콘솔에 남긴다
@Observable
final class ServerStatusMonitor {
	@ObservationIgnored private weak var session: Session?
	@ObservationIgnored private var conn: (any DBConnection)?
	@ObservationIgnored private var loop: Task<Void, Never>?
	@ObservationIgnored private var lastQuestions: (count: Int, at: Date)?

	private(set) var summary: ServerDiagnostics.Summary?
	/// 지난번 읽은 뒤 초당 쿼리 (처음엔 평균)
	private(set) var qps: Double = 0
	private(set) var processes: [ServerDiagnostics.Process] = []
	private(set) var digests: [ServerDiagnostics.Digest] = []
	private(set) var digestError: String?
	private(set) var error: String?
	private(set) var updated: Date?
	/// 앱의 주 연결·이 탭 연결 id (프로세스 목록에 표시)
	private(set) var appConnectionID: Int64?
	private(set) var ownConnectionID: Int64?
	var paused = false
	private(set) var version = 0

	let processSource = ProcessListSource()
	let digestSource = DigestSource()

	static let interval: Double = 5

	init(session: Session) {
		self.session = session
		processSource.monitor = self
	}

	deinit { loop?.cancel(); conn?.close() }

	@MainActor
	func start() {
		guard loop == nil else { return }
		loop = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				if !self.paused { await self.refresh() }
				try? await Task.sleep(for: .seconds(Self.interval))
			}
		}
	}

	@MainActor
	func stop() {
		loop?.cancel()
		loop = nil
		conn?.close()
		conn = nil
	}

	@MainActor
	func refresh() async {
		guard let session else { return }
		do {
			if conn == nil {
				conn = try await session.sideConnection(purpose: "상태", log: false)
				ownConnectionID = Int64((try? await conn!.query("SELECT CONNECTION_ID()"))?.last?.rows.first?.first?.string ?? "")
			}
			if appConnectionID == nil {
				appConnectionID = Int64((try? await session.query("SELECT CONNECTION_ID()"))?.last?.rows.first?.first?.string ?? "")
			}
			guard let c = conn else { return }
			let run: ServerDiagnostics.Run = { sql in try await c.query(sql).last ?? QueryResult() }
			let s = try await ServerDiagnostics.summary(run)
			let now = Date()
			if let last = lastQuestions, now.timeIntervalSince(last.at) > 0.5 {
				// 이 탭이 읽는 쿼리(한 번에 3~4개)는 빼고 센다
				qps = max(0, Double(s.questions - last.count - 4) / now.timeIntervalSince(last.at))
			} else {
				qps = s.avgQPS
			}
			lastQuestions = (s.questions, now)
			summary = s
			processes = try await ServerDiagnostics.processes(run)
			do {
				digests = try await ServerDiagnostics.topQueries(run)
				digestError = nil
			} catch {
				digests = []
				digestError = "쿼리 통계를 읽지 못했습니다 (performance_schema 가 꺼져 있거나 권한이 없습니다): \(error.localizedDescription)"
			}
			error = nil
			updated = now
			version += 1
			processSource.bump()
			digestSource.set(digests)
		} catch {
			self.error = error.localizedDescription
			conn?.close()
			conn = nil
		}
	}

	/// KILL QUERY (쿼리만 멈춤) / KILL (연결 끊기). 앱 연결로 보내 콘솔에 남긴다
	@MainActor
	func kill(_ p: ServerDiagnostics.Process, connection: Bool) async {
		guard let session else { return }
		do {
			_ = try await session.query(connection ? "KILL \(p.id)" : "KILL QUERY \(p.id)")
		} catch {
			let a = NSAlert()
			a.messageText = connection ? "연결을 끊지 못했습니다" : "쿼리를 멈추지 못했습니다"
			a.informativeText = error.localizedDescription
			a.runModal()
		}
		await refresh()
	}
}

/// 프로세스 목록 표
@Observable
final class ProcessListSource: GridSource {
	@ObservationIgnored weak var monitor: ServerStatusMonitor?
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	private(set) var gridVersion = 0
	func bump() { gridVersion += 1 }

	private var list: [ServerDiagnostics.Process] { monitor?.processes ?? [] }

	var gridID: String { "processlist" }
	var gridColumns: [GridColumn] {
		[GridColumn(key: "id", title: "ID", numeric: true, width: 70),
		 GridColumn(key: "user", title: "사용자", width: 110),
		 GridColumn(key: "host", title: "호스트", width: 150),
		 GridColumn(key: "db", title: "DB", width: 110),
		 GridColumn(key: "command", title: "명령", width: 80),
		 GridColumn(key: "time", title: "시간(초)", numeric: true, width: 70),
		 GridColumn(key: "state", title: "상태", width: 170),
		 GridColumn(key: "info", title: "쿼리", mono: true, width: 600)]
	}
	var rowCount: Int { list.count }
	var sortable: Bool { false }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		guard row < list.count else { return GridCell(text: "") }
		let p = list[row]
		var c: GridCell
		switch col {
		case 0: c = GridCell(text: String(p.id))
		case 1:
			let mine = p.id == monitor?.appConnectionID ? " (iSQL)" : (p.id == monitor?.ownConnectionID ? " (이 창)" : "")
			c = GridCell(text: p.user + mine)
		case 2: c = GridCell(text: p.host, dim: true)
		case 3: c = GridCell(text: p.db, dim: p.db.isEmpty)
		case 4: c = GridCell(text: p.command, dim: p.command == "Sleep")
		case 5: c = GridCell(text: String(p.time))
		case 6: c = GridCell(text: p.state)
		default: c = GridCell(text: p.info.replacingOccurrences(of: "\n", with: " "), tooltip: p.info.count > 60 ? p.info : nil)
		}
		c.tint = p.waitingLock ? NSColor.systemRed.withAlphaComponent(0.16) : (p.long ? NSColor.systemYellow.withAlphaComponent(0.16) : nil)
		return c
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		guard row < list.count, let m = monitor else { return [] }
		let p = list[row]
		let own = p.id == m.ownConnectionID || p.id == m.appConnectionID
		func confirm(_ title: String, _ connection: Bool) -> () -> Void {
			{
				let a = NSAlert()
				a.messageText = "\(title) (ID \(p.id))"
				a.informativeText = "\(p.user)@\(p.host)" + (p.info.isEmpty ? "" : "\n\n" + String(p.info.prefix(300)))
				a.addButton(withTitle: connection ? "끊기" : "멈추기")
				a.addButton(withTitle: "취소")
				a.buttons[0].hasDestructiveAction = true
				if a.runModal() == .alertFirstButtonReturn { Task { await m.kill(p, connection: connection) } }
			}
		}
		if own { return [.disabled("iSQL 이 쓰는 연결입니다")] }
		return [
			p.command == "Query" ? .action("쿼리 멈추기 (KILL QUERY)…", confirm("이 쿼리를 멈출까요?", false)) : .disabled("쿼리 멈추기 (KILL QUERY)…"),
			.action("연결 끊기 (KILL)…", confirm("이 연결을 끊을까요?", true)),
		]
	}
	var cellMenuFirst: Bool { true }
}

/// 쿼리 통계 표 (오래 걸린 순)
@Observable
final class DigestSource: GridSource {
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private var list: [ServerDiagnostics.Digest] = []
	private(set) var gridVersion = 0
	func set(_ l: [ServerDiagnostics.Digest]) { list = l; gridVersion += 1 }

	var gridID: String { "digests" }
	var gridColumns: [GridColumn] {
		[GridColumn(key: "count", title: "횟수", numeric: true, width: 80),
		 GridColumn(key: "total", title: "총 시간", numeric: true, width: 90),
		 GridColumn(key: "avg", title: "평균", numeric: true, width: 80),
		 GridColumn(key: "examined", title: "읽은 행", numeric: true, width: 100),
		 GridColumn(key: "sent", title: "보낸 행", numeric: true, width: 90),
		 GridColumn(key: "schema", title: "DB", width: 100),
		 GridColumn(key: "sql", title: "쿼리 (값은 ? 로)", mono: true, width: 700)]
	}
	var rowCount: Int { list.count }
	var sortable: Bool { false }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		guard row < list.count else { return GridCell(text: "") }
		let d = list[row]
		switch col {
		case 0: return GridCell(text: d.count.formatted())
		case 1: return GridCell(text: ServerDiagnostics.seconds(d.totalSeconds))
		case 2: return GridCell(text: ServerDiagnostics.seconds(d.avgSeconds))
		case 3: return GridCell(text: d.rowsExamined.formatted())
		case 4: return GridCell(text: d.rowsSent.formatted())
		case 5: return GridCell(text: d.schema, dim: true)
		default: return GridCell(text: d.sql, tooltip: d.sql.count > 80 ? d.sql : nil)
		}
	}
}
