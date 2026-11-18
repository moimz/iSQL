import Foundation
import AppKit
import Observation

/// 서버 진단: 상태 요약·프로세스 목록·쿼리 통계의 모양과 표시 도움. 설정 창 "상태" 탭과 MCP(server_status·top_queries)가 같이 쓴다.
/// 읽기는 서버 종류의 meta (serverSummary·processes·topQueries) 가 한다 — 쿼리를 돌릴 방법(DBRun)만 받는다
enum ServerDiagnostics {
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

	struct Digest {
		let sql: String
		let schema: String
		let count: Int64
		let totalSeconds: Double
		let avgSeconds: Double
		let rowsExamined: Int64
		let rowsSent: Int64
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

	/// 프로세스 멈추기·끊기가 있는 서버 종류인지
	var canKill: Bool { session?.capabilities.processKill ?? true }

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
				ownConnectionID = (try? await session.meta.connectionID { [conn] in try await conn!.query($0) }) ?? nil
			}
			if appConnectionID == nil {
				appConnectionID = (try? await session.meta.connectionID(session.query)) ?? nil
			}
			guard let c = conn else { return }
			let run: DBRun = { sql in try await c.query(sql) }
			let s = try await session.meta.serverSummary(run)
			let now = Date()
			if let last = lastQuestions, now.timeIntervalSince(last.at) > 0.5 {
				// 이 탭이 읽는 쿼리(한 번에 3~4개)는 빼고 센다
				qps = max(0, Double(s.questions - last.count - 4) / now.timeIntervalSince(last.at))
			} else {
				qps = s.avgQPS
			}
			lastQuestions = (s.questions, now)
			summary = s
			processes = try await session.meta.processes(run)
			if !session.capabilities.queryDigests {
				// 쿼리 통계가 없는 서버 종류
				digests = []
				digestError = nil
			} else {
				do {
					digests = try await session.meta.topQueries(run, limit: 20)
					digestError = nil
				} catch {
					digests = []
					digestError = "쿼리 통계를 읽지 못했습니다 (performance_schema 가 꺼져 있거나 권한이 없습니다): \(error.localizedDescription)"
				}
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
			_ = try await session.query(session.dialect.kill(p.id, connection: connection))
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
		// 멈추기·끊기가 없는 서버 종류
		if m.canKill == false { return [] }
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
