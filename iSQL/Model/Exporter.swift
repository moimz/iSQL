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
	/// 구조를 넣을 때 트리거를 찾을 원래 테이블 (DB, 이름)
	var exportTableRef: (schema: String, table: String)? { get }
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
		let dialect = session.dialect
		let info = session.columns[schema + "." + t.name] ?? []
		let pk = info.filter { $0.key == "PRI" }.map { dialect.quote($0.name) }
		let order = pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", ")
		let q = dialect.quote(schema: schema, table: t.name)
		return ExcelSheetSpec(name: t.name, comments: Dictionary(info.map { ($0.name, $0.comment) }, uniquingKeysWith: { a, _ in a }),
		                      total: t.rows.map { Int($0) }) { offset, limit in
			let r = try await session.query(dialect.paged("SELECT * FROM \(q)\(order)", limit: limit, offset: offset)).last ?? QueryResult()
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

	// iModules 내보내기(아래 확장)가 쓰는 시작·끝·진행
	var cancelledFlag: Bool { cancelled }
	var writtenCount: Int { written }
	@MainActor func begin(url: URL, total t: Int?) -> Bool {
		guard !running else { return false }
		running = true; cancelled = false; written = 0; message = nil; isError = false; finished = false
		fileName = url.lastPathComponent; total = t; totalApprox = t != nil
		return true
	}
	@MainActor func end() { running = false; finished = true }
	@MainActor func addWritten(_ n: Int) { written += n }
	@MainActor func finish(_ text: String) { message = cancelled ? "그만둠 · \(written.formatted())행까지 썼습니다" : text }

	/// SQL 파일로 내보낸다. 데이터는 1000행씩 받아 바로 쓴다 (큰 테이블도 메모리를 많이 안 쓰게)
	@MainActor
	func exportSQL(_ src: ExportSource, options o: SQLExportOptions, to url: URL) async {
		let dialect = src.exportSession?.dialect ?? SQLKind.mysql.dialect
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

		let table = dialect.quote(o.tableName)
		let cols = src.exportColumns
		let colList = cols.map { dialect.quote($0.name) }.joined(separator: ", ")
		let df = ISO8601DateFormatter()
		write("""
			-- iSQL 내보내기
			-- 대상: \(o.tableName)\(src.exportSession?.server.map { " · 서버 \($0.displayName)" } ?? "")
			-- 만든 시각: \(df.string(from: Date()))
			-- 데이터: \(o.visibleOnly ? "화면에 보이는 행만" : "전체")

			\(dialect.dumpPrologue.map { $0 + ";" }.joined(separator: "\n"))


			""")
		do {
			if o.includeStructure, src.canExportStructure {
				if o.includeDrop { write(dialect.dropIfExists(table, view: false) + ";\n") }
				if let create = try await src.createTableSQL() { write(create + ";\n\n") }
			}
			// 숫자 컬럼은 따옴표 없이
			func value(_ v: Value, _ numeric: Bool) -> String {
				if numeric, case .text(let s) = v, Double(s) != nil { return s }
				return dialect.literal(v)
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
			// 트리거 (화면에 보이는 행만이 아닐 때 · 구조를 넣을 때)
			if o.includeStructure, src.canExportStructure, !cancelled, let ref = src.exportTableRef, let session = src.exportSession {
				let triggers = try await Self.triggerDump(session, schema: ref.schema, tables: [ref.table], drop: o.includeDrop)
				if !triggers.isEmpty { write("\n-- 트리거\n" + triggers) }
			}
			write("\n" + dialect.dumpEpilogue.map { $0 + ";\n" }.joined())
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
		let dialect = session.dialect
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

			\(dialect.dumpPrologue.map { $0 + ";" }.joined(separator: "\n"))


			""")
		do {
			// 같은 DB 에 다시 넣을 때 막히지 않게 (SQL Server: 내보낸 테이블끼리의 외래 키 먼저 지우기)
			if o.includeStructure, o.includeDrop {
				let pre = session.meta.dumpPreamble(schema: schema, tables: tables.filter { !$0.isView }.map(\.name))
				if !pre.isEmpty {
					write("-- 다시 넣을 때 테이블 지우기가 막히지 않게 외래 키 먼저 지우기\n" + pre.map { $0 + ";\n" + (dialect.batchSeparator.map { $0 + "\n" } ?? "") }.joined() + "\n")
				}
			}
			// 테이블 먼저, 뷰는 나중 (뷰는 만들 때 가리키는 테이블이 있어야 한다 — 이름 순으로 앞에 오는 뷰가 뒤 테이블을 가리키면 실패했다)
			for t in tables.filter({ !$0.isView }) + tables.filter(\.isView) where !cancelled {
				let q = dialect.quote(schema: schema, table: t.name)
				write("-- ----------------------------------------\n-- \(t.name)\(t.comment.isEmpty ? "" : " · " + t.comment)\n-- ----------------------------------------\n")
				// SQL Server: 문장 묶음마다 GO (CREATE VIEW 등은 배치에 혼자여야 한다). 다른 DB 는 아무것도 안 씀
				func endBatch() { if let sep = dialect.batchSeparator { write(sep + "\n") } }
				if o.includeStructure {
					if o.includeDrop { write(dialect.dropIfExists(dialect.quoteLocal(t.name), view: t.isView) + ";\n"); endBatch() }
					if let create = try await session.meta.dumpCreate(session.query, schema: schema, name: t.name) { write(create + ";\n"); endBatch(); write("\n") }
				}
				guard o.includeData, !t.isView else { continue }
				let cols = (session.columns[schema + "." + t.name] ?? [])
				let pk = cols.filter { $0.key == "PRI" }.map { dialect.quote($0.name) }
				let order = pk.isEmpty ? "" : " ORDER BY " + pk.joined(separator: ", ")
				var offset = 0
				let size = 1000
				// SQL Server: IDENTITY 컬럼에 값을 넣으려면 그 동안 IDENTITY_INSERT 를 켠다
				let identity = cols.contains { $0.extra == "auto_increment" } ? dialect.identityInsert(dialect.quoteLocal(t.name), true) : nil
				if let identity { write(identity + ";\n") }
				defer { if identity != nil, let off = dialect.identityInsert(dialect.quoteLocal(t.name), false) { write(off + ";\n") } }
				while !cancelled {
					let res = try await session.query(dialect.paged("SELECT * FROM \(q)\(order)", limit: size, offset: offset)).last ?? QueryResult()
					let names = res.columns.map { dialect.quote($0.orgName.isEmpty ? $0.name : $0.orgName) }.joined(separator: ", ")
					let numeric = res.columns.map(\.isNumeric)
					var i = 0
					while i < res.rows.count {
						let chunk = res.rows[i..<min(i + 100, res.rows.count)]
						let values = chunk.map { r in "(" + r.enumerated().map { e in
							if e.offset < numeric.count, numeric[e.offset], case .text(let v) = e.element, Double(v) != nil { return v }
							return dialect.literal(e.element)
						}.joined(separator: ", ") + ")" }
						write(dialect.insertRows(dialect.quoteLocal(t.name), columns: names, rows: values) + ";\n")
						i += 100
					}
					written += res.rows.count
					if res.rows.count < size { break }
					offset += size
				}
				write("\n")
			}
			if o.includeStructure, !cancelled {
				let trailer = try await session.meta.dumpTrailer(session.query, schema: schema, tables: tables.filter { !$0.isView }.map(\.name))
				if !trailer.isEmpty { write("-- 외래 키 · 자동 증가\n" + trailer.map { $0 + ";\n" }.joined() + "\n") }
			}
			if o.includeStructure, !cancelled {
				let triggers = try await Self.triggerDump(session, schema: schema, tables: Set(tables.map(\.name)), drop: o.includeDrop)
				if !triggers.isEmpty { write("-- ----------------------------------------\n-- 트리거\n-- ----------------------------------------\n" + triggers) }
			}
			write(dialect.dumpEpilogue.map { $0 + ";\n" }.joined())
			message = cancelled ? "그만둠 · \(written.formatted())행까지 썼습니다" : "테이블 \(tables.count)개 · \(written.formatted())행 내보냄 · \(url.lastPathComponent)"
		} catch {
			fail(error.localizedDescription)
		}
	}

	/// 내보낸 테이블에 걸린 트리거 (데이터 다음에 둔다 — 먼저 만들면 넣는 행마다 돌아 값이 바뀐다).
	/// routines 의 트리거 설명은 모든 DB 가 "… · 테이블" 로 끝난다
	@MainActor
	static func triggerDump(_ session: Session, schema: String, tables: Set<String>, drop: Bool) async throws -> String {
		let dialect = session.dialect
		let list = try await session.meta.routines(session.query).filter { r in
			r.kind == .trigger && r.schema == schema && tables.contains(r.detail.components(separatedBy: " · ").last ?? "")
		}
		var out = ""
		for t in list.sorted(by: { $0.name < $1.name }) {
			guard let ddl = try await session.meta.createStatement(session.query, .routine(.trigger), schema: schema, name: t.name) else { continue }
			out += "-- 트리거 \(t.name) · \(t.detail)\n" + dialect.dumpTrigger(ddl, name: t.name, schema: schema, drop: drop) + "\n"
		}
		return out
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
		try await session.meta.createStatement(session.query, .table, schema: table.schema, name: table.name)
	}

	/// 화면과 같은 조건(appliedWhere)·정렬로 전체를 나눠 받는다
	func fetchRows(offset: Int, limit: Int) async throws -> [[Value]] {
		let pk = (session.columns[table.id] ?? []).filter { $0.key == "PRI" }.map { dialect.quote($0.name) }
		var orderParts: [String] = []
		if let sort { orderParts.append(dialect.quote(sort.column) + (sort.ascending ? " ASC" : " DESC")) }
		orderParts += pk.filter { $0 != sort.map { dialect.quote($0.column) } }
		let order = orderParts.isEmpty ? "" : " ORDER BY " + orderParts.joined(separator: ", ")
		let sql = dialect.paged("SELECT * FROM \(dialect.quote(table: table))\(appliedWhere.isEmpty ? "" : " WHERE " + appliedWhere)\(order)", limit: limit, offset: offset)
		return try await session.query(sql).last?.rows ?? []
	}

	var exportSession: Session? { session }
	var exportTableRef: (schema: String, table: String)? { table.isView ? nil : (table.schema, table.name) }
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
		return try await session.meta.createStatement(session.query, .table, schema: t.schema, name: t.table)
	}

	/// 전체: LIMIT 을 자동으로 붙였던 쿼리면 나눠 받고, 직접 LIMIT 을 쓴 쿼리면 지금 결과가 전체
	func fetchRows(offset: Int, limit: Int) async throws -> [[Value]] {
		guard paged, let session else { return offset == 0 ? result.rows : [] }
		return try await session.query(dialect.paged(sql, limit: limit, offset: offset)).last?.rows ?? []
	}

	var exportSession: Session? { session }
	var exportTableRef: (schema: String, table: String)? { singleTable }
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

// MARK: - iModules 형식 (package.json 의 databases 자리에 붙이는 { "테이블": { columns, indexes, auto_increment, comment, datas } })

/// iModules 내보내기 옵션
struct IModulesExportOptions {
	/// 테이블 이름에서 뺄 접두어 (im_core_ 등)
	var prefix = ""
	/// 데이터(datas) 넣기
	var includeData = false
}

extension ExportJob {
	/// iModules 스키마 JSON. 형식은 iModules app/databases/mysql/Builder.php 가 읽는 그대로:
	/// columns{type,length,is_null,default,comment}, indexes{"a,b": primary_key|unique|index|fulltext}, auto_increment, comment, datas[행 객체]
	@MainActor
	/// MySQL 전용 (iModules 는 MySQL 스키마 형식): SHOW FULL COLUMNS·SHOW INDEX 결과를 그대로 푼다. 3단계에서 MySQL 계열에서만 보이게
	func exportIModules(session: Session, schema: String, tables: [TableStat], options o: IModulesExportOptions, to url: URL) async {
		let dialect = session.dialect
		guard begin(url: url, total: o.includeData ? tables.map { $0.rows.map { Int($0) } }.reduce(0) { a, b in a.flatMap { x in b.map { x + $0 } } } : nil) else { return }
		defer { end() }
		var notes: [String] = []
		do {
			FileManager.default.createFile(atPath: url.path, contents: nil)
			let h = try FileHandle(forWritingTo: url)
			defer { try? h.close() }
			func w(_ s: String) { h.write(Data(s.utf8)) }
			let list = tables.filter { !$0.isView }
			if list.count < tables.count { notes.append("뷰 \(tables.count - list.count)개는 뺐습니다") }
			w("{\n")
			for (ti, t) in list.enumerated() where !cancelledFlag {
				let name = o.prefix.isEmpty || !t.name.hasPrefix(o.prefix) ? t.name : String(t.name.dropFirst(o.prefix.count))
				let q = dialect.quote(schema: schema, table: t.name)
				let cols = try await session.query("SHOW FULL COLUMNS FROM \(q)").last ?? QueryResult()
				let idx = try await session.query("SHOW INDEX FROM \(q)").last ?? QueryResult()
				w("    \(Self.json(name)): {\n        \"columns\": {\n")
				func c(_ r: QueryResult, _ row: [Value], _ n: String) -> String? {
					r.columns.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame }.flatMap { row[safe: $0]?.string }
				}
				var auto: String?
				for (ci, row) in cols.rows.enumerated() {
					let field = c(cols, row, "Field") ?? ""
					let type = c(cols, row, "Type") ?? ""
					let extra = (c(cols, row, "Extra") ?? "").lowercased()
					let parsed = Self.parseType(type)
					if parsed.unsigned { notes.append("\(t.name).\(field) UNSIGNED") }
					if extra.contains("generated") && !extra.contains("default_generated") { notes.append("\(t.name).\(field) 계산 컬럼") }
					if extra.contains("auto_increment") { auto = field }
					var props: [String] = ["\"type\": \(Self.json(parsed.base))"]
					if let len = parsed.length { props.append("\"length\": \(len)") }
					if c(cols, row, "Null") == "YES" { props.append("\"is_null\": true") }
					if let d = c(cols, row, "Default") {
						if extra.contains("default_generated") { notes.append("\(t.name).\(field) 기본값 식(\(d))") }
						else { props.append("\"default\": " + (Self.numericTypes.contains(parsed.base) && Double(d) != nil ? d : Self.json(d))) }
					}
					if let cm = c(cols, row, "Comment"), !cm.isEmpty { props.append("\"comment\": \(Self.json(cm))") }
					w("            \(Self.json(field)): {\n" + props.map { "                " + $0 }.joined(separator: ",\n") + "\n            }"
					  + (ci < cols.rows.count - 1 ? "," : "") + "\n")
				}
				w("        },\n")
				// 인덱스: 이름 → (종류, 컬럼들). PRIMARY 먼저
				var order: [String] = []
				var keys: [String: (kind: String, cols: [String])] = [:]
				for row in idx.rows {
					let key = c(idx, row, "Key_name") ?? ""
					let col = c(idx, row, "Column_name") ?? ""
					if c(idx, row, "Sub_part") != nil { notes.append("\(t.name) 인덱스 \(key) 접두 길이") }
					if keys[key] == nil {
						order.append(key)
						let kind = key == "PRIMARY" ? "primary_key"
							: c(idx, row, "Index_type") == "FULLTEXT" ? "fulltext"
							: c(idx, row, "Non_unique") == "0" ? "unique" : "index"
						keys[key] = (kind, [])
					}
					keys[key]?.cols.append(col)
				}
				order = order.filter { $0 == "PRIMARY" } + order.filter { $0 != "PRIMARY" }
				let idxLines = order.compactMap { k in keys[k].map { "            \(Self.json($0.cols.joined(separator: ","))): \(Self.json($0.kind))" } }
				w("        \"indexes\": {" + (idxLines.isEmpty ? "}" : "\n" + idxLines.joined(separator: ",\n") + "\n        }"))
				if let auto { w(",\n        \"auto_increment\": \(Self.json(auto))") }
				w(",\n        \"comment\": \(Self.json(t.comment))")
				if o.includeData {
					w(",\n        \"datas\": [")
					let spec = ExcelSheetSpec.table(session: session, schema: schema, t)
					var offset = 0, first = true
					while !cancelledFlag {
						let batch = try await spec.fetch(offset, 1000)
						for r in batch.rows {
							let obj = batch.columns.indices.map { i in "\(Self.json(batch.columns[i].name)): \(Self.jsonValue(r[safe: i] ?? .null, batch.columns[i]))" }
							w((first ? "\n" : ",\n") + "            {" + obj.joined(separator: ", ") + "}")
							first = false
						}
						addWritten(batch.rows.count)
						if batch.rows.count < 1000 { break }
						offset += 1000
					}
					w(first ? "]" : "\n        ]")
				}
				w("\n    }" + (ti < list.count - 1 ? "," : "") + "\n")
			}
			w("}\n")
			let fk = (try? await session.query("SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = \(dialect.literal(.text(schema)))").last?.rows.first?.first?.string) ?? nil
			if let fk, let n = Int(fk), n > 0 { notes.append("외래 키 \(n)개 (iModules 형식에 없음)") }
			let head = "테이블 \(list.count)개" + (o.includeData ? " · \(writtenCount.formatted())행" : "") + " 내보냄 · \(url.lastPathComponent)"
			finish(notes.isEmpty ? head : head + "\n빠진 것: " + notes.prefix(8).joined(separator: ", ") + (notes.count > 8 ? " 외 \(notes.count - 8)개" : ""))
		} catch {
			fail(error.localizedDescription)
		}
	}

	static let numericTypes: Set<String> = ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "bit", "year"]

	/// "varchar(36)" → varchar, 36 / "decimal(10,2) unsigned" → decimal, "10,2", unsigned / "enum('a','b')" → enum, "'a','b'"
	static func parseType(_ t: String) -> (base: String, length: String?, unsigned: Bool) {
		let lower = t.lowercased()
		let unsigned = lower.contains(" unsigned")
		guard let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"), open < close else {
			return (String(lower.split(separator: " ").first ?? ""), nil, unsigned)
		}
		let base = String(lower[..<open]).trimmingCharacters(in: .whitespaces)
		let inner = String(t[t.index(after: open)..<close])
		if inner.allSatisfy(\.isNumber) { return (base, inner, unsigned) }
		return (base, json(inner), unsigned)
	}

	/// JSON 글자 (따옴표·역슬래시·줄바꿈·제어 문자 바꾸기)
	static func json(_ s: String) -> String {
		var o = "\""
		for u in s.unicodeScalars {
			switch u {
			case "\"": o += "\\\""
			case "\\": o += "\\\\"
			case "\n": o += "\\n"
			case "\r": o += "\\r"
			case "\t": o += "\\t"
			default: if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
			}
		}
		return o + "\""
	}

	/// datas 값: 숫자 컬럼의 숫자는 숫자(15자리까지), NULL 은 null, 바이너리는 base64
	static func jsonValue(_ v: Value, _ c: Column) -> String {
		switch v {
		case .null: return "null"
		case .bytes(let d): return json(d.base64EncodedString())
		case .text(let t):
			if c.isNumeric, Double(t) != nil, t.filter(\.isNumber).count <= 15 { return t }
			return json(t)
		}
	}
}
