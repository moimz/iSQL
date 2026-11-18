import Foundation

/// MySQL 루틴 인자·계정·서버 상태 읽기 (1.x 의 RoutineViews·UserAccounts·ServerDiagnostics 에서 모았다)
extension MySQLMeta {
	private func last(_ run: DBRun, _ sql: String) async throws -> QueryResult { try await run(sql).last ?? QueryResult() }

	func routineParameters(_ run: DBRun, schema: String, name: String) async throws -> [(mode: String, name: String, type: String)] {
		let r = try await last(run, """
			SELECT PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER FROM information_schema.PARAMETERS
			 WHERE SPECIFIC_SCHEMA = \(dialect.literal(.text(schema))) AND SPECIFIC_NAME = \(dialect.literal(.text(name))) AND ORDINAL_POSITION > 0
			 ORDER BY ORDINAL_POSITION
			""")
		return r.rows.map { ($0[safe: 0]?.string ?? "IN", $0[safe: 1]?.string ?? "", $0[safe: 2]?.string ?? "") }
	}

	func eventSchedulerOff(_ run: DBRun) async -> Bool {
		let v = (try? await last(run, "SELECT @@event_scheduler"))?.rows.first?.first?.string ?? ""
		return v.uppercased() != "ON"
	}

	/// mysql.user 의 Y/N 권한 컬럼을 읽는다
	func accounts(_ run: DBRun) async throws -> [DBAccount] {
		let u = try await last(run, "SELECT * FROM mysql.user ORDER BY User, Host")
		func col(_ n: String) -> Int? { u.columns.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
		let iUser = col("User"), iHost = col("Host"), iPlugin = col("plugin"), iLocked = col("account_locked")
		let privCols = Privilege.all.compactMap { p in col(p.column).map { (p.sql, $0) } }
		return u.rows.map { r in
			var a = DBAccount(user: iUser.flatMap { r[$0].string } ?? "", host: iHost.flatMap { r[$0].string } ?? "")
			a.plugin = iPlugin.flatMap { r[$0].string } ?? ""
			a.locked = iLocked.map { r[$0].string == "Y" }
			a.global = Set(privCols.filter { r[$0.1].string == "Y" }.map(\.0))
			return a
		}
	}

	func databaseGrants(_ run: DBRun) async throws -> [String: [DBGrant]] {
		let d = try await last(run, "SELECT * FROM mysql.db ORDER BY Db")
		func col(_ n: String) -> Int? { d.columns.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
		let iUser = col("User"), iHost = col("Host"), iDb = col("Db")
		let privCols = Privilege.all.filter(\.perDatabase).compactMap { p in col(p.column).map { (p.sql, $0) } }
		var map: [String: [DBGrant]] = [:]
		for r in d.rows {
			let id = (iUser.flatMap { r[$0].string } ?? "") + "@" + (iHost.flatMap { r[$0].string } ?? "")
			map[id, default: []].append(DBGrant(db: iDb.flatMap { r[$0].string } ?? "",
			                                    privileges: Set(privCols.filter { r[$0.1].string == "Y" }.map(\.0))))
		}
		return map
	}

	func currentUser(_ run: DBRun) async throws -> String? { try await last(run, "SELECT CURRENT_USER()").rows.first?.first?.string }

	func grantStatements(_ run: DBRun, account: String) async throws -> [String] {
		try await last(run, "SHOW GRANTS FOR \(account)").rows.compactMap { $0.first?.string }
	}

	/// SHOW GLOBAL STATUS / VARIABLES → 이름(소문자): 값
	private func pairs(_ run: DBRun, _ sql: String) async throws -> [String: String] {
		let r = try await last(run, sql)
		var d: [String: String] = [:]
		for row in r.rows { if let k = row[safe: 0]?.string { d[k.lowercased()] = row[safe: 1]?.string ?? "" } }
		return d
	}

	func serverSummary(_ run: DBRun) async throws -> ServerDiagnostics.Summary {
		let st = try await pairs(run, "SHOW GLOBAL STATUS")
		let v = try await pairs(run, "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('version','version_comment','max_connections','innodb_buffer_pool_size','innodb_page_size','long_query_time')")
		func i(_ k: String) -> Int64 { Int64(st[k] ?? "") ?? 0 }
		var s = ServerDiagnostics.Summary()
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

	func processes(_ run: DBRun) async throws -> [ServerDiagnostics.Process] {
		let r = try await last(run, "SHOW FULL PROCESSLIST")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			return ServerDiagnostics.Process(id: Int64(s(0)) ?? 0, user: s(1), host: s(2), db: s(3), command: s(4), time: Int(s(5)) ?? 0, state: s(6), info: s(7))
		}
	}

	/// performance_schema 의 쿼리별 요약 (오래 걸린 순). 꺼져 있으면 오류
	func topQueries(_ run: DBRun, limit: Int) async throws -> [ServerDiagnostics.Digest] {
		let r = try await last(run, """
			SELECT DIGEST_TEXT, SCHEMA_NAME, COUNT_STAR, SUM_TIMER_WAIT / 1e12, AVG_TIMER_WAIT / 1e12, SUM_ROWS_EXAMINED, SUM_ROWS_SENT
			  FROM performance_schema.events_statements_summary_by_digest
			 WHERE DIGEST_TEXT IS NOT NULL ORDER BY SUM_TIMER_WAIT DESC LIMIT \(max(1, min(limit, 200)))
			""")
		return r.rows.map { row in
			func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
			return ServerDiagnostics.Digest(sql: s(0), schema: s(1), count: Int64(s(2)) ?? 0, totalSeconds: Double(s(3)) ?? 0,
			                                avgSeconds: Double(s(4)) ?? 0, rowsExamined: Int64(s(5)) ?? 0, rowsSent: Int64(s(6)) ?? 0)
		}
	}

	func variables(_ run: DBRun) async throws -> [(String, String)] {
		try await last(run, "SHOW GLOBAL VARIABLES").rows.compactMap { row in row[safe: 0]?.string.map { ($0, row[safe: 1]?.string ?? "") } }
	}

	func connectionID(_ run: DBRun) async throws -> Int64? {
		Int64(try await last(run, "SELECT CONNECTION_ID()").rows.first?.first?.string ?? "")
	}
}
