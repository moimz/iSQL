import Foundation
import Network
import Observation

/// MCP 가 열어 줄 서버 범위 (iSQL 설정 > MCP)
enum MCPScope: String, CaseIterable, Identifiable {
	/// 지금 앞에 있는 iSQL 창에서 보고 있는 서버 하나
	case active
	/// iSQL 에서 접속한 모든 서버
	case connected
	/// 서버 목록의 모든 서버 (접속 안 한 서버는 키체인 비밀번호로 MCP 가 따로 접속)
	case all
	var id: String { rawValue }
	var label: String {
		switch self {
		case .active: "지금 보고 있는 창의 서버만"
		case .connected: "접속한 모든 서버"
		case .all: "서버 목록의 모든 서버"
		}
	}
}

/// MCP 로 실행할 수 있는 쿼리 (iSQL 설정 > MCP)
enum MCPPermission: String, CaseIterable, Identifiable {
	case readOnly
	/// 읽기 + INSERT + WHERE 있는 UPDATE + 컬럼 추가만 있는 ALTER TABLE (범위는 차차 정한다, 사용자 2026-11-16)
	case safe
	case full
	var id: String { rawValue }
	var label: String {
		switch self {
		case .readOnly: "읽기 전용"
		case .safe: "안전한 쿼리만"
		case .full: "모든 권한"
		}
	}
	var detail: String {
		switch self {
		case .readOnly: "SELECT · SHOW · DESCRIBE · EXPLAIN 만"
		case .safe: "읽기 + INSERT + WHERE 있는 UPDATE + 컬럼 추가(ALTER TABLE … ADD COLUMN)"
		case .full: "모든 SQL (DROP · TRUNCATE · DELETE 포함)"
		}
	}
}

/// 문장이 권한에 맞는지. 막히면 이유 글자
enum MCPPolicy {
	static func check(_ statement: String, _ p: MCPPermission) -> String? {
		if p == .full { return nil }
		let s = SQLSplitter.stripComments(statement).trimmingCharacters(in: .whitespacesAndNewlines)
		let up = s.uppercased()
		let first = up.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
		func has(_ pattern: String) -> Bool { up.range(of: pattern, options: .regularExpression) != nil }

		// 읽기: SELECT(파일로 쓰기 빼고)·SHOW·DESCRIBE·EXPLAIN·USE, WITH … SELECT
		let writesFile = has("\\bINTO\\s+(OUTFILE|DUMPFILE)\\b")
		switch first {
		case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "USE", "HELP":
			if !writesFile { return nil }
		case "WITH":
			if !writesFile && !has("\\b(INSERT|UPDATE|DELETE|REPLACE)\\b") { return nil }
		default: break
		}
		let readOnlyReason = "읽기 전용이라 실행하지 않았습니다 (iSQL 설정 > MCP 의 쿼리 권한). 허용: SELECT·SHOW·DESCRIBE·EXPLAIN"
		if p == .readOnly { return readOnlyReason }

		// 안전한 쿼리만
		let safeReason = "'안전한 쿼리만' 이라 실행하지 않았습니다 (iSQL 설정 > MCP 의 쿼리 권한). 허용: 읽기, INSERT, WHERE 있는 UPDATE, ALTER TABLE … ADD COLUMN"
		switch first {
		case "INSERT":
			return nil
		case "UPDATE":
			return has("\\bWHERE\\b") ? nil : "WHERE 없는 UPDATE 는 " + safeReason
		case "ALTER":
			return alterAddsColumnsOnly(up) ? nil : "컬럼 추가가 아닌 ALTER 는 " + safeReason
		default:
			return safeReason
		}
	}

	/// ALTER TABLE t ADD [COLUMN] … , ADD … 처럼 컬럼 추가 절만 있는지
	private static func alterAddsColumnsOnly(_ up: String) -> Bool {
		guard let r = up.range(of: "^ALTER\\s+TABLE\\s+\\S+\\s+", options: .regularExpression) else { return false }
		let rest = String(up[r.upperBound...])
		// 괄호·따옴표 밖의 쉼표로 절을 나눈다
		var clauses: [String] = [], cur = "", depth = 0, quote: Character?
		for ch in rest {
			if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
			switch ch {
			case "'", "\"", "`": quote = ch; cur.append(ch)
			case "(": depth += 1; cur.append(ch)
			case ")": depth -= 1; cur.append(ch)
			case "," where depth == 0: clauses.append(cur); cur = ""
			default: cur.append(ch)
			}
		}
		clauses.append(cur)
		let notColumn = ["INDEX", "KEY", "PRIMARY", "UNIQUE", "CONSTRAINT", "FULLTEXT", "SPATIAL", "FOREIGN", "PARTITION", "CHECK"]
		for c in clauses {
			let words = c.split(whereSeparator: \.isWhitespace).map(String.init)
			guard words.first == "ADD", words.count >= 3 else { return false }
			if notColumn.contains(words[1]) { return false }
		}
		return true
	}
}

/// iSQL MCP 서버: 127.0.0.1 에서만 받는 Streamable HTTP(JSON-RPC, POST /mcp).
/// Claude Code: `claude mcp add --transport http isql http://127.0.0.1:<포트>/mcp`
/// 쿼리는 MCP 전용 연결로 한다 (USE 를 해도 앱 창의 쿼리 패널 기본 DB 가 안 바뀌게). 앱에서 접속한 서버는 그 SSH 터널을 같이 쓴다
@MainActor
@Observable
final class MCPServer {
	static let shared = MCPServer()

	enum Status: Equatable { case stopped, running(Int), failed(String) }
	private(set) var status: Status = .stopped

	// MARK: 설정 (UserDefaults, 이 맥에만)

	var enabled: Bool = UserDefaults.standard.bool(forKey: "mcp.enabled") {
		didSet { UserDefaults.standard.set(enabled, forKey: "mcp.enabled"); restart() }
	}
	var port: Int = UserDefaults.standard.object(forKey: "mcp.port") as? Int ?? 8766 {
		didSet { UserDefaults.standard.set(port, forKey: "mcp.port"); if oldValue != port { restart() } }
	}
	var scope: MCPScope = MCPScope(rawValue: UserDefaults.standard.string(forKey: "mcp.scope") ?? "") ?? .active {
		didSet { UserDefaults.standard.set(scope.rawValue, forKey: "mcp.scope") }
	}
	var permission: MCPPermission = MCPPermission(rawValue: UserDefaults.standard.string(forKey: "mcp.permission") ?? "") ?? .readOnly {
		didSet { UserDefaults.standard.set(permission.rawValue, forKey: "mcp.permission") }
	}

	var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

	/// 최근 요청 (설정 화면에 보인다)
	struct LogEntry: Identifiable {
		let id = UUID()
		let time = Date()
		let text: String
		let ok: Bool
	}
	private(set) var log: [LogEntry] = []
	private func note(_ text: String, ok: Bool = true) {
		log.insert(LogEntry(text: text, ok: ok), at: 0)
		if log.count > 50 { log.removeLast(log.count - 50) }
	}

	// MARK: 듣기

	@ObservationIgnored private var listener: NWListener?

	func startIfEnabled() { if enabled && listener == nil { start() } }

	private func restart() {
		stop()
		if enabled { start() }
	}

	private func stop() {
		listener?.cancel()
		listener = nil
		status = .stopped
	}

	private func start() {
		guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1024 else {
			status = .failed("포트는 1024~65535")
			return
		}
		do {
			let params = NWParameters.tcp
			params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
			params.allowLocalEndpointReuse = true
			let l = try NWListener(using: params)
			l.newConnectionHandler = { [weak self] c in
				Task { @MainActor in self?.accept(c) }
			}
			l.stateUpdateHandler = { [weak self] st in
				Task { @MainActor in
					guard let self else { return }
					switch st {
					case .ready: self.status = .running(self.port)
					case .failed(let e): self.status = .failed(e.localizedDescription); self.listener = nil
					default: break
					}
				}
			}
			l.start(queue: .main)
			listener = l
		} catch {
			status = .failed(error.localizedDescription)
		}
	}

	// MARK: HTTP (요청 하나 받고 답하고 닫는다)

	private func accept(_ c: NWConnection) {
		c.start(queue: .main)
		receive(c, buffer: Data())
	}

	private func receive(_ c: NWConnection, buffer: Data) {
		c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
			Task { @MainActor in
				guard let self else { return }
				var buf = buffer
				if let data { buf.append(data) }
				if let req = HTTPRequest(buf) {
					await self.respond(c, req)
				} else if done || error != nil || buf.count > 32 << 20 {
					c.cancel()
				} else {
					self.receive(c, buffer: buf)
				}
			}
		}
	}

	private func respond(_ c: NWConnection, _ req: HTTPRequest) async {
		// 브라우저가 이 포트로 몰래 요청하는 것(DNS 리바인딩) 막기: Origin 이 있으면 localhost 만
		if let origin = req.headers["origin"], !(origin.contains("://127.0.0.1") || origin.contains("://localhost")) {
			send(c, status: "403 Forbidden", body: Data())
			return
		}
		guard req.path.hasPrefix("/mcp") else { send(c, status: "404 Not Found", body: Data()); return }
		switch req.method {
		case "POST": break
		case "DELETE": send(c, status: "200 OK", body: Data()); return
		default: send(c, status: "405 Method Not Allowed", body: Data()); return   // 서버가 먼저 보내는 SSE 는 안 쓴다
		}
		guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
			send(c, status: "400 Bad Request", json: rpcError(nil, -32700, "JSON 을 읽지 못했습니다"))
			return
		}
		if let batch = json as? [[String: Any]] {
			var out: [[String: Any]] = []
			for m in batch { if let r = await handle(m) { out.append(r) } }
			if out.isEmpty { send(c, status: "202 Accepted", body: Data()) } else { send(c, status: "200 OK", json: out) }
		} else if let m = json as? [String: Any] {
			if let r = await handle(m) { send(c, status: "200 OK", json: r) } else { send(c, status: "202 Accepted", body: Data()) }
		} else {
			send(c, status: "400 Bad Request", json: rpcError(nil, -32600, "잘못된 요청"))
		}
	}

	private func send(_ c: NWConnection, status: String, json: Any) {
		let body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data()
		send(c, status: status, body: body, type: "application/json")
	}

	private func send(_ c: NWConnection, status: String, body: Data, type: String? = nil) {
		var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
		if let type { head += "Content-Type: \(type)\r\n" }
		head += "\r\n"
		var out = Data(head.utf8)
		out.append(body)
		c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
	}

	// MARK: JSON-RPC

	private func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
		["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
	}

	/// 알림(id 없음)은 nil
	private func handle(_ m: [String: Any]) async -> [String: Any]? {
		let id = m["id"]
		let method = m["method"] as? String ?? ""
		let params = m["params"] as? [String: Any] ?? [:]
		guard id != nil else { return nil }
		func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
		switch method {
		case "initialize":
			let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
			return ok([
				"protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
				"capabilities": ["tools": [String: Any]()],
				"serverInfo": ["name": "iSQL", "version": version],
				"instructions": "iSQL 앱으로 MySQL 서버에 접근한다. 먼저 list_servers 로 쓸 수 있는 서버와 쿼리 권한을 확인한다.",
			])
		case "ping":
			return ok([:])
		case "tools/list":
			return ok(["tools": Self.tools])
		case "tools/call":
			let name = params["name"] as? String ?? ""
			let args = params["arguments"] as? [String: Any] ?? [:]
			do {
				let text = try await call(name, args)
				return ok(["content": [["type": "text", "text": text]], "isError": false])
			} catch {
				note("\(name): \(error.localizedDescription)", ok: false)
				return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
			}
		default:
			return rpcError(id, -32601, "모르는 메서드: \(method)")
		}
	}

	// MARK: 도구

	private static let serverArg: [String: Any] = ["type": "string", "description": "서버 이름 또는 id (list_servers). 범위가 '지금 보고 있는 창의 서버만' 이면 생략 가능"]

	private static let tools: [[String: Any]] = [
		["name": "list_servers",
		 "description": "iSQL 이 MCP 에 열어 준 MySQL 서버 목록과 지금 설정(접근 범위·쿼리 권한)",
		 "inputSchema": ["type": "object", "properties": [String: Any]()]],
		["name": "list_databases",
		 "description": "서버의 데이터베이스 목록",
		 "inputSchema": ["type": "object", "properties": ["server": serverArg]]],
		["name": "list_tables",
		 "description": "데이터베이스의 테이블·뷰 목록 (이름, 종류, 어림 행 수, 코멘트)",
		 "inputSchema": ["type": "object", "properties": ["server": serverArg, "database": ["type": "string"]], "required": ["database"]]],
		["name": "describe_table",
		 "description": "테이블 구조 (SHOW CREATE TABLE)",
		 "inputSchema": ["type": "object", "properties": ["server": serverArg, "database": ["type": "string"], "table": ["type": "string"]], "required": ["database", "table"]]],
		["name": "run_query",
		 "description": "SQL 실행 (여러 문장은 ; 로). 쿼리 권한(list_servers)을 넘는 문장이 하나라도 있으면 아무것도 실행하지 않는다. 결과 행은 max_rows(기본 200, 최대 5000)까지",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"sql": ["type": "string"],
		 	"database": ["type": "string", "description": "이 DB 로 USE 한 뒤 실행 (MCP 전용 연결이라 앱 화면에는 영향 없음)"],
		 	"max_rows": ["type": "integer"],
		 ], "required": ["sql"]]],
		["name": "server_status",
		 "description": "서버 상태 진단: 가동 시간·연결 수/최대·실행 중 스레드·평균 초당 쿼리·느린 쿼리 수·InnoDB 버퍼 풀 적중률과 사용량, 그리고 프로세스 목록(10초 넘게 도는 쿼리·잠금 대기 표시). '이 서버 왜 느려?' 같은 질문에 먼저 쓴다. 쿼리 권한과 상관없이 읽기만 한다",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"include_sleeping": ["type": "boolean", "description": "놀고 있는(Sleep) 연결도 프로세스 목록에 넣기 (기본 false)"],
		 ]]],
		["name": "top_queries",
		 "description": "performance_schema 의 쿼리별 누적 통계에서 총 시간이 오래 걸린 쿼리 (값은 ? 로 묶인 형태): 횟수·총 시간·평균·읽은 행·보낸 행. 읽은 행이 보낸 행보다 훨씬 많으면 인덱스를 못 타는 쿼리일 수 있다",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"limit": ["type": "integer", "description": "몇 개 (기본 20, 최대 200)"],
		 ]]],
	]

	private struct MCPFailure: LocalizedError {
		let errorDescription: String?
		init(_ s: String) { errorDescription = s }
	}

	private func call(_ name: String, _ a: [String: Any]) async throws -> String {
		switch name {
		case "list_servers":
			note("list_servers")
			return json([
				"scope": scope.label,
				"permission": permission.label + " — " + permission.detail,
				"servers": targets().map { t in
					var d: [String: Any] = ["name": t.server.displayName, "id": t.server.id.uuidString,
					                        "connection": t.server.subtitle,
					                        "connected_in_app": t.session != nil]
					if let v = t.session?.serverVersion, !v.isEmpty { d["version"] = v }
					return d
				},
			])
		case "list_databases":
			let t = try target(a)
			let names = try await t.meta.databaseNames { [try await self.run(t, $0)] }
			note("list_databases · \(t.server.displayName)")
			return json(names)
		case "list_tables":
			let t = try target(a)
			let db = try string(a, "database")
			let list = try await t.meta.tableList({ [try await self.run(t, $0)] }, schema: db)
			note("list_tables · \(t.server.displayName) · \(db)")
			return json(list.map { row in
				["name": row.name, "type": row.isView ? "view" : "table",
				 "rows_approx": row.approxRows ?? NSNull(), "comment": row.comment] as [String: Any]
			})
		case "describe_table":
			let t = try target(a)
			let db = try string(a, "database"), table = try string(a, "table")
			let ddl = try await t.meta.createStatement({ [try await self.run(t, $0)] }, .table, schema: db, name: table)
			note("describe_table · \(t.server.displayName) · \(db).\(table)")
			return ddl ?? ""
		case "run_query":
			let t = try target(a)
			let sql = try string(a, "sql")
			let maxRows = min(max((a["max_rows"] as? Int) ?? 200, 1), 5000)
			let statements = SQLSplitter.split(sql).map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			guard !statements.isEmpty else { throw MCPFailure("실행할 SQL 이 없습니다") }
			for s in statements {
				if let why = MCPPolicy.check(s, permission) {
					note("막음 · \(t.server.displayName) · \(s.prefix(80))", ok: false)
					throw MCPFailure(why + "\n막힌 문장: " + String(s.prefix(200)))
				}
			}
			let c = try await connection(t)
			if let db = a["database"] as? String, !db.isEmpty { _ = try await c.query(t.dialect.use(db)) }
			var out: [[String: Any]] = []
			for s in statements {
				for r in try await c.query(s) { out.append(describe(r, maxRows: maxRows)) }
			}
			note("run_query · \(t.server.displayName) · \(statements.first!.prefix(80))\(statements.count > 1 ? " 외 \(statements.count - 1)개" : "")")
			// 앱에서 접속한 서버의 구조를 바꿨으면 왼쪽 목록을 다시 읽는다
			if let session = t.session, statements.contains(where: { Self.changesSchema($0) }) {
				Task { try? await session.loadSchema() }
			}
			return json(out.count == 1 ? out[0] : out)
		case "server_status":
			let t = try target(a)
			let run: ServerDiagnostics.Run = { sql in try await self.run(t, sql) }
			let s = try await ServerDiagnostics.summary(run)
			let sleeping = (a["include_sleeping"] as? Bool) ?? false
			let procs = try await ServerDiagnostics.processes(run).filter { sleeping || $0.command != "Sleep" }
			note("server_status · \(t.server.displayName)")
			var d: [String: Any] = [
				"version": s.version,
				"uptime_seconds": s.uptime,
				"connections": ["connected": s.connected, "running": s.running, "max": s.maxConnections, "near_limit": s.connectionsTight],
				"avg_queries_per_second": ServerDiagnostics.decimal(s.avgQPS, 1),
				"slow_queries": s.slowQueries,
				"long_query_time": ServerDiagnostics.trimNumber(s.longQueryTime),
				"innodb_buffer_pool": ["used": ServerDiagnostics.bytes(s.bufferUsed), "size": ServerDiagnostics.bytes(s.bufferSize),
				                       "hit_rate_percent": s.bufferHit.map { ServerDiagnostics.decimal($0 * 100, 2) } ?? NSNull(), "low": s.bufferLow],
				"bytes_received": s.received, "bytes_sent": s.sent,
			]
			d["processes"] = procs.prefix(100).map { p -> [String: Any] in
				["id": p.id, "user": p.user, "host": p.host, "db": p.db, "command": p.command, "time_seconds": p.time,
				 "state": p.state, "query": String(p.info.prefix(500)), "long_running": p.long, "waiting_lock": p.waitingLock]
			}
			return json(d)
		case "top_queries":
			let t = try target(a)
			let limit = min(max((a["limit"] as? Int) ?? 20, 1), 200)
			let list = try await ServerDiagnostics.topQueries({ sql in try await self.run(t, sql) }, limit: limit)
			note("top_queries · \(t.server.displayName)")
			return json(list.map { q -> [String: Any] in
				["query": String(q.sql.prefix(1000)), "database": q.schema, "count": q.count,
				 "total_seconds": ServerDiagnostics.decimal(q.totalSeconds, 3), "avg_seconds": ServerDiagnostics.decimal(q.avgSeconds, 4),
				 "rows_examined": q.rowsExamined, "rows_sent": q.rowsSent]
			})
		default:
			throw MCPFailure("모르는 도구: \(name)")
		}
	}

	private static func changesSchema(_ s: String) -> Bool {
		let up = SQLSplitter.stripComments(s).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		return ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE"].contains { up.hasPrefix($0 + " ") }
	}

	private func string(_ a: [String: Any], _ key: String) throws -> String {
		guard let s = a[key] as? String, !s.isEmpty else { throw MCPFailure("\(key) 가 필요합니다") }
		return s
	}

	private func describe(_ r: QueryResult, maxRows: Int) -> [String: Any] {
		guard r.isResultSet else {
			var d: [String: Any] = ["affected_rows": r.affectedRows]
			if r.lastInsertID > 0 { d["last_insert_id"] = r.lastInsertID }
			if !r.info.isEmpty { d["info"] = r.info }
			return d
		}
		let rows = r.rows.prefix(maxRows).map { row in
			row.map { v -> Any in
				switch v {
				case .null: return NSNull()
				case .text(let s): return s
				case .bytes(let d): return d.count <= 64 ? "0x" + d.map { String(format: "%02X", $0) }.joined() : "(바이너리 \(d.count)바이트)"
				}
			}
		}
		return ["columns": r.columns.map(\.name), "rows": rows, "row_count": r.rows.count, "truncated": r.rows.count > maxRows]
	}

	private func json(_ v: Any) -> String {
		guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return "\(v)" }
		return String(decoding: d, as: UTF8.self)
	}

	// MARK: 서버 고르기·연결

	private struct Target {
		let server: Server
		/// 앱에서 접속해 있으면 그 세션
		let session: Session?
		var dialect: any SQLDialect { (server.sqlKind ?? .mysql).dialect }
		var meta: any SQLMeta { (server.sqlKind ?? .mysql).meta }
	}

	/// 지금 범위에서 MCP 에 열린 서버들
	private func targets() -> [Target] {
		let app = AppState.shared
		switch scope {
		case .active:
			guard let s = app.activeSession, let srv = s.server else { return [] }
			return [Target(server: srv, session: s)]
		case .connected:
			return app.connectedSessions.compactMap { s in s.server.map { Target(server: $0, session: s) } }
		case .all:
			var list = app.connectedSessions.compactMap { s in s.server.map { Target(server: $0, session: s) } }
			let have = Set(list.map(\.server.id))
			for srv in app.store?.servers ?? [] where !have.contains(srv.id) { list.append(Target(server: srv, session: nil)) }
			return list
		}
	}

	private func target(_ a: [String: Any]) throws -> Target {
		let list = targets()
		guard !list.isEmpty else {
			throw MCPFailure(scope == .all ? "서버 목록이 비어 있습니다" : "iSQL 에서 접속한 서버가 없습니다 (범위: \(scope.label))")
		}
		guard let key = (a["server"] as? String)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
			if list.count == 1 { return list[0] }
			throw MCPFailure("server 를 정해 주세요: " + list.map(\.server.displayName).joined(separator: ", "))
		}
		if let t = list.first(where: { $0.server.id.uuidString.caseInsensitiveCompare(key) == .orderedSame
		                               || $0.server.displayName.caseInsensitiveCompare(key) == .orderedSame }) { return t }
		throw MCPFailure("'\(key)' 는 지금 범위(\(scope.label))에 없습니다. 쓸 수 있는 서버: " + list.map(\.server.displayName).joined(separator: ", "))
	}

	/// 서버마다 MCP 전용 연결 (끊겼으면 다시)
	@ObservationIgnored private var conns: [UUID: (conn: any DBConnection, tunnel: SSHTunnel?)] = [:]

	private func connection(_ t: Target) async throws -> any DBConnection {
		if let c = conns[t.server.id], c.conn.isOpen { return c.conn }
		conns[t.server.id]?.tunnel?.close()
		conns[t.server.id] = nil
		if let s = t.session {
			let c = try await s.sideConnection(purpose: "MCP")
			conns[t.server.id] = (c, nil)
			return c
		}
		// 앱에서 접속 안 한 서버 (범위: 서버 목록의 모든 서버): 키체인 비밀번호로 직접
		let (tunnel, c) = try await Session.open(t.server, mysqlPassword: Keychain.get(t.server.mysqlPasswordKey),
		                                         sshSecret: Keychain.get(t.server.sshSecretKey)) { _ in }
		note("접속 · \(t.server.displayName)")
		conns[t.server.id] = (c, tunnel)
		return c
	}

	/// 한 번 실패하면 연결을 새로 해서 한 번 더 (앱에서 접속을 끊었다 다시 했거나 서버가 끊은 경우)
	private func run(_ t: Target, _ sql: String) async throws -> QueryResult {
		do {
			return try await connection(t).rows(sql)
		} catch where t.dialect.isServerError(error) {
			throw error
		} catch {
			conns[t.server.id]?.conn.close()
			conns[t.server.id] = nil
			return try await connection(t).rows(sql)
		}
	}
}

/// HTTP 요청 하나 (다 받았을 때만 만들어진다)
private struct HTTPRequest {
	let method: String
	let path: String
	let headers: [String: String]
	let body: Data

	init?(_ data: Data) {
		guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
		var lines = head.components(separatedBy: "\r\n")
		let first = lines.removeFirst().split(separator: " ")
		guard first.count >= 2 else { return nil }
		var h: [String: String] = [:]
		for l in lines {
			guard let i = l.firstIndex(of: ":") else { continue }
			h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
		}
		let length = Int(h["content-length"] ?? "0") ?? 0
		let bodyStart = end.upperBound
		guard data.count - bodyStart >= length else { return nil }
		method = String(first[0])
		path = String(first[1])
		headers = h
		body = data.subdata(in: bodyStart..<(bodyStart + length))
	}
}
