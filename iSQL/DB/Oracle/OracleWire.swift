import Foundation

// Oracle 접속 프로토콜(TNS · TTC)의 바이트 읽기·쓰기와 상수.
// 공개 문서가 없어서 Oracle 이 직접 낸 python-oracledb(thin 모드, UPL/Apache-2.0)와
// 그것을 Swift 로 옮긴 oracle-nio(Apache-2.0)를 보고 옮겼다. 정수는 모두 큰 쪽부터(big endian),
// "UB" 정수는 첫 바이트가 길이(0x80 이면 음수)이고 그 길이만큼 이어지는 가변 길이 정수다.

enum TNS {
	// 패킷 종류
	static let packetConnect: UInt8 = 1
	static let packetAccept: UInt8 = 2
	static let packetRefuse: UInt8 = 4
	static let packetRedirect: UInt8 = 5
	static let packetData: UInt8 = 6
	static let packetResend: UInt8 = 11
	static let packetMarker: UInt8 = 12
	static let packetControl: UInt8 = 14

	static let markerBreak: UInt8 = 1
	static let markerReset: UInt8 = 2

	// 메시지 종류 (데이터 패킷 안)
	static let msgProtocol: UInt8 = 1
	static let msgDataTypes: UInt8 = 2
	static let msgFunction: UInt8 = 3
	static let msgError: UInt8 = 4
	static let msgRowHeader: UInt8 = 6
	static let msgRowData: UInt8 = 7
	static let msgParameter: UInt8 = 8
	static let msgStatus: UInt8 = 9
	static let msgIOVector: UInt8 = 11
	static let msgLOBData: UInt8 = 14
	static let msgWarning: UInt8 = 15
	static let msgDescribeInfo: UInt8 = 16
	static let msgPiggyback: UInt8 = 17
	static let msgFlushOutBinds: UInt8 = 19
	static let msgBitVector: UInt8 = 21
	static let msgServerPiggyback: UInt8 = 23
	static let msgImplicitResultSet: UInt8 = 27
	static let msgRenegotiate: UInt8 = 28
	static let msgEndOfResponse: UInt8 = 29
	static let msgToken: UInt8 = 33

	// 함수 번호
	static let funcAuthPhaseOne: UInt8 = 118
	static let funcAuthPhaseTwo: UInt8 = 115
	static let funcCloseCursors: UInt8 = 105
	static let funcCommit: UInt8 = 14
	static let funcRollback: UInt8 = 15
	static let funcExecute: UInt8 = 94
	static let funcFetch: UInt8 = 5
	static let funcLogoff: UInt8 = 9
	static let funcPing: UInt8 = 147

	// 버전 (접속 협상)
	static let versionDesired: UInt16 = 319
	static let versionMinimum: UInt16 = 300
	static let versionMinAccepted: UInt16 = 315     // 12.1
	static let versionMinLargeSDU: UInt16 = 315
	static let versionMinOOBCheck: UInt16 = 318
	static let versionMinEndOfResponse: UInt16 = 319

	static let sdu: UInt32 = 8192
	static let maxConnectData = 230
	static let protocolCharacteristics: UInt16 = 0x4F98
	static let gsoDontCare: UInt16 = 0x0001
	static let nsiDisableNA: UInt8 = 0x04
	static let nsiSupportSecurityReneg: UInt8 = 0x80
	static let acceptFlagHasEndOfResponse: UInt32 = 0x0200_0000

	static let dataFlagsEOF: UInt16 = 0x0040

	static let charsetUTF8: UInt16 = 873
	static let charsetUTF16: UInt16 = 2000
	static let charsetAL16UTF8: UInt16 = 208
	static let csNChar: UInt8 = 2

	static let longLengthIndicator: UInt8 = 254
	static let nullLengthIndicator: UInt8 = 255
	static let maxShortLength = 252
	static let chunkSize = 32767
	static let maxLongLength: UInt32 = 0x7FFF_FFFF

	// 인증
	static let authModeLogon: UInt32 = 0x0001
	static let authModeSysDBA: UInt32 = 0x0020
	static let authModeSysOper: UInt32 = 0x0040
	static let authModeWithPassword: UInt32 = 0x0100
	static let verifier11g1: UInt32 = 0xB152
	static let verifier11g2: UInt32 = 0x1B25
	static let verifier12c: UInt32 = 0x4815

	// 실행 선택
	static let execParse: UInt32 = 0x01
	static let execBind: UInt32 = 0x08
	static let execDefine: UInt32 = 0x10
	static let execExecute: UInt32 = 0x20
	static let execFetch: UInt32 = 0x40
	static let execCommit: UInt32 = 0x100
	static let execPLSQLBind: UInt32 = 0x400
	static let execNotPLSQL: UInt32 = 0x8000
	static let execImplicitResultSet: UInt32 = 0x8000

	static let errNoDataFound: UInt32 = 1403

	// TTC 필드 버전 (서버마다 다르다. 둘 중 낮은 쪽으로 맞춘다)
	static let fieldVersion12_2 = 8
	static let fieldVersion12_2Ext1 = 9
	static let fieldVersion18_1Ext1 = 11
	static let fieldVersion20_1 = 14
	static let fieldVersion23_1 = 17
	static let fieldVersion23_1Ext1 = 18
	static let fieldVersion23_1Ext3 = 20
	static let fieldVersion23_4 = 24
	static let fieldVersionMax: UInt8 = 24

	// 데이터 형식 번호 (ORA_TYPE_NUM)
	static let typeVarchar: UInt8 = 1
	static let typeNumber: UInt8 = 2
	static let typeBinaryInteger: UInt8 = 3
	static let typeLong: UInt8 = 8
	static let typeRowID: UInt8 = 11
	static let typeDate: UInt8 = 12
	static let typeRaw: UInt8 = 23
	static let typeLongRaw: UInt8 = 24
	static let typeChar: UInt8 = 96
	static let typeBinaryFloat: UInt8 = 100
	static let typeBinaryDouble: UInt8 = 101
	static let typeCursor: UInt8 = 102
	static let typeObject: UInt8 = 109
	static let typeCLOB: UInt8 = 112
	static let typeBLOB: UInt8 = 113
	static let typeBFILE: UInt8 = 114
	static let typeJSON: UInt8 = 119
	static let typeVector: UInt8 = 127
	static let typeTimestamp: UInt8 = 180
	static let typeTimestampTZ: UInt8 = 181
	static let typeIntervalYM: UInt8 = 182
	static let typeIntervalDS: UInt8 = 183
	static let typeURowID: UInt8 = 208
	static let typeTimestampLTZ: UInt8 = 231
	static let typeBoolean: UInt8 = 252
}

/// 접속 때 서버에 보내는 "주고받을 데이터 형식" 표 (형식, 변환 형식, 표현) × n, 마지막은 0,0,0.
/// python-oracledb data_types.pyx 의 표를 숫자로 옮긴 것
enum OracleDataTypes {
	static let table: [UInt16] = [
		1,1,1, 2,2,10, 8,8,1, 12,12,10, 23,23,1, 24,24,1, 25,25,1, 26,26,1, 27,27,10, 28,28,1, 29,29,1, 30,30,1,
		31,31,1, 32,32,1, 33,33,1, 10,10,1, 11,11,1, 40,40,1, 41,41,1, 117,117,1, 120,120,1, 290,290,1, 291,291,1,
		292,292,1, 293,293,1, 294,294,1, 298,298,1, 299,299,1, 300,300,1, 301,301,1, 302,302,1, 303,303,1, 304,304,1,
		305,305,1, 306,306,1, 307,307,1, 308,308,1, 309,309,1, 310,310,1, 311,311,1, 312,312,1, 313,313,1, 315,315,1,
		316,316,1, 317,317,1, 318,318,1, 319,319,1, 320,320,1, 321,321,1, 322,322,1, 323,323,1, 327,327,1, 328,328,1,
		329,329,1, 331,331,1, 333,333,1, 334,334,1, 335,335,1, 336,336,1, 337,337,1, 338,338,1, 339,339,1, 340,340,1,
		341,341,1, 342,342,1, 343,343,1, 344,344,1, 345,345,1, 346,346,1, 348,348,1, 349,349,1, 354,354,1, 355,355,1,
		359,359,1, 363,363,1, 380,380,1, 381,381,1, 382,382,1, 383,383,1, 384,384,1, 385,385,1, 386,386,1, 387,387,1,
		388,388,1, 389,389,1, 390,390,1, 391,391,1, 393,393,1, 394,394,1, 395,395,1, 396,396,1, 397,397,1, 398,398,1,
		399,399,1, 400,400,1, 401,401,1, 404,404,1, 405,405,1, 406,406,1, 407,407,1, 413,413,1, 414,414,1, 415,415,1,
		416,416,1, 417,417,1, 418,418,1, 419,419,1, 420,420,1, 421,421,1, 422,422,1, 423,423,1, 424,424,1, 425,425,1,
		426,426,1, 427,427,1, 429,429,1, 430,430,1, 431,431,1, 432,432,1, 433,433,1, 449,449,1, 450,450,1, 454,454,1,
		455,455,1, 456,456,1, 457,457,1, 458,458,1, 459,459,1, 460,460,1, 461,461,1, 462,462,1, 463,463,1, 466,466,1,
		467,467,1, 468,468,1, 469,469,1, 470,470,1, 471,471,1, 472,472,1, 473,473,1, 474,474,1, 475,475,1, 476,476,1,
		477,477,1, 478,478,1, 479,479,1, 480,480,1, 481,481,1, 482,482,1, 483,483,1, 484,484,1, 485,485,1, 486,486,1,
		490,490,1, 491,491,1, 492,492,1, 493,493,1, 494,494,1, 495,495,1, 496,496,1, 498,498,1, 499,499,1, 500,500,1,
		501,501,1, 502,502,1, 509,509,1, 510,510,1, 513,513,1, 514,514,1, 516,516,1, 517,517,1, 518,518,1, 519,519,1,
		520,520,1, 521,521,1, 522,522,1, 523,523,1, 524,524,1, 525,525,1, 526,526,1, 527,527,1, 528,528,1, 529,529,1,
		530,530,1, 531,531,1, 532,532,1, 533,533,1, 534,534,1, 535,535,1, 536,536,1, 537,537,1, 538,538,1, 539,539,1,
		540,540,1, 541,541,1, 542,542,1, 543,543,1, 560,560,1, 565,565,1, 572,572,1, 573,573,1, 574,574,1, 575,575,1,
		576,576,1, 578,578,1, 563,563,1, 564,564,1, 579,579,1, 580,580,1, 581,581,1, 582,582,1, 583,583,1, 584,584,1,
		585,585,1, 3,2,10, 4,2,10, 5,1,1, 6,2,10, 7,2,10, 9,1,1, 15,1,1, 39,39,1, 68,2,10, 91,2,10, 94,1,1, 95,23,1,
		96,96,1, 97,96,1, 100,100,1, 101,101,1, 102,102,1, 104,11,1, 106,106,1, 108,109,1, 109,109,1, 110,111,1,
		111,111,1, 112,112,1, 113,113,1, 114,114,1, 115,115,1, 116,102,1, 119,119,1, 198,198,1, 146,146,1, 152,2,10,
		153,2,10, 154,2,10, 155,1,1, 156,12,10, 172,2,10, 178,178,1, 179,179,1, 180,180,1, 181,181,1, 182,182,1,
		183,183,1, 184,12,10, 185,185,1, 186,186,1, 187,187,1, 188,188,1, 189,189,1, 190,190,1, 195,112,1, 196,113,1,
		197,114,1, 208,208,1, 231,231,1, 232,231,1, 233,233,1, 241,109,1, 252,252,1, 590,590,1, 591,591,1, 592,592,1,
		613,613,1, 614,614,1, 615,615,1, 616,616,1, 611,611,1, 612,612,1, 593,593,1, 594,594,1, 595,595,1, 596,596,1,
		597,597,1, 598,598,1, 599,599,1, 600,600,1, 601,601,1, 602,602,1, 603,603,1, 604,604,1, 605,605,1, 622,622,1,
		623,623,1, 624,624,1, 625,625,1, 626,626,1, 627,627,1, 628,628,1, 629,629,1, 630,630,1, 631,631,1, 632,632,1,
		637,637,1, 638,638,1, 636,636,1, 639,639,1, 663,663,1, 640,640,1, 652,652,1, 646,646,1, 127,127,1, 0,0,0,
	]
}

/// 보낼 메시지를 바이트로 쌓는다
struct OracleWriter {
	var data = [UInt8]()

	mutating func u8(_ v: UInt8) { data.append(v) }
	mutating func u16(_ v: UInt16) { data += [UInt8(v >> 8), UInt8(v & 0xFF)] }
	mutating func u16le(_ v: UInt16) { data += [UInt8(v & 0xFF), UInt8(v >> 8)] }
	mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8(v >> UInt32(s) & 0xFF)) } }
	mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8(v >> UInt64(s) & 0xFF)) } }
	mutating func raw(_ b: [UInt8]) { data += b }

	/// 가변 길이 정수 (UB2 · UB4 · UB8 모두 같은 방식: 길이 바이트 + 큰 쪽부터)
	mutating func ub(_ v: UInt64) {
		if v == 0 { data.append(0); return }
		var bytes = [UInt8]()
		var x = v
		while x > 0 { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
		// python-oracledb 처럼 1 · 2 · 4 · 8 바이트로만 쓴다
		let n = bytes.count <= 1 ? 1 : bytes.count <= 2 ? 2 : bytes.count <= 4 ? 4 : 8
		data.append(UInt8(n))
		data += [UInt8](repeating: 0, count: n - bytes.count) + bytes
	}
	mutating func ub4(_ v: UInt32) { ub(UInt64(v)) }

	/// 길이 바이트 + 바이트 (252 바이트가 넘으면 254 다음에 32767 바이트씩 나눠 쓰고 0 으로 끝)
	mutating func bytesWithLength(_ b: [UInt8]) {
		if b.count <= TNS.maxShortLength {
			data.append(UInt8(b.count))
			data += b
		} else {
			data.append(TNS.longLengthIndicator)
			var off = 0
			while off < b.count {
				let n = min(TNS.chunkSize, b.count - off)
				ub4(UInt32(n))
				data += b[off..<off + n]
				off += n
			}
			ub4(0)
		}
	}

	/// UB4 길이 + (길이가 있으면) bytesWithLength
	mutating func bytesWithTwoLengths(_ b: [UInt8]) {
		ub4(UInt32(b.count))
		if !b.isEmpty { bytesWithLength(b) }
	}

	/// 인증 메시지의 키 = 값 한 쌍
	mutating func keyValue(_ key: String, _ value: String, flags: UInt32 = 0) {
		bytesWithTwoLengths(Array(key.utf8))
		bytesWithTwoLengths(Array(value.utf8))
		ub4(flags)
	}
}

/// 받은 데이터 패킷의 내용을 이어서 읽는다. 모자라면 more() 로 다음 데이터 패킷을 받아 뒤에 잇는다
/// (메시지는 패킷 경계와 상관없이 이어진다)
final class OracleReader {
	private var buf: [UInt8]
	private var pos = 0
	private let more: () throws -> [UInt8]

	init(_ first: [UInt8], more: @escaping () throws -> [UInt8]) {
		buf = first
		self.more = more
	}

	var hasData: Bool { pos < buf.count }

	private func need(_ n: Int) throws {
		while buf.count - pos < n {
			if pos > 0 { buf.removeFirst(pos); pos = 0 }
			buf += try more()
		}
	}

	func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return buf[pos] }
	func u16() throws -> UInt16 { try need(2); defer { pos += 2 }; return UInt16(buf[pos]) << 8 | UInt16(buf[pos + 1]) }
	func u16le() throws -> UInt16 { try need(2); defer { pos += 2 }; return UInt16(buf[pos]) | UInt16(buf[pos + 1]) << 8 }
	func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
	func bytes(_ n: Int) throws -> [UInt8] {
		guard n > 0 else { return [] }
		try need(n)
		defer { pos += n }
		return Array(buf[pos..<pos + n])
	}
	func skip(_ n: Int) throws { if n > 0 { try need(n); pos += n } }

	/// 가변 길이 정수 (음수 표시는 버림: 길이 바이트의 0x80)
	func ub() throws -> UInt64 {
		let len = Int(try u8() & 0x7F)
		guard len <= 8 else { throw OracleError.protocolError("정수 길이가 잘못되었습니다 (\(len)).") }
		var v: UInt64 = 0
		for b in try bytes(len) { v = v << 8 | UInt64(b) }
		return v
	}
	func ub2() throws -> UInt16 { UInt16(truncatingIfNeeded: try ub()) }
	func ub4() throws -> UInt32 { UInt32(truncatingIfNeeded: try ub()) }
	/// 부호 있는 가변 길이 정수
	func sb() throws -> Int64 {
		let first = try u8()
		let len = Int(first & 0x7F)
		guard len <= 8 else { throw OracleError.protocolError("정수 길이가 잘못되었습니다 (\(len)).") }
		var v: UInt64 = 0
		for b in try bytes(len) { v = v << 8 | UInt64(b) }
		let n = Int64(bitPattern: v)
		return first & 0x80 != 0 ? -n : n
	}
	/// 가변 길이 정수를 읽지 않고 건너뛴다 (python skip_ub2/4/8)
	func skipUB() throws { try skip(Int(try u8() & 0x7F)) }

	/// 길이 바이트 + 바이트. 0 · 255 는 NULL, 254 는 나눠 보낸 조각들 (python read_bytes)
	func bytesWithLength() throws -> [UInt8]? {
		let len = try u8()
		if len == 0 || len == TNS.nullLengthIndicator { return nil }
		if len == TNS.longLengthIndicator {
			var out = [UInt8]()
			while true {
				let n = Int(try ub4())
				if n == 0 { break }
				out += try bytes(n)
			}
			return out
		}
		return try bytes(Int(len))
	}
	func skipBytesWithLength() throws { _ = try bytesWithLength() }
	func string() throws -> String? { try bytesWithLength().map { String(decoding: $0, as: UTF8.self) } }
	/// UB4 길이 + (있으면) 길이 붙은 글자 (python read_str_with_length)
	func stringWithLength() throws -> String? { try ub4() > 0 ? try string() : nil }
	func skipStringWithLength() throws { if try ub4() > 0 { try skipBytesWithLength() } }

	func nulTerminated() throws -> [UInt8] {
		var out = [UInt8]()
		while true { let b = try u8(); if b == 0 { break }; out.append(b) }
		return out
	}
}

/// Oracle 연결 오류
enum OracleError: LocalizedError {
	/// 서버가 돌려준 오류 (ORA-xxxxx)
	case server(code: Int, message: String)
	/// 접속 거절 (리스너가 돌려준 TNS 오류)
	case refused(String)
	case protocolError(String)
	case io(String)
	case closed

	var errorDescription: String? {
		switch self {
		case .server(_, let m): m
		case .refused(let m): m
		case .protocolError(let m): "Oracle 프로토콜 오류: \(m)"
		case .io(let m): m
		case .closed: "서버와 연결이 끊어졌습니다."
		}
	}
}
