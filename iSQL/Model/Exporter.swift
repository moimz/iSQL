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
	/// 결과 컬럼 (엑셀: 타입을 보고 숫자·날짜로)
	var exportResultColumns: [Column] { get }
	/// 컬럼 이름 → 코멘트 (엑셀 첫 행)
	var exportColumnComments: [String: String] { get }
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

/// 엑셀 첫 행에 컬럼 코멘트를 어떻게 쓸지
enum HeaderComment: String, CaseIterable {
	case name, comment, nameAndComment
	var title: String {
		switch self {
		case .name: "컬럼 이름만"
		case .comment: "코멘트로 바꾸기 (없으면 이름)"
		case .nameAndComment: "이름에 코멘트 덧붙이기"
		}
	}
}

/// 엑셀(xlsx) 내보내기 옵션
struct ExcelExportOptions {
	/// 첫 행에 컬럼 이름
	var header = true
	var headerComment = HeaderComment.name
	/// 여러 테이블이면 한 파일에 테이블마다 시트 (끄면 테이블마다 파일)
	var oneFile = true
	/// 숫자·날짜를 엑셀 숫자·날짜로 (끄면 모두 글자)
	var keepTypes = true
	/// 열린 테이블·쿼리 결과: 화면에 보이는 행만
	var visibleOnly = true
}

/// 엑셀 시트 하나로 쓸 것: 이름, 코멘트, 행 받기 (offset, limit → 컬럼과 행)
struct ExcelSheetSpec {
	var name: String
	var comments: [String: String]
	var total: Int?
	var fetch: (_ offset: Int, _ limit: Int) async throws -> (columns: [Column], rows: [[Value]])

	/// 열린 테이블·쿼리 결과
	@MainActor
	static func data(_ src: ExportSource, visibleOnly: Bool) -> ExcelSheetSpec {
		let cols = src.exportResultColumns
		if visibleOnly {
			let rows = src.visibleRows
			return ExcelSheetSpec(name: src.exportFileBase, comments: src.exportColumnComments, total: rows.count) { offset, _ in
				(cols, offset == 0 ? rows : [])
			}
		}
		return ExcelSheetSpec(name: src.exportFileBase, comments: src.exportColumnComments, total: src.exportTotalEstimate) { offset, limit in
			(cols, try await src.fetchRows(offset: offset, limit: limit))
		}
	}

	/// DB 의 테이블 하나 (기본 키 순서로 나눠 받는다)
	@MainActor
	static func table(session: Session, schema: String, _ t: TableStat) -> ExcelSheetSpec {
		let info = session.columns[schema + "." + t.name] ?? []
		let pk = info.filter { $0.key == "PRI" }.map { quoteName($0.name) }
		let order = pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", ")
		let q = "\(quoteName(schema)).\(quoteName(t.name))"
		return ExcelSheetSpec(name: t.name, comments: Dictionary(info.map { ($0.name, $0.comment) }, uniquingKeysWith: { a, _ in a }),
		                      total: t.rows.map { Int($0) }) { offset, limit in
			let r = try await session.query("SELECT * FROM \(q)\(order) LIMIT \(limit) OFFSET \(offset)").last ?? QueryResult()
			return (r.columns, r.rows)
		}
	}
}

/// MySQL 컬럼 → 엑셀 칸
enum ExcelValue {
	enum Kind { case integer, decimal, float, date, dateTime, text, binary }

	static func kind(_ c: Column) -> Kind {
		if c.isBinary { return .binary }
		switch c.type {
		case 1, 2, 3, 8, 9, 13: return .integer
		case 0, 246: return .decimal
		case 4, 5: return .float
		case 10, 14: return .date
		case 7, 12: return .dateTime
		default: return .text
		}
	}

	/// 엑셀은 숫자를 15자리까지만 정확히 다룬다 → 넘으면 글자로 (BIGINT ID 등)
	private static func fitsDouble(_ s: String) -> Bool {
		var digits = 0
		for u in s.utf8 {
			if u >= 0x30 && u <= 0x39 { digits += 1 }
			else if u != 0x2D && u != 0x2E && u != 0x2B { return false }
		}
		return digits > 0 && digits <= 15
	}

	static func cell(_ v: Value, _ kind: Kind, keepTypes: Bool) -> XLSXCell {
		switch v {
		case .null: return .empty
		case .bytes(let d):
			if let s = String(data: d, encoding: .utf8), kind != .binary { return .text(s) }
			// 바이너리는 0x 16진수 (칸 글자 수 한도 안에서)
			return .text("0x" + d.prefix(16_000).map { String(format: "%02X", $0) }.joined())
		case .text(let s):
			guard keepTypes else { return .text(s) }
			switch kind {
			case .integer, .decimal:
				return fitsDouble(s) ? .number(s) : .text(s)
			case .float:
				if let d = Double(s), d.isFinite { return .number(s) }
				return .text(s)
			case .date:
				return XLSXWriter.excelSerial(s).map { .date($0) } ?? .text(s)
			case .dateTime:
				return XLSXWriter.excelSerial(s).map { .dateTime($0) } ?? .text(s)
			case .text, .binary:
				return .text(s)
			}
		}
	}

	/// 화면 너비 어림 (한글 등은 두 칸)
	static func displayWidth(_ s: String) -> Int {
		var w = 0
		for u in s.unicodeScalars.prefix(200) { w += u.value > 0x2E7F ? 2 : 1 }
		return w
	}
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

	/// 엑셀(xlsx)로. oneFile 이면 url 은 파일 하나(시트 여럿), 아니면 url 은 폴더(시트마다 파일).
	/// 1,000행씩 받아 바로 쓴다. 시트 한 장 최대 행 수(1,048,576)를 넘으면 "이름 (2)" 시트로 이어 쓴다
	@MainActor
	func exportExcel(_ specs: [ExcelSheetSpec], options o: ExcelExportOptions, to url: URL, oneFile: Bool) async {
		guard !running else { return }
		running = true
		cancelled = false
		written = 0
		message = nil
		isError = false
		finished = false
		fileName = url.lastPathComponent
		let totals = specs.map(\.total)
		total = totals.contains { $0 == nil } ? nil : totals.reduce(0) { $0 + ($1 ?? 0) }
		totalApprox = false
		defer { running = false; finished = true }
		var files: [URL] = []
		do {
			var shared: XLSXWriter?
			if oneFile { shared = try XLSXWriter(url: url); files.append(url) }
			for spec in specs where !cancelled {
				let w: XLSXWriter
				if let shared { w = shared } else {
					let f = Self.freeURL(url.appendingPathComponent(Self.safeFileName(spec.name) + ".xlsx"))
					w = try XLSXWriter(url: f)
					files.append(f)
					fileName = f.lastPathComponent
				}
				try await writeSheet(spec, to: w, options: o)
				if shared == nil { try w.close() }
			}
			try shared?.close()
			if cancelled {
				message = "그만둠 · \(written.formatted())행까지 썼습니다"
			} else {
				message = "\(written.formatted())행 내보냄 · " + (oneFile ? url.lastPathComponent : "파일 \(files.count)개 (\(url.lastPathComponent))")
			}
		} catch {
			fail(error.localizedDescription)
		}
	}

	@MainActor
	private func writeSheet(_ spec: ExcelSheetSpec, to w: XLSXWriter, options o: ExcelExportOptions) async throws {
		let size = 1000
		var batch = try await spec.fetch(0, size)
		let cols = batch.columns
		let kinds = cols.map(ExcelValue.kind)
		let titles: [String] = cols.map { c in
			let comment = (spec.comments[c.orgName.isEmpty ? c.name : c.orgName] ?? spec.comments[c.name] ?? "")
			switch o.headerComment {
			case .name: return c.name
			case .comment: return comment.isEmpty ? c.name : comment
			case .nameAndComment: return comment.isEmpty ? c.name : "\(c.name) (\(comment))"
			}
		}
		// 너비: 첫 묶음과 제목으로 어림 (날짜는 고정)
		let widths: [Double] = cols.indices.map { i in
			switch kinds[i] {
			case .date: return 11
			case .dateTime: return 19
			default:
				var m = o.header ? ExcelValue.displayWidth(titles[i]) + 2 : 6
				for r in batch.rows.prefix(200) where i < r.count { m = max(m, ExcelValue.displayWidth(r[i].string ?? "")) }
				return Double(min(max(m + 1, 6), 60))
			}
		}
		var part = 1
		func start() throws {
			try w.beginSheet(part == 1 ? spec.name : "\(spec.name) (\(part))", widths: widths, freezeHeader: o.header)
			if o.header { try w.row(titles.map { .text($0) }, header: true) }
		}
		try start()
		var offset = 0
		while !cancelled {
			for r in batch.rows {
				if w.rowsInSheet >= XLSXWriter.maxRows {
					try w.endSheet()
					part += 1
					try start()
				}
				try w.row(r.indices.map { i in ExcelValue.cell(r[i], i < kinds.count ? kinds[i] : .text, keepTypes: o.keepTypes) })
			}
			written += batch.rows.count
			if batch.rows.count < size { break }
			offset += size
			batch = try await spec.fetch(offset, size)
		}
		try w.endSheet()
	}

	/// 파일 이름에 못 쓰는 글자(/ :)는 _
	private static func safeFileName(_ s: String) -> String {
		let t = String(s.map { "/:".contains($0) ? "_" : $0 })
		return t.isEmpty ? "sheet" : t
	}

	/// 같은 이름이 있으면 "이름 2.xlsx"
	private static func freeURL(_ u: URL) -> URL {
		var url = u, i = 2
		let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
		while FileManager.default.fileExists(atPath: url.path) {
			url = u.deletingLastPathComponent().appendingPathComponent("\(base) \(i).\(ext)")
			i += 1
		}
		return url
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
	var exportResultColumns: [Column] { columns }
	var exportColumnComments: [String: String] {
		Dictionary((session.columns[table.id] ?? []).map { ($0.name, $0.comment) }, uniquingKeysWith: { a, _ in a })
	}
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
	var exportResultColumns: [Column] { result.columns }
	/// 원래 테이블의 컬럼 코멘트 (별칭이면 결과 이름으로)
	var exportColumnComments: [String: String] {
		var d: [String: String] = [:]
		for c in result.columns where !c.orgTable.isEmpty {
			let info = session?.columns["\(c.schema).\(c.orgTable)"]?.first { $0.name.caseInsensitiveCompare(c.orgName) == .orderedSame }
			if let info, !info.comment.isEmpty, d[c.name] == nil { d[c.name] = info.comment }
		}
		return d
	}
}
