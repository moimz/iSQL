import Foundation
import Observation

/// 데이터베이스 복제 (사이드바 DB 오른쪽 클릭 → 데이터베이스 복제…).
/// 새 DB 를 원본과 같은 문자셋·콜레이션으로 만들고, 테이블마다 구조(SHOW CREATE TABLE)와 데이터(나눠서 INSERT)를 옮긴다.
/// USE 를 쓰지 않고 모두 `DB`.`테이블` 로 적는다 (쿼리 패널의 기본 DB 를 건드리지 않게)
@Observable
final class DatabaseCopyJob {
	let source: String
	@ObservationIgnored private weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	private var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }

	/// 원본의 문자셋·콜레이션 (시트에 보여 주고 새 DB 에 그대로)
	private(set) var charset = ""
	private(set) var collation = ""

	private(set) var running = false
	private(set) var finished = false
	private(set) var done = 0
	private(set) var total = 0
	/// 지금 옮기는 테이블
	private(set) var current = ""
	private(set) var message: String?
	private(set) var isError = false
	@ObservationIgnored private var cancelled = false

	init(source: String, session: Session) {
		self.source = source
		self.session = session
	}

	@MainActor
	func loadSettings() async {
		guard let session else { return }
		let r = try? await session.query("""
			SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(dialect.literal(.text(source)))
			""").last
		charset = r?.rows.first?[safe: 0]?.string ?? ""
		collation = r?.rows.first?[safe: 1]?.string ?? ""
	}

	func cancel() { cancelled = true }

	/// 데이터를 옮기는 방식.
	/// server: 서버 안에서 `INSERT … SELECT` (READ COMMITTED 라 원본은 잠금 없는 읽기)
	/// client: 원본을 앱으로 읽어 와(잠금 없는 일반 SELECT) INSERT VALUES 로 넣는다 — 바이너리 로그가 STATEMENT 형식이면
	///         READ COMMITTED 의 INSERT … SELECT 를 서버가 거부하므로 이쪽
	enum Mode { case server, client }

	/// 한 번에 옮기는 행 수
	static let chunk = 5000
	/// 앱에서 만드는 INSERT 한 문장의 행 수 (max_allowed_packet 을 넘지 않게)
	static let clientBatch = 500

	private(set) var mode: Mode = .server
	/// 지금 테이블에서 옮긴 행 / 어림 행
	private(set) var rowsDone: Int64 = 0
	private(set) var rowsTotal: Int64 = 0

	/// 진행 막대 값 (끝난 테이블 + 지금 테이블의 행 비율)
	var fraction: Double {
		guard total > 0 else { return 0 }
		let part = rowsTotal > 0 ? min(1, Double(rowsDone) / Double(rowsTotal)) : 0
		return (Double(done) + part) / Double(total)
	}

	private struct TableMeta {
		var name: String
		var isView: Bool
		var approxRows: Int64
		/// 생성 컬럼(GENERATED)은 빼고 넣는다 (값을 넣으면 오류)
		var columns: [String] = []
		var primaryKey: [String] = []
	}

	@MainActor
	func run(to target: String, structure: Bool, data: Bool, routines: Bool = false) async {
		guard let session, !running else { return }
		running = true
		finished = false
		cancelled = false
		message = nil
		isError = false
		done = 0
		rowsDone = 0
		rowsTotal = 0
		defer { running = false; finished = true }

		let q = dialect.quote(_:)
		let src = q(source), dst = q(target)
		var fkOff = false
		do {
			var create = "CREATE DATABASE \(dst)"
			if !charset.isEmpty { create += " CHARACTER SET \(charset)" }
			if !collation.isEmpty { create += " COLLATE \(collation)" }
			_ = try await session.query(create)

			if structure {
				let list = try await tableList()
				total = list.count
				if data { mode = try await pickMode() }
				// 외래 키 순서와 상관없이 만들고 넣는다 (같은 연결을 쓰므로 끝나면 되돌린다)
				_ = try await session.query("SET FOREIGN_KEY_CHECKS = 0")
				fkOff = true
				for t in list {
					if cancelled { break }
					current = t.name
					rowsDone = 0
					rowsTotal = data && !t.isView ? t.approxRows : 0
					if t.isView {
						try await copyView(t.name, src: src, target: target)
					} else {
						try await copyTable(t.name, src: src, dst: dst)
						if data { try await copyData(t, src: src, dst: dst) }
					}
					if cancelled { break }
					done += 1
				}
			}
			if fkOff { _ = try? await session.query("SET FOREIGN_KEY_CHECKS = 1") }
			// 루틴은 데이터를 다 넣은 뒤에 (트리거가 복제 INSERT 에 돌지 않게)
			var routineNote = ""
			if routines && structure && !cancelled { routineNote = try await copyRoutines(target: target) }
			let stopped = current
			current = ""
			message = cancelled ? "그만뒀습니다. \(target) 에 테이블 \(done)개까지 복제됐습니다" + (stopped.isEmpty ? "." : " (\(stopped) 는 되돌림).")
			                    : "\(target) 복제를 마쳤습니다" + (structure ? " (테이블 \(done)개\(routineNote))" : "")
		} catch {
			if fkOff { _ = try? await session.query("SET FOREIGN_KEY_CHECKS = 1") }
			isError = true
			message = (current.isEmpty ? "" : "\(current): ") + error.localizedDescription
		}
		try? await session.loadSchema()
	}

	/// 같은 DB 안에서 테이블(또는 뷰) 하나 복제 (오른쪽 클릭 → 테이블 복제…).
	/// 테이블: CREATE TABLE 새 LIKE 원본 (컬럼·인덱스·AUTO_INCREMENT 설정, 외래 키·트리거는 안 옮겨짐) + 데이터는 DB 복제와 같은 방식.
	/// 뷰: 정의(VIEW_DEFINITION)로 CREATE VIEW 새 AS …
	@MainActor
	func duplicateTable(_ name: String, isView: Bool, to newName: String, data: Bool) async {
		guard let session, !running else { return }
		running = true
		finished = false
		cancelled = false
		message = nil
		isError = false
		done = 0
		total = 1
		current = newName
		rowsDone = 0
		defer { running = false; finished = true }
		let q = dialect.quote(_:)
		let db = q(source)
		do {
			if isView {
				let r = try await session.query("SELECT VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(dialect.literal(.text(source))) AND TABLE_NAME = \(dialect.literal(.text(name)))").last
				guard let def = r?.rows.first?.first?.string else { throw CopyError.noDDL(name) }
				_ = try await session.query("CREATE VIEW \(db).\(q(newName)) AS \(def)")
			} else {
				_ = try await session.query("CREATE TABLE \(db).\(q(newName)) LIKE \(db).\(q(name))")
				if data, let meta = try await tableList().first(where: { $0.name == name && !$0.isView }) {
					mode = try await pickMode()
					rowsTotal = meta.approxRows
					try await copyData(meta, src: db, dst: db, dstName: newName)
				}
			}
			done = 1
			if cancelled {
				message = "그만뒀습니다 · \(newName) 는 비어 있습니다"
				isError = true
			} else {
				message = data && !isView ? "\(newName) 만듦 · \(rowsDone.formatted())행 복사" : "\(newName) 만듦"
			}
		} catch {
			message = error.localizedDescription
			isError = true
		}
		await session.tableCreated(schema: source, name: newName)
	}

	/// 테이블 먼저, 뷰는 나중 (뷰가 테이블을 본다). 컬럼·기본 키·어림 행도 한 번에
	@MainActor
	private func tableList() async throws -> [TableMeta] {
		guard let session else { return [] }
		let s = dialect.literal(.text(source))
		let t = try await session.query("""
			SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME
			""").last ?? QueryResult()
		var metas = t.rows.map { r in
			TableMeta(name: r[0].string ?? "", isView: r[safe: 1]?.string == "VIEW", approxRows: r[safe: 3]?.string.flatMap { Int64($0) } ?? 0)
		}
		let c = try await session.query("""
			SELECT TABLE_NAME, COLUMN_NAME, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME, ORDINAL_POSITION
			""").last ?? QueryResult()
		let k = try await session.query("""
			SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(s) AND INDEX_NAME = 'PRIMARY' ORDER BY TABLE_NAME, SEQ_IN_INDEX
			""").last ?? QueryResult()
		var cols: [String: [String]] = [:], keys: [String: [String]] = [:]
		for r in c.rows where !(r[safe: 2]?.string?.uppercased().contains("GENERATED") ?? false) {
			cols[r[0].string ?? "", default: []].append(r[1].string ?? "")
		}
		for r in k.rows { keys[r[0].string ?? "", default: []].append(r[1].string ?? "") }
		for i in metas.indices {
			metas[i].columns = cols[metas[i].name] ?? []
			metas[i].primaryKey = keys[metas[i].name] ?? []
		}
		return metas.filter { !$0.isView } + metas.filter(\.isView)
	}

	/// 바이너리 로그가 켜져 있고 STATEMENT 형식이면 앱을 거쳐 옮긴다
	@MainActor
	private func pickMode() async throws -> Mode {
		guard let session else { return .server }
		let r = try? await session.query("SELECT @@log_bin, @@binlog_format").last
		let logBin = r?.rows.first?[safe: 0]?.string ?? "0"
		let format = (r?.rows.first?[safe: 1]?.string ?? "").uppercased()
		return (logBin == "1" || logBin.uppercased() == "ON") && format == "STATEMENT" ? .client : .server
	}

	/// 테이블 하나의 데이터: 트랜잭션 하나(오토커밋 끔) 안에서 기본 키 순서로 5,000행씩 넣고 다 넣으면 커밋.
	/// 원본은 잠그지 않는다 (server: READ COMMITTED 의 INSERT … SELECT 는 원본을 잠금 없이 읽는다, client: 일반 SELECT).
	/// 그만두면 그 테이블은 되돌린다(비어 있는 채로 남는다)
	@MainActor
	private func copyData(_ t: TableMeta, src: String, dst: String, dstName: String? = nil) async throws {
		guard let session, !t.columns.isEmpty else { return }
		let q = dialect.quote(_:)
		let cols = t.columns.map(q).joined(separator: ", ")
		let target = "\(dst).\(q(dstName ?? t.name))"
		let from = "\(src).\(q(t.name))", into = "\(target) (\(cols))"
		// 기본 키가 컬럼 목록에 다 있어야 이어 읽기를 할 수 있다
		let keyIdx = t.primaryKey.compactMap { t.columns.firstIndex(of: $0) }
		let keyed = !t.primaryKey.isEmpty && keyIdx.count == t.primaryKey.count
		let order = keyed ? " ORDER BY " + t.primaryKey.map(q).joined(separator: ", ") : ""

		if mode == .server { _ = try await session.query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED") }
		_ = try await session.query("START TRANSACTION")
		do {
			var last: [Value]? = nil
			var offset = 0
			while true {
				if cancelled {
					_ = try? await session.query("ROLLBACK")
					return
				}
				var cond = ""
				if keyed, let last { cond = " WHERE " + Self.after(dialect, t.primaryKey.map(q), last) }
				let limit = keyed ? " LIMIT \(Self.chunk)" : " LIMIT \(Self.chunk) OFFSET \(offset)"
				var n = 0
				switch mode {
				case .server:
					if !keyed && rowsTotal <= Int64(Self.chunk) {
						// 기본 키 없는 작은 테이블은 한 번에
						n = Int(try await session.query("INSERT INTO \(into) SELECT \(cols) FROM \(from)").last?.affectedRows ?? 0)
						rowsDone += Int64(n)
						n = 0
						break
					}
					n = Int(try await session.query("INSERT INTO \(into) SELECT \(cols) FROM \(from)\(cond)\(order)\(limit)").last?.affectedRows ?? 0)
					if keyed, n > 0 {
						let keys = t.primaryKey.map(q).joined(separator: ", ")
						let desc = t.primaryKey.map { q($0) + " DESC" }.joined(separator: ", ")
						last = try await session.query("SELECT \(keys) FROM \(target) ORDER BY \(desc) LIMIT 1").last?.rows.first
					}
				case .client:
					let rows = try await session.query("SELECT \(cols) FROM \(from)\(cond)\(order)\(limit)").last?.rows ?? []
					n = rows.count
					if n > 0 {
						// 문자열 만들기는 메인 스레드 밖에서 (UI 가 멈추지 않게)
						let head = "INSERT INTO \(into) VALUES "
						let batch = Self.clientBatch
						let d = dialect
						let statements = await Task.detached { Self.inserts(d, head: head, rows: rows, batch: batch) }.value
						for sql in statements { _ = try await session.query(sql) }
						if keyed, let r = rows.last { last = keyIdx.map { r[$0] } }
					}
				}
				rowsDone += Int64(n)
				offset += n
				if rowsTotal < rowsDone { rowsTotal = rowsDone }
				if n < Self.chunk { break }
			}
			_ = try await session.query("COMMIT")
		} catch {
			_ = try? await session.query("ROLLBACK")
			throw error
		}
	}

	/// (a, b) > (1, 2) — 기본 키 다음부터 (컬럼 하나면 a > 1)
	private static func after(_ dialect: any SQLDialect, _ keys: [String], _ values: [Value]) -> String {
		if keys.count == 1 { return "\(keys[0]) > \(dialect.literal(values[0]))" }
		return "(" + keys.joined(separator: ", ") + ") > (" + values.map(dialect.literal).joined(separator: ", ") + ")"
	}

	nonisolated private static func inserts(_ dialect: any SQLDialect, head: String, rows: [[Value]], batch: Int) -> [String] {
		stride(from: 0, to: rows.count, by: batch).map { i in
			head + rows[i..<min(i + batch, rows.count)].map { "(" + $0.map(dialect.literal).joined(separator: ", ") + ")" }.joined(separator: ", ")
		}
	}

	/// SHOW CREATE TABLE 의 "CREATE TABLE `이름`" 을 "CREATE TABLE `새DB`.`이름`" 으로 바꿔 실행.
	/// 같은 DB 를 가리키는 외래 키(REFERENCES `부모`)는 새 테이블의 DB 로 풀린다
	@MainActor
	private func copyTable(_ name: String, src: String, dst: String) async throws {
		guard let session else { return }
		let q = dialect.quote(_:)
		let r = try await session.query("SHOW CREATE TABLE \(src).\(q(name))").last ?? QueryResult()
		guard var ddl = r.rows.first?[safe: 1]?.string else { throw CopyError.noDDL(name) }
		let head = "CREATE TABLE \(q(name))"
		guard ddl.hasPrefix(head) else { throw CopyError.noDDL(name) }
		ddl = "CREATE TABLE \(dst).\(q(name))" + ddl.dropFirst(head.count)
		_ = try await session.query(ddl)
	}

	/// 뷰는 원본 DB 를 `원본`. 으로 가리키므로 새 DB 로 바꾸고, DEFINER 는 뺀다 (권한 오류 방지)
	@MainActor
	private func copyView(_ name: String, src: String, target: String) async throws {
		guard let session else { return }
		let q = dialect.quote(_:)
		let r = try await session.query("SHOW CREATE VIEW \(src).\(q(name))").last ?? QueryResult()
		guard let ddl = r.rows.first?[safe: 1]?.string, ddl.contains(" VIEW ") else { throw CopyError.noDDL(name) }
		// "VIEW `원본`.`v` AS …" 처럼 DB 가 붙어 와서 " VIEW `v`" 로 찾으면 못 찾았다 → 이름 바꾸기와 같은 고치기
		_ = try await session.query(DatabaseRenameJob.rewriteView(ddl, name: name, from: source, to: target, dialect: dialect))
	}

	/// 프로시저·함수·트리거·이벤트를 새 DB 에: SHOW CREATE 를 읽어 `원본`. 을 `새`. 로 바꾸고 USE 새 DB 에서 만든다.
	/// DEFINER 로 실패하면 빼고 다시. 이벤트는 꺼진 채로 (복제본에서 돌면 안 되는 정리 작업일 수 있다). 끝에 붙일 설명
	@MainActor
	private func copyRoutines(target: String) async throws -> String {
		guard let session else { return "" }
		let q = dialect.quote(_:)
		let s = dialect.literal(.text(source))
		var items: [(RoutineKind, String)] = []
		for r in (try await session.query("SELECT ROUTINE_TYPE, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s)").last?.rows ?? []) {
			items.append((r[safe: 0]?.string == "FUNCTION" ? .function : .procedure, r[safe: 1]?.string ?? ""))
		}
		for r in (try await session.query("SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(s)").last?.rows ?? []) {
			items.append((.trigger, r[safe: 0]?.string ?? ""))
		}
		for r in (try await session.query("SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(s)").last?.rows ?? []) {
			items.append((.event, r[safe: 0]?.string ?? ""))
		}
		guard !items.isEmpty else { return "" }
		let c = try await session.sideConnection(purpose: "복제")
		defer { c.close() }
		_ = try await c.query("USE \(q(target))")
		var made = 0, events = 0
		for (k, n) in items {
			current = "\(k.label) \(n)"
			let r = try await session.query("SHOW CREATE \(k.sqlWord) \(q(source)).\(q(n))").last ?? QueryResult()
			guard !r.rows.isEmpty, let ddl0 = r.string(0, k.createColumn) else { throw CopyError.noDDL(n) }
			let ddl = Self.retarget(ddl0, from: source, to: target, dialect: dialect)
			do { _ = try await c.query(ddl) } catch { _ = try await c.query(RoutineEditor.stripDefiner(ddl)) }
			if k == .event { _ = try? await c.query("ALTER EVENT \(q(target)).\(q(n)) DISABLE"); events += 1 }
			made += 1
		}
		return ", 루틴 \(made)개" + (events > 0 ? " — 이벤트 \(events)개는 꺼진 채로" : "")
	}

	/// 정의 안의 DB 참조를 새 DB 로: `원본`. 과 따옴표 없는 원본. 둘 다 (프로시저 본문은 쓴 그대로 와서 따옴표가 없을 수 있다)
	static func retarget(_ ddl: String, from: String, to: String, dialect: any SQLDialect) -> String {
		let q = dialect.quote(_:)
		var s = ddl.replacingOccurrences(of: q(from) + ".", with: q(to) + ".")
		let name = NSRegularExpression.escapedPattern(for: from)
		s = s.replacingOccurrences(of: #"(?<![\w`$.])"# + name + #"\.(?=[`\w])"#, with: NSRegularExpression.escapedTemplate(for: q(to) + "."), options: .regularExpression)
		return s
	}

	enum CopyError: LocalizedError {
		case noDDL(String)
		var errorDescription: String? {
			switch self { case .noDDL(let n): "\(n) 의 정의를 읽지 못했습니다" }
		}
	}
}
