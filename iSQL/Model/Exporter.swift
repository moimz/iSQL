import Foundation
import Observation

/// 내보낼 수 있는 것 (테이블 데이터, 쿼리 결과)
protocol ExportSource: AnyObject {
	/// INSERT 에 쓸 기본 테이블 이름 (쿼리 결과가 여러 테이블에서 왔으면 nil → 입력받는다)
	var exportTableName: String? { get }
	/// CREATE TABLE 을 넣을 수 있는지 (한 테이블에서 온 것일 때만)
	var canExportStructure: Bool { get }
	/// 파일 이름에 쓸 이름
	var exportFileBase: String { get }
	/// 컬럼 이름과 숫자 여부
	var exportColumns: [(name: String, numeric: Bool)] { get }
	/// 화면에 보이는 행
	var visibleRows: [[Value]] { get }
	/// SHOW CREATE TABLE 결과
	func createTableSQL() async throws -> String?
	/// 전체 행을 offset 부터 limit 개 (조건·정렬은 화면과 같게)
	func fetchRows(offset: Int, limit: Int) async throws -> [[Value]]
	/// 머리말에 서버 이름을 쓰려고
	var exportSession: Session? { get }
	/// 전체를 내보낼 때의 행 수 (진행 막대용, 모르면 nil)
	var exportTotalEstimate: Int? { get }
	/// 그 행 수가 정확한지
	var isExactTotal: Bool { get }
}

/// SQL 내보내기 옵션
struct SQLExportOptions {
	var includeStructure = true
	var includeDrop = true
	var visibleOnly = true
	/// INSERT 대상 테이블 이름
	var tableName = ""
}

/// 무엇을 내보낼지 (창 제목바 시트 하나가 모든 곳의 내보내기를 받는다)
enum ExportTarget {
	/// 열려 있는 테이블 데이터나 쿼리 결과 (화면에 보이는 것만 / 전체)
	case data(ExportSource)
	/// DB 의 테이블들 (사이드바·DB 개요에서): 구조 / 데이터.
	/// tables 는 고를 수 있는 전체, picked 는 처음에 체크된 이름, showPicker 면 시트에 고르기 목록을 보인다
	case database(schema: String, tables: [TableStat], picked: Set<String>, showPicker: Bool)

	/// 테이블 하나 (고르기 목록 없음)
	static func table(_ schema: String, _ t: TableStat) -> ExportTarget {
		.database(schema: schema, tables: [t], picked: [t.name], showPicker: false)
	}
}

struct ExportRequest: Identifiable {
	let id = UUID()
	let target: ExportTarget
}

extension TableStat {
	/// 사이드바 테이블 정보로 (용량은 모르니 0)
	init(_ t: TableInfo) {
		self.init(name: t.name, isView: t.isView, engine: t.engine, rows: t.rows, dataLength: 0, indexLength: 0, dataFree: 0,
		          autoIncrement: nil, collation: "", comment: t.comment, updated: "")
	}
}

/// DB 내보내기 옵션 (여러 테이블)
struct DatabaseExportOptions {
	var includeStructure = true
	var includeDrop = true
	var includeData = true
}

/// 내보내기 진행 (팝오버에 보여 준다)
@Observable
final class ExportJob {
	private(set) var running = false
	private(set) var written = 0
	/// 진행 막대용 전체 행 수 (모르면 nil → 움직이는 막대)
	private(set) var total: Int?
	/// 어림값인지 (InnoDB 통계)
	private(set) var totalApprox = false
	private(set) var fileName = ""
	private(set) var finished = false
	private(set) var message: String?
	private(set) var isError = false
	@ObservationIgnored private var cancelled = false

	func cancel() { cancelled = true }

	/// SQL 파일로 내보낸다. 데이터는 1000행씩 받아 바로 쓴다 (큰 테이블도 메모리를 많이 안 쓰게)
	@MainActor
	func exportSQL(_ src: ExportSource, options o: SQLExportOptions, to url: URL) async {
		guard !running else { return }
		running = true
		cancelled = false
		written = 0
		message = nil
		isError = false
		finished = false
		fileName = url.lastPathComponent
		if o.visibleOnly { total = src.visibleRows.count; totalApprox = false }
		else { total = src.exportTotalEstimate; totalApprox = !(src.isExactTotal) }
		defer { finished = true }
		defer { running = false }

		guard FileManager.default.createFile(atPath: url.path, contents: nil), let fh = try? FileHandle(forWritingTo: url) else {
			fail("파일을 만들지 못했습니다: \(url.path)")
			return
		}
		defer { try? fh.close() }
		func write(_ s: String) { fh.write(Data(s.utf8)) }

		let table = quoteName(o.tableName)
		let cols = src.exportColumns
		let colList = cols.map { quoteName($0.name) }.joined(separator: ", ")
		let df = ISO8601DateFormatter()
		write("""
			-- iSQL 내보내기
			-- 대상: \(o.tableName)\(src.exportSession?.server.map { " · 서버 \($0.displayName)" } ?? "")
			-- 만든 시각: \(df.string(from: Date()))
			-- 데이터: \(o.visibleOnly ? "화면에 보이는 행만" : "전체")

			SET NAMES utf8mb4;
			SET FOREIGN_KEY_CHECKS = 0;


			""")
		do {
			if o.includeStructure, src.canExportStructure {
				if o.includeDrop { write("DROP TABLE IF EXISTS \(table);\n") }
				if let create = try await src.createTableSQL() { write(create + ";\n\n") }
			}
			// 숫자 컬럼은 따옴표 없이
			func value(_ v: Value, _ numeric: Bool) -> String {
				if numeric, case .text(let s) = v, Double(s) != nil { return s }
				return literal(v)
			}
			func writeRows(_ rows: [[Value]]) {
				// 100행씩 묶은 INSERT
				var i = 0
				while i < rows.count {
					let chunk = rows[i..<min(i + 100, rows.count)]
					let values = chunk.map { r in "(" + r.enumerated().map { value($0.element, $0.offset < cols.count && cols[$0.offset].numeric) }.joined(separator: ", ") + ")" }
					write("INSERT INTO \(table) (\(colList)) VALUES\n" + values.joined(separator: ",\n") + ";\n")
					i += 100
				}
				written += rows.count
			}
			if o.visibleOnly {
				writeRows(src.visibleRows)
			} else {
				var offset = 0
				let size = 1000
				while !cancelled {
					let rows = try await src.fetchRows(offset: offset, limit: size)
					writeRows(rows)
					if rows.count < size { break }
					offset += size
				}
			}
			write("\nSET FOREIGN_KEY_CHECKS = 1;\n")
			if cancelled {
				message = "그만둠 · \(written.formatted())행까지 썼습니다"
			} else {
				message = "\(written.formatted())행 내보냄 · \(url.lastPathComponent)"
			}
		} catch {
			fail(error.localizedDescription)
		}
	}

	/// DB 의 여러 테이블을 한 SQL 파일로. 테이블마다 구조(선택)와 데이터(선택, 1000행씩)
	@MainActor
	func exportDatabase(session: Session, schema: String, tables: [TableStat], options o: DatabaseExportOptions, to url: URL) async {
		guard !running else { return }
		running = true
		cancelled = false
		written = 0
		message = nil
		isError = false
		finished = false
		fileName = url.lastPathComponent
		let dataTables = tables.filter { !$0.isView }
		total = o.includeData ? Int(dataTables.reduce(0) { $0 + ($1.rows ?? 0) }) : nil
		totalApprox = dataTables.contains { !$0.rowsExact }
		defer { running = false; finished = true }

		guard FileManager.default.createFile(atPath: url.path, contents: nil), let fh = try? FileHandle(forWritingTo: url) else {
			fail("파일을 만들지 못했습니다: \(url.path)")
			return
		}
		defer { try? fh.close() }
		func write(_ s: String) { fh.write(Data(s.utf8)) }
		let df = ISO8601DateFormatter()
		write("""
			-- iSQL 내보내기
			-- DB: \(schema)\(session.server.map { " · 서버 \($0.displayName)" } ?? "")
			-- 테이블 \(tables.count)개 · 만든 시각: \(df.string(from: Date()))

			SET NAMES utf8mb4;
			SET FOREIGN_KEY_CHECKS = 0;


			""")
		do {
			for t in tables where !cancelled {
				let q = "\(quoteName(schema)).\(quoteName(t.name))"
				write("-- ----------------------------------------\n-- \(t.name)\(t.comment.isEmpty ? "" : " · " + t.comment)\n-- ----------------------------------------\n")
				if o.includeStructure {
					if o.includeDrop { write(t.isView ? "DROP VIEW IF EXISTS \(quoteName(t.name));\n" : "DROP TABLE IF EXISTS \(quoteName(t.name));\n") }
					// 뷰도 SHOW CREATE TABLE 이 CREATE VIEW 를 준다
					let r = try await session.query("SHOW CREATE TABLE \(q)").last
					if let create = r?.rows.first.flatMap({ $0.count > 1 ? $0[1].string : nil }) { write(create + ";\n\n") }
				}
				guard o.includeData, !t.isView else { continue }
				let cols = (session.columns[schema + "." + t.name] ?? [])
				let pk = cols.filter { $0.key == "PRI" }.map { quoteName($0.name) }
				let order = pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", ")
				var offset = 0
				let size = 1000
				while !cancelled {
					let res = try await session.query("SELECT * FROM \(q)\(order) LIMIT \(size) OFFSET \(offset)").last ?? QueryResult()
					let names = res.columns.map { quoteName($0.orgName.isEmpty ? $0.name : $0.orgName) }.joined(separator: ", ")
					let numeric = res.columns.map(\.isNumeric)
					var i = 0
					while i < res.rows.count {
						let chunk = res.rows[i..<min(i + 100, res.rows.count)]
						let values = chunk.map { r in "(" + r.enumerated().map { e in
							if e.offset < numeric.count, numeric[e.offset], case .text(let v) = e.element, Double(v) != nil { return v }
							return literal(e.element)
						}.joined(separator: ", ") + ")" }
						write("INSERT INTO \(quoteName(t.name)) (\(names)) VALUES\n" + values.joined(separator: ",\n") + ";\n")
						i += 100
					}
					written += res.rows.count
					if res.rows.count < size { break }
					offset += size
				}
				write("\n")
			}
			write("SET FOREIGN_KEY_CHECKS = 1;\n")
			message = cancelled ? "그만둠 · \(written.formatted())행까지 썼습니다" : "테이블 \(tables.count)개 · \(written.formatted())행 내보냄 · \(url.lastPathComponent)"
		} catch {
			fail(error.localizedDescription)
		}
	}

	private func fail(_ s: String) {
		message = s
		isError = true
	}
}

// MARK: - 테이블 데이터

extension TableData: ExportSource {
	var exportTableName: String? { table.name }
	var canExportStructure: Bool { !table.isView }
	var exportFileBase: String { table.name }
	var exportColumns: [(name: String, numeric: Bool)] {
		columns.map { (($0.orgName.isEmpty ? $0.name : $0.orgName), $0.isNumeric) }
	}
	/// 화면에 보이는 행 (저장 안 한 변경은 빼고 서버에서 읽은 그대로)
	var visibleRows: [[Value]] { rows }

	func createTableSQL() async throws -> String? {
		let r = try await session.query("SHOW CREATE TABLE \(table.quoted)").last
		return r?.rows.first.flatMap { $0.count > 1 ? $0[1].string : nil }
	}

	/// 화면과 같은 조건(appliedWhere)·정렬로 전체를 나눠 받는다
	func fetchRows(offset: Int, limit: Int) async throws -> [[Value]] {
		let pk = (session.columns[table.id] ?? []).filter { $0.key == "PRI" }.map { quoteName($0.name) }
		var orderParts: [String] = []
		if let sort { orderParts.append(quoteName(sort.column) + (sort.ascending ? " ASC" : " DESC")) }
		orderParts += pk.filter { $0 != sort.map { quoteName($0.column) } }
		let order = orderParts.isEmpty ? "" : " ORDER BY " + orderParts.joined(separator: ", ")
		let sql = "SELECT * FROM \(table.quoted)\(appliedWhere.isEmpty ? "" : " WHERE " + appliedWhere)\(order) LIMIT \(limit) OFFSET \(offset)"
		return try await session.query(sql).last?.rows ?? []
	}

	var exportSession: Session? { session }
	var exportTotalEstimate: Int? { exactTotal ?? statTotal.map { Int($0) } }
	var isExactTotal: Bool { exactTotal != nil || (statTotal != nil && table.rowsExact) }
}

// MARK: - 쿼리 결과

extension QueryOutput: ExportSource {
	/// 모든 컬럼이 한 테이블에서 왔으면 그 테이블
	private var singleTable: (schema: String, table: String)? {
		let t = Set(result.columns.map { "\($0.schema)\u{1}\($0.orgTable)" })
		guard t.count == 1, let c = result.columns.first, !c.orgTable.isEmpty else { return nil }
		return (c.schema, c.orgTable)
	}
	var exportTableName: String? { singleTable?.table }
	var canExportStructure: Bool { singleTable != nil }
	var exportFileBase: String { singleTable?.table ?? "query_result" }
	var exportColumns: [(name: String, numeric: Bool)] {
		result.columns.map { (($0.orgName.isEmpty ? $0.name : $0.orgName), $0.isNumeric) }
	}
	var visibleRows: [[Value]] { result.rows }

	func createTableSQL() async throws -> String? {
		guard let t = singleTable, let session else { return nil }
		let name = t.schema.isEmpty ? quoteName(t.table) : "\(quoteName(t.schema)).\(quoteName(t.table))"
		let r = try await session.query("SHOW CREATE TABLE \(name)").last
		return r?.rows.first.flatMap { $0.count > 1 ? $0[1].string : nil }
	}

	/// 전체: LIMIT 을 자동으로 붙였던 쿼리면 나눠 받고, 직접 LIMIT 을 쓴 쿼리면 지금 결과가 전체
	func fetchRows(offset: Int, limit: Int) async throws -> [[Value]] {
		guard paged, let session else { return offset == 0 ? result.rows : [] }
		return try await session.query("\(sql) LIMIT \(limit) OFFSET \(offset)").last?.rows ?? []
	}

	var exportSession: Session? { session }
	var exportTotalEstimate: Int? { paged ? knownTotal : result.rows.count }
	var isExactTotal: Bool { true }
}
