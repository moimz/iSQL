import Foundation
import AppKit
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
	static func check(_ statement: String, _ p: MCPPermission, _ syntax: SQLSyntax) -> String? {
		if p == .full { return nil }
		let s = SQLSplitter.stripComments(statement, syntax).trimmingCharacters(in: .whitespacesAndNewlines)
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
			return alterAddsColumnsOnly(up, syntax) ? nil : "컬럼 추가가 아닌 ALTER 는 " + safeReason
		default:
			return safeReason
		}
	}

	/// ALTER TABLE t ADD [COLUMN] … , ADD … 처럼 컬럼 추가 절만 있는지
	private static func alterAddsColumnsOnly(_ up: String, _ syntax: SQLSyntax) -> Bool {
		guard let r = up.range(of: "^ALTER\\s+TABLE\\s+\\S+\\s+", options: .regularExpression) else { return false }
		let rest = String(up[r.upperBound...])
		// 괄호·따옴표 밖의 쉼표로 절을 나눈다
		var clauses: [String] = [], cur = "", depth = 0, quote: Character?
		for ch in rest {
			if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
			if let u = ch.utf16.first, ch.utf16.count == 1, syntax.opensQuote(u) { quote = ch; cur.append(ch); continue }
			switch ch {
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
				"instructions": "iSQL 앱으로 DB 서버에 접근한다. 먼저 list_servers 로 쓸 수 있는 서버와 쿼리 권한을 확인한다.",
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
		 "description": "iSQL 이 MCP 에 열어 준 DB 서버 목록과 지금 설정(접근 범위·쿼리 권한)",
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
		["name": "create_private_view",
		 "description": "사용자의 '나만 보는 뷰' 를 만든다: 서버에 CREATE VIEW 하지 않고 SELECT 를 이름 붙여 iSQL 에 저장(iCloud, 사용자의 맥끼리 공유)하고, 그 서버 창 사이드바의 DB 아래에 넣은 뒤 탭으로 열어 결과를 보여 준다. 사용자가 '이런 데이터를 보고 싶다' 고 하면 list_tables · describe_table 로 구조를 보고 조인 · 서브쿼리를 짜서 이것으로 띄운다(쿼리 패널에 넣지 않아 사용자의 쿼리와 섞이지 않음). SELECT(WITH) 한 문장만, 저장 전에 한 번 실행해 오류를 확인한다. 앱에서 접속한 서버만. 이름 앞에 ✨ 가 붙는다",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"database": ["type": "string", "description": "사이드바에서 뷰가 들어갈 DB (쿼리 안의 DB 안 붙인 테이블도 이 DB 로 푼다)"],
		 	"name": ["type": "string", "description": "뷰 이름 (짧게, 한국어 가능)"],
		 	"sql": ["type": "string"],
		 ], "required": ["database", "name", "sql"]]],
		["name": "update_private_view",
		 "description": "나만 보는 뷰의 SQL 이나 이름을 바꾸고 그 탭을 열어 다시 실행한다 (결과가 원하던 게 아니어서 고칠 때). view 는 list_private_views 의 id 또는 이름",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"view": ["type": "string"],
		 	"sql": ["type": "string"],
		 	"name": ["type": "string"],
		 ], "required": ["view"]]],
		["name": "open_table",
		 "description": "앱 화면에 테이블을 띄운다: 그 서버 창을 앞으로, 테이블 탭을 열고 데이터 또는 구조 보기. where 를 주면 조건 줄에 넣어 걸러 보여 준다. 사용자가 '보여 줘' 할 때 쓴다. 앱에서 접속한 서버만",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"database": ["type": "string"],
		 	"table": ["type": "string"],
		 	"view": ["type": "string", "enum": ["data", "structure"], "description": "기본 data"],
		 	"where": ["type": "string", "description": "WHERE 뒤 조건 (WHERE 는 빼고). 빈 글자면 조건을 지운다"],
		 ], "required": ["database", "table"]]],
		["name": "open_database",
		 "description": "앱 화면에 DB 개요 탭을 띄운다 (테이블 목록 · 행 수 · 크기). 앱에서 접속한 서버만",
		 "inputSchema": ["type": "object", "properties": ["server": serverArg, "database": ["type": "string"]], "required": ["database"]]],
		["name": "refresh",
		 "description": "앱에 열린 탭을 다시 읽는다 (⌘R 과 같음). run_query 뒤에는 바뀐 테이블의 탭을 자동으로 다시 읽으니, 프로시저 안에서 바뀌었을 때처럼 자동으로 못 잡는 경우에 쓴다. table 을 빼면 그 DB 의 탭, database 도 빼면 모든 테이블 탭. 저장 안 한 편집이 있는 탭은 건너뛰고 알려 준다",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"database": ["type": "string"],
		 	"table": ["type": "string"],
		 	"structure": ["type": "boolean", "description": "구조 · 사이드바 목록까지 다시 읽기 (기본 true)"],
		 ]]],
		["name": "import_excel",
		 "description": "엑셀(.xlsx) 파일을 iSQL 의 엑셀 가져오기로 새 테이블에 넣고 그 테이블 탭을 연다. 컬럼 형식은 앱이 값을 보고 정한다(첫 행은 컬럼 이름). 같은 이름 테이블이 있으면 하지 않는다. 쿼리 권한이 읽기 전용이면 안 된다. 앱에서 접속한 서버만",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"path": ["type": "string", "description": "이 맥의 .xlsx 파일 전체 경로"],
		 	"database": ["type": "string"],
		 	"table": ["type": "string", "description": "만들 테이블 이름"],
		 	"sheet": ["type": "string", "description": "시트 이름 (기본 첫 시트)"],
		 	"header": ["type": "boolean", "description": "첫 행이 컬럼 이름인지 (기본 true)"],
		 	"add_id": ["type": "boolean", "description": "자동 증가 id 기본 키 컬럼 붙이기 (기본 true, 있어야 iSQL 에서 행을 고칠 수 있다)"],
		 ], "required": ["path", "database", "table"]]],
		["name": "show_query",
		 "description": "앱의 쿼리 패널 [MCP] 칸에 SQL 을 넣어 보여 준다: 그 서버 창을 앞으로, 쿼리 패널을 열고 [MCP] 칸으로 바꿔 끝에 '-- ✨ 시각 · 설명' 과 함께 붙이고 그 SQL 을 골라 둔다(사용자는 ⌘↩ 로 실행). 사용자의 [사용자] 칸 쿼리와 섞이지 않고, [MCP] 칸은 그 맥에만 남는다(최근 50개). 사용자가 검토하고 직접 돌릴 쿼리(변경 · 계정 · 비밀번호 자리를 채워야 하는 쿼리, 한 번 보고 고칠 쿼리)에 쓴다. 넣기만 할 때는 쿼리 권한과 상관없다. run=true 면 바로 실행해 결과를 띄우되 쿼리 권한을 따른다(넘으면 실행하지 않고 넣기만 하고 not_run 으로 알려 준다). 두고두고 볼 데이터는 create_private_view. 앱에서 접속한 서버만",
		 "inputSchema": ["type": "object", "properties": [
		 	"server": serverArg,
		 	"sql": ["type": "string"],
		 	"database": ["type": "string", "description": "쿼리 패널의 기본 DB (USE)"],
		 	"note": ["type": "string", "description": "무슨 쿼리인지 한 줄 (주석으로 붙는다)"],
		 	"run": ["type": "boolean", "description": "바로 실행 (기본 false, 쿼리 권한을 따른다)"],
		 ], "required": ["sql"]]],
		["name": "list_private_views",
		 "description": "서버의 나만 보는 뷰 목록 (id, 이름, DB, SQL)",
		 "inputSchema": ["type": "object", "properties": ["server": serverArg]]],
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
			let statements = SQLSplitter.split(sql, t.dialect.syntax).map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			guard !statements.isEmpty else { throw MCPFailure("실행할 SQL 이 없습니다") }
			for s in statements {
				if let why = MCPPolicy.check(s, permission, t.dialect.syntax) {
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
			// 앱에서 접속한 서버면 바뀐 테이블의 열린 탭 · 사이드바를 다시 읽는다 (저장 안 한 편집이 있는 탭은 건너뜀)
			if let session = t.session, session.isConnected {
				let skipped = await refreshAfter(statements, db: a["database"] as? String, t, session)
				if !skipped.isEmpty {
					var d: [String: Any] = ["results": out.count == 1 ? out[0] : out]
					d["app_not_refreshed"] = "저장 안 한 편집이 있어 다시 읽지 않은 탭: " + skipped.joined(separator: ", ")
					return json(d)
				}
			}
			return json(out.count == 1 ? out[0] : out)
		case "create_private_view":
			let t = try target(a)
			let session = try appSession(t)
			let db = try string(a, "database"), sql = try viewSQL(a, t)
			let raw = try string(a, "name").trimmingCharacters(in: .whitespacesAndNewlines)
			try await tryViewSQL(t, db: db, sql: sql)
			let v = session.addPrivateView(name: raw.hasPrefix(Self.aiMark) ? raw : Self.aiMark + raw, schema: db, sql: sql)
			show(v, in: session)
			note("create_private_view · \(t.server.displayName) · \(db) · \(v.name)")
			return json(["created": true, "id": v.id.uuidString, "name": v.name, "database": db])
		case "update_private_view":
			let t = try target(a)
			let session = try appSession(t)
			let key = try string(a, "view")
			guard let old = session.privateViews.first(where: { $0.id.uuidString == key || $0.name == key || $0.name == Self.aiMark + key }) else {
				throw MCPFailure("나만 보는 뷰 '\(key)' 가 없습니다 (list_private_views)")
			}
			var sql: String?
			if a["sql"] != nil {
				sql = try viewSQL(a, t)
				try await tryViewSQL(t, db: old.schema, sql: sql!)
			}
			let name = (a["name"] as? String).map { n in n.hasPrefix(Self.aiMark) ? n : Self.aiMark + n }
			guard let v = session.updatePrivateView(old.id, name: name, sql: sql) else { throw MCPFailure("뷰를 바꾸지 못했습니다") }
			show(v, in: session)
			note("update_private_view · \(t.server.displayName) · \(v.name)")
			return json(["updated": true, "id": v.id.uuidString, "name": v.name, "database": v.schema])
		case "open_table":
			let t = try target(a)
			let session = try appSession(t)
			let db = try string(a, "database"), name = try string(a, "table")
			if session.tables.first(where: { $0.schema == db && $0.name == name }) == nil { try? await session.loadSchema() }
			guard let info = session.tables.first(where: { $0.schema.caseInsensitiveCompare(db) == .orderedSame && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
				throw MCPFailure("\(db).\(name) 테이블이 없습니다")
			}
			front(session)
			session.expanded.insert(info.schema)
			session.openTab(info)
			guard let tab = session.activeTab, let d = session.data(tab: tab) else { return json(["opened": true]) }
			d.mode = (a["view"] as? String) == "structure" ? .structure : .data
			if let w = a["where"] as? String {
				let clause = w.trimmingCharacters(in: .whitespacesAndNewlines)
				if d.hasChanges { throw MCPFailure("탭은 열었지만 저장 안 한 편집이 있어 조건을 바꾸지 않았습니다") }
				// 조건 줄은 처음 보일 때 빈 줄을 만들며 WHERE 를 다시 만든다(비워짐) → 먼저 만들어 둔다
				d.prepareFilters()
				d.whereClause = clause
				d.showFilter = !clause.isEmpty
				d.mode = .data
				if d.loaded { await d.applyWhere() }
			}
			note("open_table · \(t.server.displayName) · \(info.id)")
			return json(["opened": true, "table": info.id, "view": d.mode == .structure ? "structure" : "data", "where": d.whereClause])
		case "open_database":
			let t = try target(a)
			let session = try appSession(t)
			let db = try string(a, "database")
			guard session.databases.contains(db) else { throw MCPFailure("\(db) 데이터베이스가 없습니다") }
			front(session)
			session.expanded.insert(db)
			session.openDatabase(db)
			note("open_database · \(t.server.displayName) · \(db)")
			return json(["opened": true, "database": db])
		case "refresh":
			let t = try target(a)
			let session = try appSession(t)
			let db = (a["database"] as? String).flatMap { $0.isEmpty ? nil : $0 }
			let table = (a["table"] as? String).flatMap { $0.isEmpty ? nil : $0 }
			let skipped = await session.externalChange(schema: db, table: table, structure: (a["structure"] as? Bool) ?? true, dropped: false)
			note("refresh · \(t.server.displayName)\(db.map { " · " + $0 } ?? "")\(table.map { "." + $0 } ?? "")")
			var d: [String: Any] = ["refreshed": true]
			if !skipped.isEmpty { d["not_refreshed"] = "저장 안 한 편집이 있어 다시 읽지 않은 탭: " + skipped.joined(separator: ", ") }
			return json(d)
		case "import_excel":
			let t = try target(a)
			let session = try appSession(t)
			guard permission != .readOnly else { throw MCPFailure("쿼리 권한이 읽기 전용이라 테이블을 만들 수 없습니다 (iSQL 설정 > MCP)") }
			let path = (try string(a, "path") as NSString).expandingTildeInPath
			let db = try string(a, "database"), name = try string(a, "table").trimmingCharacters(in: .whitespaces)
			guard FileManager.default.fileExists(atPath: path) else { throw MCPFailure("파일이 없습니다: \(path)") }
			guard session.databases.contains(db) else { throw MCPFailure("\(db) 데이터베이스가 없습니다") }
			if session.tables.contains(where: { $0.schema == db && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
				throw MCPFailure("\(db).\(name) 테이블이 이미 있습니다 (덮어쓰지 않음)")
			}
			let job = ExcelImportJob(url: URL(fileURLWithPath: path), session: session, schema: db, table: nil)
			func settle() async { for _ in 0..<600 { try? await Task.sleep(for: .milliseconds(50)); if !job.loading { break } } }
			await settle()
			if let e = job.loadError { throw MCPFailure("엑셀을 읽지 못했습니다: \(e)") }
			if let s = a["sheet"] as? String, !s.isEmpty {
				guard let i = job.sheets.firstIndex(where: { $0.name == s }) else { throw MCPFailure("시트 '\(s)' 가 없습니다. 시트: " + job.sheets.map(\.name).joined(separator: ", ")) }
				job.sheetIndex = i
				await settle()
			}
			if let h = a["header"] as? Bool { job.header = h }
			if let id = a["add_id"] as? Bool { job.addID = id }
			job.target = .newTable
			job.newName = name
			guard job.canRun else { throw MCPFailure("가져올 수 없습니다 (빈 시트이거나 이름이 맞지 않음)") }
			front(session)
			await job.run()
			if job.isError { throw MCPFailure(job.message ?? "가져오기 실패") }
			note("import_excel · \(t.server.displayName) · \(db).\(name)")
			return json(["imported": true, "table": db + "." + name, "message": job.message ?? "", "sql": job.createSQL])
		case "show_query":
			let t = try target(a)
			let session = try appSession(t)
			guard let panel = session.queryPanel else { throw MCPFailure("쿼리 패널이 없습니다") }
			let sql = try string(a, "sql")
			var run = (a["run"] as? Bool) ?? false
			let statements = SQLSplitter.split(sql, t.dialect.syntax).map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			// 실행이 쿼리 권한을 넘으면 실행하지 않고 넣기만 한다 (사용자가 검토하고 직접 실행)
			var blocked: String?
			if run, let s = statements.first(where: { MCPPolicy.check($0, permission, t.dialect.syntax) != nil }) {
				blocked = MCPPolicy.check(s, permission, t.dialect.syntax)! + " 막힌 문장: " + String(s.prefix(200))
				run = false
			}
			front(session)
			if let db = a["database"] as? String, !db.isEmpty, session.databases.contains(db) { panel.database = db }
			panel.open = true
			panel.appendFromMCP(sql, note: a["note"] as? String)
			note("show_query · \(t.server.displayName) · \(sql.prefix(80))")
			guard run else {
				var d: [String: Any] = ["shown": true, "ran": false]
				if let blocked { d["not_run"] = blocked + " — 쿼리 패널 [MCP] 칸에 넣어 두었으니 사용자가 검토하고 ⌘↩ 로 직접 실행할 수 있다" }
				return json(d)
			}
			await panel.run(statements)
			var d: [String: Any] = ["shown": true, "ran": true, "error": panel.isError,
			                        "results": panel.outputs.map { ["rows": $0.totalText, "seconds": $0.elapsed.map { String(format: "%.2f", $0) } ?? ""] }]
			if let m = panel.message { d["message"] = m }
			return json(d)
		case "list_private_views":
			let t = try target(a)
			let session = try appSession(t)
			note("list_private_views · \(t.server.displayName)")
			return json(session.privateViews.map { ["id": $0.id.uuidString, "name": $0.name, "database": $0.schema, "sql": $0.sql] })
		case "server_status":
			let t = try target(a)
			guard t.capabilities.serverStatus else { throw MCPFailure("\(t.server.displayName) (\(t.server.kindLabel)) 는 서버 상태를 지원하지 않습니다") }
			let run: DBRun = { sql in [try await self.run(t, sql)] }
			let s = try await t.meta.serverSummary(run)
			let sleeping = (a["include_sleeping"] as? Bool) ?? false
			let procs = try await t.meta.processes(run).filter { sleeping || $0.command != "Sleep" }
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
			]
			if t.capabilities.packetAndPageCounts {
				// SQL Server: 바이트가 아니라 패킷 수, 느린 쿼리는 계획 캐시에서 평균 1초 넘는 쿼리의 실행 횟수
				d["packets_received"] = s.received; d["packets_sent"] = s.sent
				d["buffer_pool"] = d.removeValue(forKey: "innodb_buffer_pool")
			} else {
				d["bytes_received"] = s.received; d["bytes_sent"] = s.sent
			}
			d["processes"] = procs.prefix(100).map { p -> [String: Any] in
				["id": p.id, "user": p.user, "host": p.host, "db": p.db, "command": p.command, "time_seconds": p.time,
				 "state": p.state, "query": String(p.info.prefix(500)), "long_running": p.long, "waiting_lock": p.waitingLock]
			}
			return json(d)
		case "top_queries":
			let t = try target(a)
			guard t.capabilities.queryDigests else { throw MCPFailure("\(t.server.displayName) (\(t.server.kindLabel)) 는 쿼리 통계를 지원하지 않습니다") }
			let limit = min(max((a["limit"] as? Int) ?? 20, 1), 200)
			let list = try await t.meta.topQueries({ sql in [try await self.run(t, sql)] }, limit: limit)
			note("top_queries · \(t.server.displayName)")
			let pages = t.capabilities.packetAndPageCounts
			return json(list.map { q -> [String: Any] in
				[pages ? "query_sample" : "query": String(q.sql.prefix(1000)), "database": q.schema, "count": q.count,
				 "total_seconds": ServerDiagnostics.decimal(q.totalSeconds, 3), "avg_seconds": ServerDiagnostics.decimal(q.avgSeconds, 4),
				 pages ? "logical_reads" : "rows_examined": q.rowsExamined, pages ? "rows_returned" : "rows_sent": q.rowsSent]
			})
		default:
			throw MCPFailure("모르는 도구: \(name)")
		}
	}

	// MARK: 나만 보는 뷰

	/// AI 가 만든 뷰 표시 (사이드바에서 구분되게)
	private static let aiMark = "✨ "

	private func appSession(_ t: Target) throws -> Session {
		guard let s = t.session, s.isConnected else { throw MCPFailure("\(t.server.displayName) 는 iSQL 에서 접속해 있지 않습니다. 나만 보는 뷰는 앱에서 접속한 서버에만 만들 수 있습니다") }
		return s
	}

	/// 보기용이라 SELECT(WITH) 한 문장만 (쿼리 권한과 상관없이 읽기 전용 검사)
	private func viewSQL(_ a: [String: Any], _ t: Target) throws -> String {
		let sql = try string(a, "sql").trimmingCharacters(in: .whitespacesAndNewlines)
		let parts = SQLSplitter.split(sql, t.dialect.syntax).map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		guard parts.count == 1 else { throw MCPFailure("나만 보는 뷰는 SELECT 한 문장만 됩니다 (\(parts.count)문장)") }
		let s = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
		let first = SQLSplitter.stripComments(s, t.dialect.syntax).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		guard first.hasPrefix("SELECT") || first.hasPrefix("WITH") || first.hasPrefix("("), MCPPolicy.check(s, .readOnly, t.dialect.syntax) == nil else {
			throw MCPFailure("나만 보는 뷰는 SELECT(WITH) 문장만 됩니다")
		}
		return s
	}

	/// 저장 전에 MCP 연결로 한 번 실행해 오류를 돌려준다 (1행만)
	private func tryViewSQL(_ t: Target, db: String, sql: String) async throws {
		let c = try await connection(t)
		_ = try await c.query(t.dialect.use(db))
		let probe = SQLSplitter.canAutoLimit(sql, t.dialect.syntax) ? t.dialect.paged(sql, limit: 1) : sql
		do { _ = try await c.query(probe) }
		catch { throw MCPFailure("SQL 오류: \(error.localizedDescription)") }
	}

	/// 그 서버가 열린 창을 앞으로, 사이드바 [테이블], 뷰 탭 열기
	private func show(_ v: PrivateView, in session: Session) {
		front(session)
		session.expanded.insert(v.schema)
		session.openPrivateView(v)
	}

	/// 그 서버가 열린 창을 앞으로 (그 서버로 바꾸고 사이드바 [테이블])
	private func front(_ session: Session) {
		guard let m = AppState.shared.allModels.first(where: { $0.sessions.values.contains { $0 === session } }), let srv = session.server else { return }
		m.open(srv)
		m.sidebarMode = .tables
		NSApp.activate()
	}

	// MARK: run_query 뒤 화면 새로고침

	/// 문장에서 바뀐 테이블을 찾아 앱의 열린 탭을 다시 읽는다. 저장 안 한 편집이 있어 건너뛴 탭을 돌려준다
	private func refreshAfter(_ statements: [String], db: String?, _ t: Target, _ session: Session) async -> [String] {
		var skipped: [String] = []
		let name = #"((?:[`"\[]?[^\s`"\].(]+[`"\]]?\.)?[`"\[]?[^\s`"\].(;]+[`"\]]?)"#
		func split(_ raw: String) -> (String?, String) {
			let clean = raw.replacingOccurrences(of: #"[`"\[\]]"#, with: "", options: .regularExpression)
			if let dot = clean.lastIndex(of: ".") { return (String(clean[..<dot]), String(clean[clean.index(after: dot)...])) }
			return (db, clean)
		}
		func match(_ s: String, _ pattern: String) -> [String]? {
			guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
			      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
			return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
		}
		for raw in statements {
			let s = SQLSplitter.stripComments(raw, t.dialect.syntax).trimmingCharacters(in: .whitespacesAndNewlines)
			// 이름 바꾸기: 열린 탭이 새 이름을 따라간다
			if let g = match(s, #"^RENAME\s+TABLE\s+"# + name + #"\s+TO\s+"# + name) ?? match(s, #"^ALTER\s+TABLE\s+"# + name + #"\s+RENAME\s+TO\s+"# + name), g.count == 2 {
				let (sc, old) = split(g[0]), (_, new) = split(g[1])
				if let sc { await session.tableRenamed(schema: sc, from: old, to: new) }
				else { _ = await session.externalChange(schema: nil, table: nil, structure: true, dropped: false) }
				continue
			}
			let kinds: [(String, Bool, Bool)] = [   // 패턴, 구조가 바뀌나, 지웠나
				(#"^DROP\s+(?:TABLE|VIEW)\s+(?:IF\s+EXISTS\s+)?"#, true, true),
				(#"^ALTER\s+TABLE\s+(?:ONLY\s+)?"#, true, false),
				(#"^CREATE\s+(?:UNIQUE\s+)?INDEX\s+\S+\s+ON\s+"#, true, false),
				(#"^(?:CREATE|REPLACE)\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?"#, true, false),
				(#"^TRUNCATE\s+(?:TABLE\s+)?"#, false, false),
				(#"^(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?(?:INTO\s+)?"#, false, false),
				(#"^UPDATE\s+(?:LOW_PRIORITY\s+)?(?:IGNORE\s+)?"#, false, false),
				(#"^DELETE\s+(?:FROM\s+)?"#, false, false),
			]
			if let k = kinds.first(where: { match(s, $0.0 + name) != nil }), let g = match(s, k.0 + name) {
				let (sc, tb) = split(g[0])
				skipped += await session.externalChange(schema: sc, table: tb, structure: k.1, dropped: k.2)
			} else if Self.changesSchema(s, t.dialect.syntax) {
				// 못 알아본 구조 변경 (DB 만들기 · 지우기 등): 목록만 다시
				try? await session.loadSchema()
			}
		}
		return skipped
	}

	private static func changesSchema(_ s: String, _ syntax: SQLSyntax) -> Bool {
		let up = SQLSplitter.stripComments(s, syntax).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
		var capabilities: SQLCapabilities { (server.sqlKind ?? .mysql).capabilities }
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
