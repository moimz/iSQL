import Foundation

/// SQL Server 의 TDS(Tabular Data Stream) 7.4 — 마이크로소프트 공개 규격 [MS-TDS] 대로 직접 구현한다 (외부 라이브러리 없음, 2026-11-20).
/// 패킷 머리 8바이트(종류·상태·길이 BE·SPID·번호·창) 뒤에 내용. 내용 안의 숫자는 리틀 엔디언 (PRELOGIN 만 빅 엔디언)
enum TDS {
	// 패킷 종류
	static let packetSQLBatch: UInt8 = 0x01
	static let packetRPC: UInt8 = 0x03
	static let packetReply: UInt8 = 0x04
	static let packetAttention: UInt8 = 0x06
	static let packetLogin7: UInt8 = 0x10
	static let packetPrelogin: UInt8 = 0x12
	/// 상태: 메시지의 마지막 패킷
	static let statusEOM: UInt8 = 0x01

	/// TDS 7.4 (SQL Server 2012 이상)
	static let version74: UInt32 = 0x7400_0004

	// PRELOGIN 항목
	static let preVersion: UInt8 = 0x00
	static let preEncryption: UInt8 = 0x01
	static let preInstOpt: UInt8 = 0x02
	static let preThreadID: UInt8 = 0x03
	static let preMARS: UInt8 = 0x04
	static let preTerminator: UInt8 = 0xFF
	// 암호화 값
	static let encryptOff: UInt8 = 0x00
	static let encryptOn: UInt8 = 0x01
	static let encryptNotSup: UInt8 = 0x02
	static let encryptReq: UInt8 = 0x03

	// 응답 토큰
	static let tokenColMetadata: UInt8 = 0x81
	static let tokenRow: UInt8 = 0xD1
	static let tokenNBCRow: UInt8 = 0xD2
	static let tokenDone: UInt8 = 0xFD
	static let tokenDoneProc: UInt8 = 0xFE
	static let tokenDoneInProc: UInt8 = 0xFF
	static let tokenError: UInt8 = 0xAA
	static let tokenInfo: UInt8 = 0xAB
	static let tokenLoginAck: UInt8 = 0xAD
	static let tokenEnvChange: UInt8 = 0xE3
	static let tokenOrder: UInt8 = 0xA9
	static let tokenReturnStatus: UInt8 = 0x79
	static let tokenReturnValue: UInt8 = 0xAC
	static let tokenTabName: UInt8 = 0xA4
	static let tokenColInfo: UInt8 = 0xA5
	static let tokenFeatureExtAck: UInt8 = 0xAE
	static let tokenSessionState: UInt8 = 0xE4
	static let tokenSSPI: UInt8 = 0xED
	static let tokenFedAuthInfo: UInt8 = 0xEE

	// DONE 상태
	static let doneMore: UInt16 = 0x01
	static let doneError: UInt16 = 0x02
	static let doneCount: UInt16 = 0x10
	static let doneAttn: UInt16 = 0x20

	// 데이터 형식 (TYPE_INFO 의 첫 바이트)
	static let typeNull: UInt8 = 0x1F
	static let typeInt1: UInt8 = 0x30, typeBit: UInt8 = 0x32, typeInt2: UInt8 = 0x34, typeInt4: UInt8 = 0x38, typeInt8: UInt8 = 0x7F
	static let typeDateTim4: UInt8 = 0x3A, typeFlt4: UInt8 = 0x3B, typeMoney: UInt8 = 0x3C, typeDateTime: UInt8 = 0x3D
	static let typeFlt8: UInt8 = 0x3E, typeMoney4: UInt8 = 0x7A
	static let typeGUID: UInt8 = 0x24, typeIntN: UInt8 = 0x26, typeBitN: UInt8 = 0x68, typeFltN: UInt8 = 0x6D
	static let typeMoneyN: UInt8 = 0x6E, typeDateTimN: UInt8 = 0x6F
	static let typeDecimal: UInt8 = 0x37, typeNumeric: UInt8 = 0x3F, typeDecimalN: UInt8 = 0x6A, typeNumericN: UInt8 = 0x6C
	static let typeDateN: UInt8 = 0x28, typeTimeN: UInt8 = 0x29, typeDateTime2N: UInt8 = 0x2A, typeDateTimeOffsetN: UInt8 = 0x2B
	static let typeBigVarChar: UInt8 = 0xA7, typeBigChar: UInt8 = 0xAF, typeNVarChar: UInt8 = 0xE7, typeNChar: UInt8 = 0xEF
	static let typeBigVarBin: UInt8 = 0xA5, typeBigBinary: UInt8 = 0xAD
	static let typeText: UInt8 = 0x23, typeNText: UInt8 = 0x63, typeImage: UInt8 = 0x22
	static let typeXML: UInt8 = 0xF1, typeUDT: UInt8 = 0xF0, typeVariant: UInt8 = 0x62
	// 옛 형식 (요즘 서버는 보내지 않지만 읽을 수는 있게)
	static let typeVarChar: UInt8 = 0x27, typeChar: UInt8 = 0x2F, typeVarBinary: UInt8 = 0x25, typeBinary: UInt8 = 0x2D

	/// LOGIN7 비밀번호: 바이트마다 앞뒤 4비트를 바꾸고 0xA5 와 XOR (규격의 가리기, 암호화가 아니다 — 그래서 TLS 안으로 보낸다)
	static func scramble(_ password: String) -> [UInt8] {
		utf16le(password).map { b in ((b << 4) | (b >> 4)) ^ 0xA5 }
	}

	static func utf16le(_ s: String) -> [UInt8] {
		var out: [UInt8] = []
		out.reserveCapacity(s.utf16.count * 2)
		for u in s.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
		return out
	}

	static func string(utf16le b: ArraySlice<UInt8>) -> String {
		var units: [UInt16] = []
		units.reserveCapacity(b.count / 2)
		var i = b.startIndex
		while i + 1 < b.endIndex { units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8); i += 2 }
		return String(decoding: units, as: UTF16.self)
	}
}

/// 리틀 엔디언으로 읽기 (넘치면 TDSError.protocolError)
struct TDSReader {
	let b: [UInt8]
	var i: Int
	init(_ b: [UInt8], at i: Int = 0) { self.b = b; self.i = i }

	var atEnd: Bool { i >= b.count }
	var remaining: Int { b.count - i }

	mutating func need(_ n: Int) throws {
		if n < 0 || i + n > b.count { throw TDSError.protocolError("응답이 예상보다 짧습니다 (\(i)+\(n) > \(b.count)).") }
	}
	mutating func u8() throws -> UInt8 { try need(1); defer { i += 1 }; return b[i] }
	mutating func u16() throws -> UInt16 { try need(2); defer { i += 2 }; return UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
	mutating func u32() throws -> UInt32 {
		try need(4); defer { i += 4 }
		return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
	}
	mutating func u64() throws -> UInt64 { let lo = UInt64(try u32()); return lo | UInt64(try u32()) << 32 }
	mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> { try need(n); defer { i += n }; return b[i..<(i + n)] }
	mutating func skip(_ n: Int) throws { try need(n); i += n }
	/// 1바이트 글자 수 + UTF-16
	mutating func bVarChar() throws -> String { let n = Int(try u8()); return TDS.string(utf16le: try bytes(n * 2)) }
	/// 2바이트 글자 수 + UTF-16
	mutating func usVarChar() throws -> String { let n = Int(try u16()); return TDS.string(utf16le: try bytes(n * 2)) }
	/// 1바이트 길이 + 바이트
	mutating func bVarByte() throws -> ArraySlice<UInt8> { let n = Int(try u8()); return try bytes(n) }
}

enum TDSError: LocalizedError {
	/// 서버가 보낸 오류 (번호, 상태, 심각도, 글, 줄)
	case server(number: Int, state: Int, severity: Int, message: String, line: Int, procedure: String)
	case protocolError(String)
	case io(String)
	/// 쿼리 취소 (ATTENTION 확인을 받음)
	case cancelled
	case closed

	var errorDescription: String? {
		switch self {
		case .server(let n, _, _, let m, let line, let proc):
			"\(m) (오류 \(n)" + (proc.isEmpty ? "" : ", \(proc)") + (line > 0 ? ", \(line)번째 줄" : "") + ")"
		case .protocolError(let s), .io(let s): s
		case .cancelled: "쿼리를 취소했습니다."
		case .closed: "서버와 연결이 끊어졌습니다."
		}
	}
}

/// 결과 컬럼 하나의 형식 정보 (COLMETADATA)
struct TDSColumn {
	var name = ""
	var type: UInt8 = 0
	var userType: UInt32 = 0
	var flags: UInt16 = 0
	/// 형식 안의 최대 길이 (바이트), PLP(…(max)·xml·udt) 면 0xFFFF
	var maxLength: Int = 0
	var precision: UInt8 = 0
	var scale: UInt8 = 0
	/// 글자(비 유니코드)의 콜레이션 5바이트
	var collation: [UInt8] = []
	var udtName = ""

	var nullable: Bool { flags & 0x01 != 0 }
	var isIdentity: Bool { flags & 0x10 != 0 }
	/// 8바이트 전체 길이 + 조각들로 오는 형식
	var isPLP: Bool {
		switch type {
		case TDS.typeXML, TDS.typeUDT: true
		case TDS.typeBigVarChar, TDS.typeNVarChar, TDS.typeBigVarBin: maxLength == 0xFFFF
		default: false
		}
	}

	/// 화면이 쓰는 Column (type·charset 은 아직 MySQL 번호: 숫자 · 긴 글자 · 바이트를 가린다)
	var column: Column {
		let (my, cs): (UInt8, UInt16) = switch type {
		case TDS.typeInt1: (1, 63)
		case TDS.typeBit, TDS.typeBitN: (1, 63)
		case TDS.typeInt2: (2, 63)
		case TDS.typeInt4: (3, 63)
		case TDS.typeInt8: (8, 63)
		case TDS.typeIntN: (maxLength == 8 ? 8 : maxLength == 2 ? 2 : maxLength == 1 ? 1 : 3, 63)
		case TDS.typeFlt4: (4, 63)
		case TDS.typeFlt8: (5, 63)
		case TDS.typeFltN: (maxLength == 4 ? 4 : 5, 63)
		case TDS.typeMoney, TDS.typeMoney4, TDS.typeMoneyN, TDS.typeDecimal, TDS.typeNumeric, TDS.typeDecimalN, TDS.typeNumericN: (246, 63)
		case TDS.typeDateN: (10, 63)
		case TDS.typeTimeN: (11, 63)
		case TDS.typeDateTime, TDS.typeDateTim4, TDS.typeDateTimN, TDS.typeDateTime2N, TDS.typeDateTimeOffsetN: (12, 63)
		case TDS.typeBigVarBin, TDS.typeBigBinary, TDS.typeVarBinary, TDS.typeBinary: (isPLP ? 252 : 253, 63)
		case TDS.typeImage, TDS.typeUDT: (252, 63)
		case TDS.typeText, TDS.typeNText, TDS.typeXML: (252, 33)
		case TDS.typeBigVarChar, TDS.typeNVarChar, TDS.typeVarChar: (isPLP ? 252 : 253, 33)
		case TDS.typeBigChar, TDS.typeNChar, TDS.typeChar: (254, 33)
		default: (253, 33)   // GUID · sql_variant
		}
		var f: UInt16 = nullable ? 0 : 1
		if isIdentity { f |= 0x200 }   // MySQL AUTO_INCREMENT 비트
		return Column(name: name, orgName: name, table: "", orgTable: "", schema: "", charset: cs,
		              length: UInt32(clamping: maxLength), type: my, flags: f, decimals: scale)
	}
}

// MARK: - 값 풀기

enum TDSValues {
	/// 비 유니코드 글자의 인코딩: 콜레이션의 UTF8 표시 → UTF-8, 아니면 LCID 로 코드 페이지 (한국어 949 …), 모르면 1252
	static func encoding(_ collation: [UInt8]) -> String.Encoding {
		guard collation.count == 5 else { return .windowsCP1252 }
		if collation[3] & 0x04 != 0 { return .utf8 }
		let lcid = Int(collation[0]) | Int(collation[1]) << 8 | Int(collation[2] & 0x0F) << 16
		let cf: CFStringEncodings? = switch lcid & 0xFFFF {
		case 0x0412: .dosKorean                                    // 949
		case 0x0411: .dosJapanese                                  // 932
		case 0x0804, 0x1004: .dosChineseSimplif                    // 936
		case 0x0404, 0x0C04, 0x1404: .dosChineseTrad               // 950
		case 0x0419, 0x0422, 0x0423, 0x0402, 0x042F, 0x0C1A: .windowsCyrillic
		case 0x0408: .windowsGreek
		case 0x041F: .windowsLatin5
		case 0x040D: .windowsHebrew
		case 0x0401: .windowsArabic
		case 0x041E: .dosThai
		case 0x042A: .windowsVietnamese
		case 0x0405, 0x040E, 0x0415, 0x0418, 0x041B, 0x0424, 0x041A: .windowsLatin2
		default: nil
		}
		guard let cf else { return .windowsCP1252 }
		return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
	}

	static func text(_ b: ArraySlice<UInt8>, _ collation: [UInt8]) -> String {
		let d = Data(b)
		return String(data: d, encoding: encoding(collation)) ?? String(decoding: d, as: UTF8.self)
	}

	static func int(_ b: ArraySlice<UInt8>) -> Int64 {
		var v: UInt64 = 0
		for (k, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(k)) }
		// 부호 늘리기
		let bits = b.count * 8
		if bits < 64, v & (1 << UInt64(bits - 1)) != 0 { v |= ~0 << UInt64(bits) }
		return Int64(bitPattern: v)
	}

	static func uint(_ b: ArraySlice<UInt8>) -> UInt64 {
		var v: UInt64 = 0
		for (k, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(k)) }
		return v
	}

	/// 정수 글자 → 소수점 scale 자리 글자 ("12345", 2 → "123.45")
	static func withScale(_ digits: String, negative: Bool, scale: Int) -> String {
		var d = digits
		if scale > 0 {
			if d.count <= scale { d = String(repeating: "0", count: scale - d.count + 1) + d }
			d.insert(".", at: d.index(d.endIndex, offsetBy: -scale))
		}
		return (negative && d.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + d
	}

	/// 리틀 엔디언 크기(최대 16바이트) → 10진 글자
	static func decimalDigits(_ mag: ArraySlice<UInt8>) -> String {
		var words = Array(mag.reversed())   // 빅 엔디언
		var out: [Character] = []
		while words.contains(where: { $0 != 0 }) {
			var rem = 0
			for k in words.indices {
				let cur = rem * 256 + Int(words[k])
				words[k] = UInt8(cur / 10)
				rem = cur % 10
			}
			out.append(Character(String(rem)))
		}
		return out.isEmpty ? "0" : String(out.reversed())
	}

	/// MONEY: 8바이트 = 위 4바이트 + 아래 4바이트, 1/10000
	static func money(_ b: ArraySlice<UInt8>) -> String {
		let raw: Int64
		if b.count == 8 {
			let hi = UInt64(uint(b.prefix(4))), lo = UInt64(uint(b.suffix(4)))
			raw = Int64(bitPattern: hi << 32 | lo)
		} else {
			raw = int(b)
		}
		let neg = raw < 0
		return withScale(String(raw.magnitude), negative: neg, scale: 4)
	}

	// 날짜: 0001-01-01 부터 날 수 (date·datetime2·datetimeoffset), 1900-01-01 부터 (datetime·smalldatetime)
	private static let julian1: Int = 1_721_426   // 0001-01-01 의 율리우스일 (그레고리력 연장)
	private static func ymd(daysFrom0001 d: Int) -> (Int, Int, Int) {
		// 율리우스일 → 그레고리력 (Fliegel–Van Flandern)
		let jd = d + julian1
		var l = jd + 68569
		let n = 4 * l / 146097
		l = l - (146097 * n + 3) / 4
		let i = 4000 * (l + 1) / 1461001
		l = l - 1461 * i / 4 + 31
		let j = 80 * l / 2447
		let day = l - 2447 * j / 80
		l = j / 11
		let month = j + 2 - 12 * l
		let year = 100 * (n - 49) + i + l
		return (year, month, day)
	}
	private static let days0001to1900 = 693_595

	static func date(days: Int) -> String {
		let (y, m, d) = ymd(daysFrom0001: days)
		return String(format: "%04d-%02d-%02d", y, m, d)
	}

	/// 하루 안 시각 (10^-scale 초 단위) → "HH:mm:ss[.fffffff]"
	static func time(units: UInt64, scale: Int) -> String {
		var p: UInt64 = 1
		for _ in 0..<scale { p *= 10 }
		let secs = units / p, frac = units % p
		let s = String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
		return scale > 0 ? s + "." + String(format: "%0\(scale)llu", frac) : s
	}

	static func timeBytes(_ scale: Int) -> Int { scale <= 2 ? 3 : scale <= 4 ? 4 : 5 }

	/// DATETIME: 날(1900 부터, 부호 있음) + 1/300 초
	static func dateTime(_ b: ArraySlice<UInt8>) -> String {
		let days = Int(int(b.prefix(4)))
		let ticks = UInt64(uint(b.suffix(4)))
		// 1/300 초 → 밀리초 (반올림, SQL Server 처럼 .000 .003 .007)
		let ms = (ticks * 10 + 1) / 3
		return date(days: days + days0001to1900) + " " + time(units: ms, scale: 3)
	}

	/// SMALLDATETIME: 날(1900 부터, 2바이트) + 분(2바이트)
	static func smallDateTime(_ b: ArraySlice<UInt8>) -> String {
		let days = Int(uint(b.prefix(2))), mins = UInt64(uint(b.suffix(2)))
		return date(days: days + days0001to1900) + " " + time(units: mins * 60, scale: 0)
	}

	/// DATETIMEOFFSET: 시각·날은 UTC 기준 → 지역 시각으로 바꿔 "+09:00" 붙임
	static func dateTimeOffset(_ b: ArraySlice<UInt8>, scale: Int) -> String {
		let tb = timeBytes(scale)
		var units = uint(b.prefix(tb))
		var days = Int(uint(b.dropFirst(tb).prefix(3)))
		let offset = Int(int(b.suffix(2)))
		var p: UInt64 = 1
		for _ in 0..<scale { p *= 10 }
		let dayUnits = 86400 * p
		// UTC + 오프셋(분)
		var signed = Int64(units) + Int64(offset) * 60 * Int64(p)
		while signed < 0 { signed += Int64(dayUnits); days -= 1 }
		while signed >= Int64(dayUnits) { signed -= Int64(dayUnits); days += 1 }
		units = UInt64(signed)
		let sign = offset < 0 ? "-" : "+"
		return date(days: days) + " " + time(units: units, scale: scale) + String(format: " %@%02d:%02d", sign, abs(offset) / 60, abs(offset) % 60)
	}

	/// GUID: 앞 4·2·2 바이트는 리틀 엔디언, 나머지 8바이트는 그대로
	static func guid(_ b: ArraySlice<UInt8>) -> String {
		let a = Array(b)
		guard a.count == 16 else { return "" }
		let order = [3, 2, 1, 0, -1, 5, 4, -1, 7, 6, -1, 8, 9, -1, 10, 11, 12, 13, 14, 15]
		return order.map { $0 < 0 ? "-" : String(format: "%02X", a[$0]) }.joined()
	}

	static func float(_ b: ArraySlice<UInt8>) -> String {
		if b.count == 4 {
			let f = Float(bitPattern: UInt32(uint(b)))
			return f == f.rounded() && abs(f) < 1e15 ? String(format: "%.0f", f) : "\(f)"
		}
		let d = Double(bitPattern: uint(b))
		return d == d.rounded() && abs(d) < 1e15 ? String(format: "%.0f", d) : "\(d)"
	}
}

// MARK: - T-SQL 글 (연결이 GO 배치를 나누고, 쿼리 패널이 문장을 나눈다)

/// T-SQL 글 나누기 도움
enum TSQLScript {
	/// ; 로 나누면 안 되는 글로 시작하는지: CREATE [OR ALTER] / ALTER 프로시저·함수·트리거·뷰, DECLARE (변수는 배치 안에서만 산다)
	static func startsBlock(_ s: String) -> Bool {
		let t = s.replacingOccurrences(of: #"(?s)/\*.*?\*/|--[^\n]*"#, with: " ", options: .regularExpression)
		let words = t.split(whereSeparator: { !($0.isLetter || $0 == "_") }).prefix(4).map { $0.uppercased() }
		guard let first = words.first else { return false }
		if first == "DECLARE" { return true }
		guard first == "CREATE" || first == "ALTER" else { return false }
		let objects: Set<String> = ["PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "VIEW"]
		for w in words.dropFirst() {
			if objects.contains(w) { return true }
			if !["OR", "ALTER"].contains(w) { return false }
		}
		return false
	}

	/// 줄 전체가 GO (뒤에 횟수·공백 허용) 인지: u[i] 가 줄 첫 글자일 때 그 줄 끝 위치, 아니면 nil
	static func goLineEnd(_ u: [UInt16], at i: Int) -> Int? {
		var b = i - 1
		while b >= 0 && (u[b] == 32 || u[b] == 9) { b -= 1 }
		guard b < 0 || u[b] == 10 else { return nil }
		guard i + 1 < u.count, u[i] == 71 || u[i] == 103, u[i + 1] == 79 || u[i + 1] == 111 else { return nil }
		var j = i + 2
		while j < u.count && (u[j] == 32 || u[j] == 9 || u[j] == 13 || (u[j] >= 48 && u[j] <= 57)) { j += 1 }
		return j >= u.count || u[j] == 10 ? j : nil
	}

	/// GO 줄로 배치 나누기 (빈 배치는 뺀다)
	static func batches(_ sql: String) -> [String] {
		let u = Array(sql.utf16)
		var out: [String] = []
		var start = 0, i = 0
		var quote: UInt16 = 0
		func cut(_ end: Int) {
			let t = String(utf16CodeUnits: Array(u[start..<end]), count: end - start).trimmingCharacters(in: .whitespacesAndNewlines)
			if !t.isEmpty { out.append(t) }
		}
		while i < u.count {
			let c = u[i]
			if quote != 0 { if c == quote { quote = 0 }; i += 1; continue }
			switch c {
			case 39: quote = 39
			case 91: quote = 93          // [ … ]
			case 45 where i + 1 < u.count && u[i + 1] == 45:
				while i < u.count && u[i] != 10 { i += 1 }
				continue
			case 47 where i + 1 < u.count && u[i + 1] == 42:
				i += 2
				while i + 1 < u.count && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
				i += 2
				continue
			case 71, 103:
				if let end = goLineEnd(u, at: i) { cut(i); start = end; i = end; continue }
			default: break
			}
			i += 1
		}
		cut(u.count)
		return out
	}
}
