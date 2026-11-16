import Foundation
import Observation

/// 엑셀 가져오기 요청 (DB·테이블 오른쪽 클릭 → 파일 고르기 → 창이 제목바 시트로)
struct ExcelImportRequest: Identifiable {
	let id = UUID()
	let schema: String
	/// 기존 테이블에 넣을 때 (테이블 오른쪽 클릭)
	let table: String?
	let job: ExcelImportJob
}

/// 엑셀(xlsx) 가져오기: 시트 하나를 새 테이블로 만들거나 기존 테이블에 넣는다.
/// 옵션: 첫 행을 컬럼 이름으로(끄면 A, B, C …), 컬럼별 데이터 형식 고려(숫자·날짜 → INT/DECIMAL/DATE…, 끄면 모두 글자).
/// 가져오기 전용 연결에서 트랜잭션 하나로 500행씩 넣고, 오류가 나면 모두 되돌린다
@MainActor
@Observable
final class ExcelImportJob {
	enum Target: Hashable { case newTable, existing }

	@ObservationIgnored private weak var session: Session?
	let schema: String
	private(set) var url: URL
	private(set) var fileSize: Int64 = 0

	private(set) var sheets: [XLSXReader.Sheet] = []
	var sheetIndex = 0 { didSet { if oldValue != sheetIndex && !opening { loadSheet() } } }
	private(set) var loadError: String?
	/// 파일·시트를 읽는 중 (큰 파일은 몇 초 걸려서 메인 밖에서 읽는다)
	private(set) var loading = false
	@ObservationIgnored private var opening = false
	@ObservationIgnored private var loadToken = 0

	// 옵션
	var header = true { didSet { if oldValue != header { recompute() } } }
	var typed = true { didSet { if oldValue != typed { recompute() } } }
	var target = Target.newTable
	var newName = ""
	var existingName = ""
	/// 새 테이블에 자동 증가 id 기본 키 컬럼을 붙인다 (기본 키가 있어야 iSQL 에서 고칠 수 있다)
	var addID = true

	// 진행
	private(set) var running = false
	private(set) var finished = false
	private(set) var done = 0
	private(set) var message: String?
	private(set) var isError = false
	@ObservationIgnored private var cancelled = false

	@ObservationIgnored private var reader: XLSXReader?
	/// 지금 시트의 모든 행 (형식을 정하려면 다 봐야 한다)
	private(set) var raw: [[XLSXValue]] = []

	init(url: URL, session: Session, schema: String, table: String?) {
		self.url = url
		self.session = session
		self.schema = schema
		if let table { target = .existing; existingName = table }
		open()
	}

	func change(to url: URL) {
		guard !running, !finished else { return }
		self.url = url
		open()
	}

	private func open() {
		fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		loadError = nil
		let url = self.url
		loadToken += 1
		let token = loadToken
		loading = true
		Task {
			let result = await Task.detached { () -> Result<XLSXReader, Error> in Result { try XLSXReader(url: url) } }.value
			guard token == loadToken else { return }
			switch result {
			case .success(let r):
				reader = r
				opening = true
				sheets = r.sheets
				sheetIndex = 0
				opening = false
				loadSheet()
			case .failure(let e):
				reader = nil
				sheets = []
				raw = []
				recompute()
				loading = false
				loadError = e.localizedDescription
			}
		}
	}

	private func loadSheet() {
		guard let reader, sheets.indices.contains(sheetIndex) else { raw = []; recompute(); loading = false; return }
		let sheet = sheets[sheetIndex]
		loadToken += 1
		let token = loadToken
		loading = true
		Task {
			let result = await Task.detached { () -> Result<[[XLSXValue]], Error> in
				Result {
					var rows = try reader.rows(of: sheet)
					// 뒤쪽 빈 행은 뺀다
					while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
					return rows
				}
			}.value
			guard token == loadToken else { return }
			loading = false
			switch result {
			case .success(let rows):
				raw = rows
				recompute()
				if newName.isEmpty || sheets.contains(where: { Self.tableName($0.name) == newName }) { newName = Self.tableName(sheet.name) }
				loadError = nil
			case .failure(let e):
				raw = []
				recompute()
				loadError = e.localizedDescription
			}
		}
	}

	/// 이름·형식은 행이나 옵션이 바뀔 때만 다시 계산한다 (모든 행을 훑으므로 화면을 그릴 때마다 하지 않는다)
	private func recompute() {
		dataRows = (header ? Array(raw.dropFirst()) : raw).filter { !$0.allSatisfy(\.isEmpty) }
		names = computeNames()
		kinds = computeKinds()
	}
	private(set) var names: [String] = []
	private(set) var kinds: [Kind] = []

	/// 시트 이름 → 테이블 이름 (공백은 _)
	private static func tableName(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
		return t.isEmpty ? "sheet" : t
	}

	// MARK: 컬럼·형식

	var columnCount: Int { raw.map(\.count).max() ?? 0 }
	/// 넣을 행: 첫 행(이름)을 빼고, 중간의 완전히 빈 행도 뺀다 (엑셀에서 띄어 둔 줄)
	private(set) var dataRows: [[XLSXValue]] = []

	/// 엑셀 열 이름 (A, B …)
	static func letter(_ i: Int) -> String { XLSXWriter.columnName(i) }

	/// 컬럼 이름: 첫 행(비면 column_n, 겹치면 _2) 또는 A, B, C
	private func computeNames() -> [String] {
		let n = columnCount
		guard header, let first = raw.first else { return (0..<n).map(Self.letter) }
		var used = Set<String>()
		return (0..<n).map { i in
			var name = Self.columnName(i < first.count ? Self.text(first[i]) : nil)
			if name.isEmpty { name = "column_\(i + 1)" }
			var unique = name, k = 2
			while used.contains(unique.lowercased()) {
				let tail = "_\(k)"
				unique = String(name.prefix(Self.maxNameLength - tail.count)) + tail
				k += 1
			}
			used.insert(unique.lowercased())
			return unique
		}
	}

	/// MySQL 컬럼 이름 길이 한도
	static let maxNameLength = 64

	/// 엑셀 제목 칸 → 컬럼 이름: 칸 안 줄바꿈·탭은 띄어쓰기 하나로 (그대로 두면 이름이 두 줄인 컬럼이 생겼다),
	/// 앞뒤 공백은 빼고(MySQL 은 끝 공백 이름을 거부한다), 64자까지
	static func columnName(_ raw: String?) -> String {
		guard let raw else { return "" }
		let words = raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)).filter { !$0.isEmpty }
		return String(words.joined(separator: " ").prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
	}

	enum Kind: Equatable { case int, bigint, decimal(Int, Int), double, date, datetime, varchar(Int), text }

	/// 컬럼별 형식 (새 테이블에 쓴다). 형식 고려를 끄면 모두 글자
	private func computeKinds() -> [Kind] {
		(0..<columnCount).map { i in
			var lengths = 0
			var allDate = true, allDateOnly = true, allNumber = true, allInt = true, anyExp = false
			var maxAbs = 0.0, intDigits = 1, scale = 0, count = 0
			for r in dataRows {
				let v = i < r.count ? r[i] : .empty
				if v.isEmpty { continue }
				count += 1
				lengths = max(lengths, (Self.text(v) ?? "").count)
				switch v {
				case .date(let d):
					allNumber = false
					if d != d.rounded(.down) { allDateOnly = false }
				case .number(let s):
					allDate = false
					guard let d = Double(s) else { allNumber = false; continue }
					maxAbs = max(maxAbs, abs(d))
					if s.contains("E") || s.contains("e") { anyExp = true; allInt = false }
					if let dot = s.firstIndex(of: ".") {
						allInt = false
						scale = max(scale, s.distance(from: dot, to: s.endIndex) - 1)
						intDigits = max(intDigits, s.distance(from: s.startIndex, to: dot) - (s.hasPrefix("-") ? 1 : 0))
					} else {
						intDigits = max(intDigits, s.count - (s.hasPrefix("-") ? 1 : 0))
					}
				case .bool:
					allDate = false
				default:
					allDate = false
					allNumber = false
				}
			}
			let textKind: Kind = lengths > 1000 ? .text : .varchar([50, 100, 255, 500, 1000].first { $0 >= lengths } ?? 1000)
			guard typed, count > 0 else { return textKind }
			if allDate { return allDateOnly ? .date : .datetime }
			if allNumber {
				if allInt { return maxAbs <= 2_147_483_647 ? .int : .bigint }
				if anyExp || scale > 10 || intDigits + scale > 30 { return .double }
				return .decimal(intDigits + scale, scale)
			}
			return textKind
		}
	}

	static func sqlType(_ k: Kind) -> String {
		switch k {
		case .int: "INT"
		case .bigint: "BIGINT"
		case .decimal(let m, let d): "DECIMAL(\(m),\(d))"
		case .double: "DOUBLE"
		case .date: "DATE"
		case .datetime: "DATETIME"
		case .varchar(let n): "VARCHAR(\(n))"
		case .text: "TEXT"
		}
	}

	/// 칸 → 글자 (날짜는 YYYY-MM-DD[ HH:MM:SS], 참/거짓은 1/0)
	static func text(_ v: XLSXValue) -> String? {
		switch v {
		case .empty: nil
		case .text(let s): s
		case .number(let s): s
		case .date(let d): XLSXReader.dateString(d)
		case .bool(let b): b ? "1" : "0"
		}
	}

	/// 기존 테이블: 엑셀 열 → 테이블 컬럼 (첫 행 이름이면 이름으로, 아니면 순서대로). 맞는 게 없으면 nil
	var mapping: [String?] {
		guard target == .existing, let cols = session?.columns[schema + "." + existingName] else { return [] }
		let names = self.names
		if header {
			return names.map { n in cols.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.name }
		}
		return names.indices.map { $0 < cols.count ? cols[$0].name : nil }
	}

	private func existingType(_ column: String) -> String {
		(session?.columns[schema + "." + existingName]?.first { $0.name == column }?.type ?? "").lowercased()
	}

	var existingTables: [String] {
		session?.tables.filter { $0.schema == schema && !$0.isView }.map(\.name) ?? []
	}

	var nameTaken: Bool {
		session?.tables.contains { $0.schema == schema && $0.name.caseInsensitiveCompare(newName.trimmingCharacters(in: .whitespaces)) == .orderedSame } ?? false
	}

	var canRun: Bool {
		guard !running, !finished, !loading, loadError == nil, columnCount > 0, !dataRows.isEmpty else { return false }
		switch target {
		case .newTable: return !newName.trimmingCharacters(in: .whitespaces).isEmpty && !nameTaken
		case .existing: return !existingName.isEmpty && mapping.contains { $0 != nil }
		}
	}

	/// 새 테이블 CREATE 문 (미리 보기에도)
	var createSQL: String {
		let q = TableInspector.ident
		let names = self.names, kinds = self.kinds
		var defs = names.indices.map { "\(q(names[$0])) \(Self.sqlType(kinds[$0])) NULL" }
		let hasID = names.contains { $0.lowercased() == "id" }
		if addID && !hasID { defs.insert("`id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY", at: 0) }
		return "CREATE TABLE \(q(schema)).\(q(newName.trimmingCharacters(in: .whitespaces))) (\n  " + defs.joined(separator: ",\n  ") + "\n)"
	}

	// MARK: 넣기

	func cancel() { cancelled = true }

	func run() async {
		guard let session, canRun else { return }
		running = true
		cancelled = false
		message = nil
		isError = false
		done = 0
		let q = TableInspector.ident
		let names = self.names, kinds = self.kinds
		let tableName = target == .newTable ? newName.trimmingCharacters(in: .whitespaces) : existingName
		let full = "\(q(schema)).\(q(tableName))"
		// 넣을 열과 대상 컬럼
		var pairs: [(col: Int, name: String, numeric: Bool, dateOnly: Bool)] = []
		if target == .newTable {
			for i in names.indices {
				let k = kinds[i]
				let numeric: Bool = { switch k { case .int, .bigint, .decimal, .double: true; default: false } }()
				pairs.append((i, names[i], numeric, k == .date))
			}
		} else {
			for (i, m) in mapping.enumerated() {
				guard let m else { continue }
				let t = existingType(m)
				pairs.append((i, m, false, t.hasPrefix("date") && !t.hasPrefix("datetime")))
			}
		}
		let colList = pairs.map { q($0.name) }.joined(separator: ", ")
		let rows = dataRows
		var conn: MySQLConnection?
		var created = false
		do {
			let c = try await session.sideConnection()
			conn = c
			if target == .newTable {
				_ = try await c.query(createSQL)
				created = true
			}
			_ = try await c.query("START TRANSACTION")
			var i = 0
			while i < rows.count {
				if cancelled { break }
				let chunk = rows[i..<min(i + 500, rows.count)]
				let values = chunk.map { r -> String in
					"(" + pairs.map { p -> String in
						let v = p.col < r.count ? r[p.col] : .empty
						guard var s = Self.text(v) else { return "NULL" }
						if p.dateOnly, s.count > 10 { s = String(s.prefix(10)) }
						if p.numeric, Double(s) != nil { return s }
						return literal(.text(s))
					}.joined(separator: ", ") + ")"
				}
				do {
					_ = try await c.query("INSERT INTO \(full) (\(colList)) VALUES " + values.joined(separator: ", "))
				} catch {
					// 엑셀 행 번호로 알려 준다 (첫 행이 이름이면 +1)
					let first = i + 1 + (header ? 1 : 0)
					throw ImportFailure(text: "엑셀 \(first.formatted())~\((first + chunk.count - 1).formatted())행에서 오류: \(error.localizedDescription)")
				}
				i += chunk.count
				done = i
			}
			if cancelled {
				_ = try? await c.query("ROLLBACK")
				message = "그만뒀습니다 · 넣은 행은 모두 되돌렸습니다" + (created ? " (\(tableName) 는 빈 채로 남음)" : "")
				isError = true
			} else {
				_ = try await c.query("COMMIT")
				message = "\(tableName) 에 \(rows.count.formatted())행 넣음"
			}
		} catch {
			_ = try? await conn?.query("ROLLBACK")
			message = error.localizedDescription + (created ? "\n넣은 행은 되돌렸습니다 (\(tableName) 는 빈 채로 남음)" : "\n넣은 행은 모두 되돌렸습니다")
			isError = true
		}
		conn?.close()
		running = false
		finished = true
		if created { await session.tableCreated(schema: schema, name: tableName) }
		else { await session.dataImported(schema: schema) }
	}

	struct ImportFailure: LocalizedError { let text: String; var errorDescription: String? { text } }
}
