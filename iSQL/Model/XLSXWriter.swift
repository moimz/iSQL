import Foundation
import Compression

/// zip 파일 쓰기 (deflate, 외부 라이브러리 없이 맥의 Compression 으로).
/// 항목 하나씩 차례로 흘려 쓴다: 로컬 머리 → 압축 데이터 → 데이터 서술자(CRC·크기는 뒤에) → 마지막에 중앙 디렉터리.
/// 그래서 큰 시트도 메모리에 다 올리지 않는다. (4GB 넘는 zip64 는 지원하지 않는다)
final class ZipWriter {
	private struct Entry { var name: [UInt8]; var crc: UInt32; var csize: UInt32; var usize: UInt32; var offset: UInt32 }

	private let fh: FileHandle
	private var out = Data()
	private var offset: UInt64 = 0
	private var entries: [Entry] = []

	// 지금 쓰는 항목
	private var current: (name: [UInt8], offset: UInt32)?
	private var crc: UInt32 = 0
	private var usize: UInt64 = 0
	private var csize: UInt64 = 0
	private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
	private let dstSize = 1 << 16
	private let dst: UnsafeMutablePointer<UInt8>
	private let dosTime: UInt16
	private let dosDate: UInt16

	enum ZipError: LocalizedError {
		case create(String), compress, tooLarge
		var errorDescription: String? {
			switch self {
			case .create(let p): return "파일을 만들지 못했습니다: \(p)"
			case .compress: return "압축하지 못했습니다"
			case .tooLarge: return "파일이 4GB 를 넘습니다"
			}
		}
	}

	init(url: URL) throws {
		guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
			throw ZipError.create(url.path)
		}
		fh = h
		dst = .allocate(capacity: dstSize)
		let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
		dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
		dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
	}

	deinit {
		stream.deallocate()
		dst.deallocate()
		try? fh.close()
	}

	// MARK: 바이트 쓰기 (1MB 씩 모아서)

	private func emit(_ d: Data) {
		out.append(d)
		offset += UInt64(d.count)
		if out.count >= 1 << 20 { fh.write(out); out.removeAll(keepingCapacity: true) }
	}
	private func emit(_ p: UnsafePointer<UInt8>, _ n: Int) { emit(Data(bytes: p, count: n)) }
	private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
	private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

	// MARK: 항목

	func begin(_ name: String) throws {
		guard offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
		let n = Array(name.utf8)
		current = (n, UInt32(offset))
		crc = 0; usize = 0; csize = 0
		var h = Data()
		h += le32(0x04034B50); h += le16(20)
		h += le16(0x0808)          // 비트 3: 크기·CRC 는 데이터 서술자에, 비트 11: 이름 UTF-8
		h += le16(8)               // deflate
		h += le16(dosTime); h += le16(dosDate)
		h += le32(0); h += le32(0); h += le32(0)
		h += le16(UInt16(n.count)); h += le16(0)
		h += Data(n)
		emit(h)
		guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.compress }
	}

	func write(_ data: Data) throws {
		guard !data.isEmpty else { return }
		crc = CRC32.update(crc, data)
		usize += UInt64(data.count)
		try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
			try pump(base, data.count, finalize: false)
		}
	}

	func write(_ s: String) throws { try write(Data(s.utf8)) }

	private func pump(_ src: UnsafePointer<UInt8>?, _ n: Int, finalize: Bool) throws {
		stream.pointee.src_ptr = src ?? UnsafePointer(dst)
		stream.pointee.src_size = n
		while true {
			stream.pointee.dst_ptr = dst
			stream.pointee.dst_size = dstSize
			let status = compression_stream_process(stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
			guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.compress }
			let produced = dstSize - stream.pointee.dst_size
			if produced > 0 { emit(dst, produced); csize += UInt64(produced) }
			if finalize {
				if status == COMPRESSION_STATUS_END { return }
			} else if stream.pointee.src_size == 0 && stream.pointee.dst_size > 0 {
				return
			}
		}
	}

	func end() throws {
		guard let c = current else { return }
		try pump(nil, 0, finalize: true)
		compression_stream_destroy(stream)
		guard usize < UInt64(UInt32.max), csize < UInt64(UInt32.max) else { throw ZipError.tooLarge }
		var d = Data()
		d += le32(0x08074B50); d += le32(crc); d += le32(UInt32(csize)); d += le32(UInt32(usize))
		emit(d)
		entries.append(Entry(name: c.name, crc: crc, csize: UInt32(csize), usize: UInt32(usize), offset: c.offset))
		current = nil
	}

	/// 작은 항목 하나를 통째로
	func add(_ name: String, _ text: String) throws {
		try begin(name)
		try write(text)
		try end()
	}

	/// 중앙 디렉터리를 쓰고 닫는다
	func close() throws {
		guard offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
		let start = UInt32(offset)
		for e in entries {
			var h = Data()
			h += le32(0x02014B50); h += le16(20); h += le16(20)
			h += le16(0x0808); h += le16(8)
			h += le16(dosTime); h += le16(dosDate)
			h += le32(e.crc); h += le32(e.csize); h += le32(e.usize)
			h += le16(UInt16(e.name.count)); h += le16(0); h += le16(0)
			h += le16(0); h += le16(0); h += le32(0)
			h += le32(e.offset)
			h += Data(e.name)
			emit(h)
		}
		let size = UInt32(offset) - start
		var t = Data()
		t += le32(0x06054B50); t += le16(0); t += le16(0)
		t += le16(UInt16(entries.count)); t += le16(UInt16(entries.count))
		t += le32(size); t += le32(start); t += le16(0)
		emit(t)
		fh.write(out)
		out.removeAll()
		try fh.close()
	}
}

enum CRC32 {
	private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
		var c = UInt32(i)
		for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
		return c
	}

	static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
		var c = ~crc
		data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
			table.withUnsafeBufferPointer { t in
				for b in p { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
			}
		}
		return ~c
	}
}

/// 엑셀 칸 하나
enum XLSXCell {
	case empty
	case text(String)
	/// 숫자 (글자 그대로 <v> 에)
	case number(String)
	/// 엑셀 날짜 일련번호 (1899-12-30 부터 날 수)
	case date(Double)
	case dateTime(Double)
}

/// xlsx 쓰기: 시트마다 행을 흘려 쓰고, 끝에 통합 문서·스타일을 쓴다.
/// 글자는 inline string 으로 넣는다 (공유 문자열 표를 만들려면 모든 글자를 메모리에 모아야 해서).
final class XLSXWriter {
	/// 엑셀 시트 한 장의 최대 행 수
	static let maxRows = 1_048_576
	/// 칸 하나의 최대 글자 수
	static let maxCellChars = 32_767

	private let zip: ZipWriter
	private var sheets: [String] = []
	private var rowIndex = 0
	private var buffer = ""
	private var columnRefs: [String] = []

	init(url: URL) throws { zip = try ZipWriter(url: url) }

	/// 지금 시트에 쓴 행 수
	var rowsInSheet: Int { rowIndex }

	/// 시트 시작. widths 는 컬럼 너비(글자 수), freezeHeader 면 첫 행 고정
	func beginSheet(_ name: String, widths: [Double], freezeHeader: Bool) throws {
		sheets.append(uniqueSheetName(name))
		rowIndex = 0
		columnRefs = (0..<max(widths.count, 1)).map(Self.columnName)
		try zip.begin("xl/worksheets/sheet\(sheets.count).xml")
		var h = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
		h += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
		if freezeHeader {
			h += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
		}
		if !widths.isEmpty {
			h += "<cols>"
			for (i, w) in widths.enumerated() { h += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(String(format: "%.1f", w))" customWidth="1"/>"# }
			h += "</cols>"
		}
		h += "<sheetData>"
		try zip.write(h)
	}

	/// 행 하나 (header 면 굵게)
	func row(_ cells: [XLSXCell], header: Bool = false) throws {
		rowIndex += 1
		let r = String(rowIndex)
		buffer += "<row r=\"\(r)\">"
		for (i, c) in cells.enumerated() {
			let ref = (i < columnRefs.count ? columnRefs[i] : Self.columnName(i)) + r
			switch c {
			case .empty: continue
			case .text(let s):
				let t = Self.escape(s)
				let space = s.first.map { $0.isWhitespace } == true || s.last.map { $0.isWhitespace } == true || s.contains("\n")
				buffer += "<c r=\"\(ref)\" t=\"inlineStr\"\(header ? " s=\"1\"" : "")><is><t\(space ? " xml:space=\"preserve\"" : "")>\(t)</t></is></c>"
			case .number(let v):
				buffer += "<c r=\"\(ref)\"><v>\(v)</v></c>"
			case .date(let d):
				buffer += "<c r=\"\(ref)\" s=\"2\"><v>\(Self.serial(d))</v></c>"
			case .dateTime(let d):
				buffer += "<c r=\"\(ref)\" s=\"3\"><v>\(Self.serial(d))</v></c>"
			}
		}
		buffer += "</row>"
		if buffer.utf8.count > 1 << 18 { try flush() }
	}

	private func flush() throws {
		try zip.write(buffer)
		buffer.removeAll(keepingCapacity: true)
	}

	func endSheet() throws {
		try flush()
		try zip.write("</sheetData></worksheet>")
		try zip.end()
	}

	/// 통합 문서·관계·스타일을 쓰고 닫는다
	func close() throws {
		if sheets.isEmpty {
			try beginSheet("Sheet1", widths: [], freezeHeader: false)
			try endSheet()
		}
		let ns = "http://schemas.openxmlformats.org"
		var types = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
		types += #"<Types xmlns="\#(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
		types += #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
		types += #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
		for i in sheets.indices {
			types += #"<Override PartName="/xl/worksheets/sheet\#(i + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
		}
		types += "</Types>"
		try zip.add("[Content_Types].xml", types)
		try zip.add("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n" +
			#"<Relationships xmlns="\#(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\#(ns)/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
		var wb = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
		wb += #"<workbook xmlns="\#(ns)/spreadsheetml/2006/main" xmlns:r="\#(ns)/officeDocument/2006/relationships"><sheets>"#
		for (i, n) in sheets.enumerated() { wb += #"<sheet name="\#(Self.escape(n))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"# }
		wb += "</sheets></workbook>"
		try zip.add("xl/workbook.xml", wb)
		var rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n" + #"<Relationships xmlns="\#(ns)/package/2006/relationships">"#
		for i in sheets.indices {
			rels += #"<Relationship Id="rId\#(i + 1)" Type="\#(ns)/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i + 1).xml"/>"#
		}
		rels += #"<Relationship Id="rId\#(sheets.count + 1)" Type="\#(ns)/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
		try zip.add("xl/_rels/workbook.xml.rels", rels)
		// 스타일: 0 기본, 1 머리(굵게), 2 날짜, 3 날짜·시각
		let styles = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n" + #"""
			<styleSheet xmlns="\#(ns)/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
			"""#
		try zip.add("xl/styles.xml", styles)
		try zip.close()
	}

	// MARK: 도우미

	/// 0 → A, 25 → Z, 26 → AA
	static func columnName(_ i: Int) -> String {
		var n = i + 1, s = ""
		while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
		return s
	}

	/// XML 에 쓸 수 없는 제어 문자는 빼고, & < > " 는 바꾼다. 칸 최대 글자 수로 자른다
	static func escape(_ s: String) -> String {
		var out = ""
		out.reserveCapacity(s.utf8.count)
		var count = 0
		for u in s.unicodeScalars {
			count += 1
			if count > maxCellChars { break }
			switch u {
			case "&": out += "&amp;"
			case "<": out += "&lt;"
			case ">": out += "&gt;"
			case "\"": out += "&quot;"
			case "\t", "\n", "\r": out.unicodeScalars.append(u)
			default:
				let v = u.value
				if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
				out.unicodeScalars.append(u)
			}
		}
		return out
	}

	/// 일련번호를 짧게 (정수면 소수점 없이)
	private static func serial(_ d: Double) -> String {
		// 시각(초·밀리초)이 반올림되지 않게 줄이지 않는다 (Swift 의 가장 짧은 정확한 표기)
		d == d.rounded() ? String(Int(d)) : String(d)
	}

	/// 시트 이름: [ ] : * ? / \ 는 _, 31자, 겹치면 " (2)"
	private func uniqueSheetName(_ raw: String) -> String {
		var base = String(raw.map { "[]:*?/\\".contains($0) ? "_" : $0 })
			.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
		if base.isEmpty { base = "Sheet" }
		let taken = Set(sheets.map { $0.lowercased() })
		var name = String(base.prefix(31)), i = 2
		while taken.contains(name.lowercased()) {
			let suffix = " (\(i))"
			name = String(base.prefix(31 - suffix.count)) + suffix
			i += 1
		}
		return name
	}

	// MARK: MySQL 값 → 엑셀 날짜

	/// "YYYY-MM-DD[ HH:MM:SS[.ffffff]]" → 일련번호. 1900-03-01 전·0000-00-00 은 nil (글자로 쓴다)
	static func excelSerial(_ s: String) -> Double? {
		let b = Array(s.utf8)
		guard b.count >= 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
		func num(_ r: Range<Int>) -> Int? {
			var v = 0
			for i in r { guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }; v = v * 10 + Int(b[i] - 0x30) }
			return v
		}
		guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10), (1...12).contains(m), (1...31).contains(d) else { return nil }
		guard y > 1900 || (y == 1900 && m >= 3), y <= 9999 else { return nil }
		var serial = Double(daysFromCivil(y, m, d) - daysFromCivil(1899, 12, 30))
		if b.count >= 19, b[10] == 0x20 || b[10] == 0x54, let hh = num(11..<13), let mm = num(14..<16), let ss = num(17..<19) {
			var secs = Double(hh * 3600 + mm * 60 + ss)
			if b.count > 20, b[19] == 0x2E, let frac = Double("0." + String(decoding: b[20...], as: UTF8.self)) { secs += frac }
			serial += secs / 86400
		}
		return serial
	}

	/// 그레고리력 날짜 → 1970-01-01 부터 날 수 (Howard Hinnant)
	private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
		let y = m <= 2 ? y0 - 1 : y0
		let era = (y >= 0 ? y : y - 399) / 400
		let yoe = y - era * 400
		let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
		let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
		return era * 146097 + doe - 719468
	}
}
