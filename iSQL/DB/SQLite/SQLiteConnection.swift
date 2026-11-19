import Foundation
import SQLite3

/// SQLite 파일 연결 (맥 기본 libsqlite3). 모든 작업은 연결마다 하나인 직렬 큐에서 돈다 (MySQLConnection 과 같게).
/// 결과 컬럼 타입은 지금 표가 쓰는 MySQL 타입 번호로 바꿔 준다 (정수·실수·글자·긴 글자·바이너리)
final class SQLiteConnection: DBConnection, @unchecked Sendable {
	private var db: OpaquePointer?
	private let queue = DispatchQueue(label: "iSQL.sqlite")
	let path: String

	private(set) var serverVersion = "SQLite " + String(cString: sqlite3_libversion())
	var isOpen: Bool { db != nil }
	var onQuery: (@Sendable (String, Double, String?) -> Void)?

	private init(path: String) { self.path = path }

	/// 파일을 연다. create 면 없을 때 새로 만든다
	static func open(path: String, create: Bool = false) async throws -> SQLiteConnection {
		let c = SQLiteConnection(path: path)
		try await c.run {
			guard create || FileManager.default.fileExists(atPath: path) else { throw SQLiteError.message("이 맥에 파일이 없습니다: \(path)") }
			var h: OpaquePointer?
			let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
			let rc = sqlite3_open_v2(path, &h, flags, nil)
			guard rc == SQLITE_OK, let h else {
				let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "열 수 없습니다"
				if let h { sqlite3_close(h) }
				throw SQLiteError.sqlite(code: rc, message: msg)
			}
			sqlite3_busy_timeout(h, 5000)
			// 정말 SQLite 파일인지 (아니면 여기서 "file is not a database")
			var st: OpaquePointer?
			if sqlite3_prepare_v2(h, "SELECT count(*) FROM sqlite_master", -1, &st, nil) != SQLITE_OK || sqlite3_step(st) != SQLITE_ROW {
				let msg = String(cString: sqlite3_errmsg(h))
				sqlite3_finalize(st)
				sqlite3_close(h)
				throw SQLiteError.message("SQLite 파일이 아닙니다 (\(msg))")
			}
			sqlite3_finalize(st)
			c.db = h
		}
		return c
	}

	func query(_ sql: String) async throws -> [QueryResult] {
		try await run {
			let start = Date()
			do {
				let r = try self.execute(sql)
				self.onQuery?(sql, Date().timeIntervalSince(start), nil)
				return r
			} catch {
				self.onQuery?(sql, Date().timeIntervalSince(start), error.localizedDescription)
				throw error
			}
		}
	}

	/// SQL 파일 가져오기: UTF-8 이 아닌 글자는 바꿔서
	func query(bytes: [UInt8]) async throws -> [QueryResult] {
		try await query(String(decoding: bytes, as: UTF8.self))
	}

	func rows(_ sql: String) async throws -> QueryResult {
		try await query(sql).last ?? QueryResult()
	}

	func close() {
		queue.async {
			if let db = self.db { sqlite3_close_v2(db) }
			self.db = nil
		}
	}

	deinit { if let db { sqlite3_close_v2(db) } }

	/// 실행 중인 문장 멈추기: sqlite3_interrupt 는 다른 스레드에서 불러도 된다 (문장은 SQLITE_INTERRUPT 로 끝난다)
	func cancel() {
		if let db { sqlite3_interrupt(db) }
	}

	private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { cont in
			queue.async {
				do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
			}
		}
	}

	// MARK: - 실행

	/// 여러 문장이면 차례로 (결과도 문장마다 하나)
	private func execute(_ sql: String) throws -> [QueryResult] {
		guard let db else { throw DBError.closed }
		var results: [QueryResult] = []
		// 이 글이 연 트랜잭션은 중간에 실패하면 되돌린다 (열린 채로 남지 않게)
		let wasAutocommit = sqlite3_get_autocommit(db) != 0
		do {
			try executeAll(sql, db, into: &results)
		} catch {
			if wasAutocommit, sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
			throw error
		}
		return results
	}

	private func executeAll(_ sql: String, _ db: OpaquePointer, into results: inout [QueryResult]) throws {
		try sql.withCString { base in
			var tail: UnsafePointer<CChar>? = base
			while let cur = tail, cur.pointee != 0 {
				var st: OpaquePointer?
				let rc = sqlite3_prepare_v2(db, cur, -1, &st, &tail)
				guard rc == SQLITE_OK else { throw SQLiteError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db))) }
				guard let st else { continue }   // 빈 문장·주석만
				defer { sqlite3_finalize(st) }
				results.append(try step(st, db))
			}
		}
	}

	private func step(_ st: OpaquePointer, _ db: OpaquePointer) throws -> QueryResult {
		var r = QueryResult()
		let n = Int(sqlite3_column_count(st))
		var firstTypes: [Int32] = []
		while true {
			let rc = sqlite3_step(st)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else { throw SQLiteError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db))) }
			// 선언 타입이 없는 컬럼(식)은 처음 나온 NULL 아닌 값의 타입으로
			if firstTypes.isEmpty { firstTypes = Array(repeating: SQLITE_NULL, count: n) }
			for i in 0..<n where firstTypes[i] == SQLITE_NULL { firstTypes[i] = sqlite3_column_type(st, Int32(i)) }
			var row: [Value] = []
			row.reserveCapacity(n)
			for i in 0..<Int32(n) {
				switch sqlite3_column_type(st, i) {
				case SQLITE_NULL: row.append(.null)
				case SQLITE_BLOB:
					let len = Int(sqlite3_column_bytes(st, i))
					if len > 0, let p = sqlite3_column_blob(st, i) { row.append(.bytes(Data(bytes: p, count: len))) } else { row.append(.bytes(Data())) }
				default:
					row.append(sqlite3_column_text(st, i).map { .text(String(cString: $0)) } ?? .null)
				}
			}
			r.rows.append(row)
		}
		if n > 0 {
			r.columns = (0..<n).map { column(st, db, Int32($0), firstType: $0 < firstTypes.count ? firstTypes[$0] : SQLITE_NULL) }
		} else {
			r.affectedRows = UInt64(max(0, sqlite3_changes(db)))
			r.lastInsertID = UInt64(max(0, sqlite3_last_insert_rowid(db)))
		}
		return r
	}

	/// 결과 컬럼 하나: 선언 타입(없으면 첫 행 값의 타입)으로 MySQL 타입 번호를 고른다
	private func column(_ st: OpaquePointer, _ db: OpaquePointer, _ i: Int32, firstType: Int32) -> Column {
		func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
		let name = s(sqlite3_column_name(st, i))
		let table = s(sqlite3_column_table_name(st, i))
		let origin = s(sqlite3_column_origin_name(st, i))
		let schema = s(sqlite3_column_database_name(st, i))
		let decl = s(sqlite3_column_decltype(st, i)).uppercased()
		var type: UInt8 = 253, charset: UInt16 = 33
		if !decl.isEmpty {
			// SQLite 의 타입 친화도 규칙 (INT → 정수, CHAR·CLOB·TEXT → 글자, BLOB → 바이너리, REAL·FLOA·DOUB → 실수, 나머지 숫자)
			if decl.contains("INT") { type = 8 }
			else if decl.contains("CHAR") || decl.contains("CLOB") { type = 253 }
			else if decl.contains("TEXT") || decl == "JSON" { type = 252 }
			else if decl.contains("BLOB") { type = 252; charset = 63 }
			else if decl.contains("REAL") || decl.contains("FLOA") || decl.contains("DOUB") { type = 5 }
			else if decl.contains("NUM") || decl.contains("DEC") { type = 246 }
			else if decl.contains("DATE") || decl.contains("TIME") || decl.contains("BOOL") { type = 253 }
		} else {
			switch firstType {
			case SQLITE_INTEGER: type = 8
			case SQLITE_FLOAT: type = 5
			case SQLITE_BLOB: type = 252; charset = 63
			default: type = 253
			}
		}
		var flags: UInt16 = 0
		if !table.isEmpty, !origin.isEmpty {
			var pk: Int32 = 0
			if sqlite3_table_column_metadata(db, schema.isEmpty ? nil : schema, table, origin, nil, nil, nil, &pk, nil) == SQLITE_OK, pk != 0 { flags |= 0x2 }
		}
		return Column(name: name, orgName: origin, table: table, orgTable: table, schema: schema, charset: charset,
		              length: 0, type: type, flags: flags, decimals: 0)
	}
}

enum SQLiteError: LocalizedError {
	case sqlite(code: Int32, message: String)
	case message(String)
	var errorDescription: String? {
		switch self {
		case .sqlite(let code, let message): "\(message) (오류 \(code))"
		case .message(let m): m
		}
	}
}
