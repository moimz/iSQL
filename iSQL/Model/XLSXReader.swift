import Foundation
import Compression

/// zip 읽기 (중앙 디렉터리 → 항목 하나씩 풀기). deflate 는 맥의 Compression(raw deflate)
struct ZipReader {
	private let data: Data
	private(set) var entries: [String: (offset: Int, method: UInt16, csize: Int, usize: Int)] = [:]

	enum ZipError: LocalizedError {
		case notZip, missing(String), unsupported, inflate
		var errorDescription: String? {
			switch self {
			case .notZip: return "엑셀(xlsx) 파일이 아닙니다"
			case .missing(let n): return "파일 안에 \(n) 이(가) 없습니다"
			case .unsupported: return "지원하지 않는 압축 방식입니다"
			case .inflate: return "압축을 풀지 못했습니다"
			}
		}
	}

	init(url: URL) throws {
		data = try Data(contentsOf: url, options: .mappedIfSafe)
		try readDirectory()
	}

	private func u16(_ i: Int) -> Int { Int(data[data.startIndex + i]) | Int(data[data.startIndex + i + 1]) << 8 }
	private func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

	private mutating func readDirectory() throws {
		// 끝에서 "PK\5\6" 찾기 (주석 최대 64KB)
		let n = data.count
		guard n >= 22 else { throw ZipError.notZip }
		var eocd = -1
		var i = n - 22
		while i >= max(0, n - 22 - 65_535) {
			if u32(i) == 0x06054B50 { eocd = i; break }
			i -= 1
		}
		guard eocd >= 0 else { throw ZipError.notZip }
		let count = u16(eocd + 10)
		var p = u32(eocd + 16)
		for _ in 0..<count {
			guard p + 46 <= n, u32(p) == 0x02014B50 else { throw ZipError.notZip }
			let method = UInt16(u16(p + 10))
			let csize = u32(p + 20), usize = u32(p + 24)
			let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
			let local = u32(p + 42)
			let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen)], as: UTF8.self)
			entries[name] = (local, method, csize, usize)
			p += 46 + nameLen + extraLen + commentLen
		}
	}

	func has(_ name: String) -> Bool { entries[name] != nil }

	/// 항목 하나를 풀어서
	func read(_ name: String) throws -> Data {
		guard let e = entries[name] else { throw ZipError.missing(name) }
		let lh = e.offset
		guard u32(lh) == 0x04034B50 else { throw ZipError.notZip }
		let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
		let comp = data[(data.startIndex + start)..<(data.startIndex + start + e.csize)]
		switch e.method {
		case 0: return Data(comp)
		case 8: return try Self.inflate(Data(comp), size: e.usize)
		default: throw ZipError.unsupported
		}
	}

	private static func inflate(_ src: Data, size: Int) throws -> Data {
		guard size > 0 else { return Data() }
		var out = Data(count: size)
		let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
			src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
				compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
				                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written == size else { throw ZipError.inflate }
		return out
	}
}

/// 엑셀 칸 값
enum XLSXValue: Equatable {
	case empty
	case text(String)
	/// 숫자 (글자 그대로)
	case number(String)
	/// 날짜 서식이 붙은 숫자 (일련번호)
	case date(Double)
	case bool(Bool)

	var isEmpty: Bool { if case .empty = self { return true }; return false }
}

/// xlsx 읽기: 시트 목록, 공유 문자열, 날짜 서식, 시트의 행
final class XLSXReader: @unchecked Sendable {
	struct Sheet { var name: String; var path: String }

	let sheets: [Sheet]
	private let zip: ZipReader
	private var shared: [String] = []
	/// 스타일 번호 → 날짜 서식인지
	private var dateStyles: Set<Int> = []

	init(url: URL) throws {
		zip = try ZipReader(url: url)
		guard zip.has("xl/workbook.xml") else { throw ZipReader.ZipError.missing("xl/workbook.xml") }
		// 시트 이름 ↔ r:id ↔ 파일
		let wb = try zip.read("xl/workbook.xml")
		let rels = (try? zip.read("xl/_rels/workbook.xml.rels")) ?? Data()
		let targets = XMLScan.attributes(in: rels, element: "Relationship").reduce(into: [String: String]()) { d, a in
			if let id = a["Id"], let t = a["Target"] { d[id] = t }
		}
		var list: [Sheet] = []
		for a in XMLScan.attributes(in: wb, element: "sheet") {
			guard let name = a["name"] else { continue }
			let rid = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value ?? ""
			var target = targets[rid] ?? "worksheets/sheet\(list.count + 1).xml"
			if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
			list.append(Sheet(name: name, path: target))
		}
		sheets = list
		if zip.has("xl/sharedStrings.xml") { shared = SharedStrings.parse(try zip.read("xl/sharedStrings.xml")) }
		if zip.has("xl/styles.xml") { dateStyles = Styles.dateStyles(try zip.read("xl/styles.xml")) }
	}

	/// 시트의 모든 행 (빈 칸은 .empty 로 채워 열 위치를 맞춘다). maxRows 면 거기까지만
	func rows(of sheet: Sheet, maxRows: Int? = nil) throws -> [[XLSXValue]] {
		let data = try zip.read(sheet.path)
		let p = SheetParser(shared: shared, dateStyles: dateStyles, maxRows: maxRows)
		let parser = XMLParser(data: data)
		parser.delegate = p
		parser.parse()
		return p.rows
	}

	/// A → 0, AA → 26
	static func columnIndex(_ ref: String) -> Int {
		var n = 0
		for u in ref.unicodeScalars {
			guard u.value >= 65 && u.value <= 90 else { break }
			n = n * 26 + Int(u.value - 64)
		}
		return max(0, n - 1)
	}

	/// 엑셀 일련번호 → "YYYY-MM-DD" 또는 "YYYY-MM-DD HH:MM:SS"
	static func dateString(_ serial: Double) -> String {
		var days = Int(serial.rounded(.down))
		var secs = Int(((serial - Double(days)) * 86400).rounded())
		if secs >= 86400 { days += 1; secs -= 86400 }
		// 1899-12-30 + days
		let z = days - 25569 + 719468   // 1970-01-01 기준으로 옮긴 뒤 Hinnant
		let era = (z >= 0 ? z : z - 146096) / 146097
		let doe = z - era * 146097
		let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
		var y = yoe + era * 400
		let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
		let mp = (5 * doy + 2) / 153
		let d = doy - (153 * mp + 2) / 5 + 1
		let m = mp < 10 ? mp + 3 : mp - 9
		if m <= 2 { y += 1 }
		let date = String(format: "%04d-%02d-%02d", y, m, d)
		if secs == 0 { return date }
		return date + String(format: " %02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
	}
}

/// 작은 XML 에서 요소 속성만 뽑기 (workbook·rels)
enum XMLScan {
	final class Collector: NSObject, XMLParserDelegate {
		let element: String
		var found: [[String: String]] = []
		init(_ e: String) { element = e }
		func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
			if name == element || name.hasSuffix(":" + element) { found.append(a) }
		}
	}

	static func attributes(in data: Data, element: String) -> [[String: String]] {
		let c = Collector(element)
		let p = XMLParser(data: data)
		p.delegate = c
		p.parse()
		return c.found
	}
}

/// sharedStrings.xml: <si> 마다 글자 (<t> 여러 개면 이어 붙임, 발음 <rPh> 는 뺀다)
enum SharedStrings {
	final class P: NSObject, XMLParserDelegate {
		var list: [String] = []
		var cur = ""
		var inT = false, inPh = false
		func parser(_ parser: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
			switch n {
			case "si": cur = ""
			case "t": inT = true
			case "rPh": inPh = true
			default: break
			}
		}
		func parser(_ parser: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
			switch n {
			case "si": list.append(cur)
			case "t": inT = false
			case "rPh": inPh = false
			default: break
			}
		}
		func parser(_ parser: XMLParser, foundCharacters s: String) { if inT && !inPh { cur += s } }
	}

	static func parse(_ d: Data) -> [String] {
		let p = P()
		let x = XMLParser(data: d)
		x.delegate = p
		x.parse()
		return p.list
	}
}

/// styles.xml: cellXfs 의 몇 번째가 날짜 서식인지 (기본 14~22·45~47, 직접 만든 서식은 y·d·h·s 가 있으면)
enum Styles {
	final class P: NSObject, XMLParserDelegate {
		var custom: [Int: String] = [:]
		var xfs: [Int] = []
		var inCellXfs = false
		func parser(_ parser: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
			if n == "numFmt", let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { custom[id] = code }
			if n == "cellXfs" { inCellXfs = true }
			if n == "xf", inCellXfs { xfs.append(a["numFmtId"].flatMap(Int.init) ?? 0) }
		}
		func parser(_ parser: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
			if n == "cellXfs" { inCellXfs = false }
		}
	}

	static func isDateFormat(_ code: String) -> Bool {
		// 따옴표 안 글자·[색] 은 빼고 본다
		var s = "", inQuote = false, inBracket = false
		for ch in code {
			if ch == "\"" { inQuote.toggle(); continue }
			if ch == "[" { inBracket = true; continue }
			if ch == "]" { inBracket = false; continue }
			if !inQuote && !inBracket { s.append(ch) }
		}
		let l = s.lowercased()
		return l.contains("y") || l.contains("d") || l.contains("h") || (l.contains("m") && l.contains("s"))
	}

	static func dateStyles(_ d: Data) -> Set<Int> {
		let p = P()
		let x = XMLParser(data: d)
		x.delegate = p
		x.parse()
		var out = Set<Int>()
		for (i, f) in p.xfs.enumerated() {
			if (14...22).contains(f) || (45...47).contains(f) || p.custom[f].map(isDateFormat) == true { out.insert(i) }
		}
		return out
	}
}

/// 시트 XML: <row><c r="B3" t="s" s="2"><v>…</v> | <is><t>…</t></is></c></row>
final class SheetParser: NSObject, XMLParserDelegate {
	private let shared: [String]
	private let dateStyles: Set<Int>
	private let maxRows: Int?
	private(set) var rows: [[XLSXValue]] = []

	private var row: [XLSXValue] = []
	private var rowIndex = 0
	private var col = 0
	private var type = ""
	private var style = 0
	private var text = ""
	private var inV = false, inT = false, inIs = false, inRow = false

	init(shared: [String], dateStyles: Set<Int>, maxRows: Int?) {
		self.shared = shared
		self.dateStyles = dateStyles
		self.maxRows = maxRows
	}

	func parser(_ parser: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
		switch n {
		case "row":
			inRow = true
			row = []
			// 빈 행도 자리를 맞춘다 (r 은 1부터)
			if let r = a["r"].flatMap(Int.init) {
				while rows.count + 1 < r, maxRows.map({ rows.count < $0 }) ?? true { rows.append([]) }
			}
			col = 0
		case "c":
			if let r = a["r"] { col = XLSXReader.columnIndex(r) }
			type = a["t"] ?? "n"
			style = a["s"].flatMap(Int.init) ?? 0
			text = ""
		case "v": inV = true
		case "is": inIs = true
		case "t": if inIs { inT = true }
		default: break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters s: String) {
		if inV || inT { text += s }
	}

	func parser(_ parser: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
		switch n {
		case "v": inV = false
		case "t": inT = false
		case "is": inIs = false
		case "c":
			let v: XLSXValue
			switch type {
			case "s": v = Int(text).flatMap { shared.indices.contains($0) ? .text(shared[$0]) : nil } ?? .empty
			case "inlineStr", "str": v = .text(text)
			case "b": v = .bool(text == "1")
			case "e": v = .empty
			default:
				if text.isEmpty { v = .empty }
				else if dateStyles.contains(style), let d = Double(text) { v = .date(d) }
				else { v = .number(text) }
			}
			while row.count < col { row.append(.empty) }
			if row.count == col { row.append(v) } else if col < row.count { row[col] = v }
			col += 1
		case "row":
			inRow = false
			rows.append(row)
			if let m = maxRows, rows.count >= m { parser.abortParsing() }
		default: break
		}
	}
}
