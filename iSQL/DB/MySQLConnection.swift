import Foundation
import Darwin
import CryptoKit
import Security

/// MySQL / MariaDB 클라이언트 (텍스트 프로토콜).
/// 외부 라이브러리 없이 직접 구현한다: 접속(mysql_native_password, caching_sha2_password 와 그 RSA 전체 인증), COM_QUERY, 여러 결과.
/// 소켓은 막히는(blocking) 방식이고, 모든 작업은 연결마다 하나인 직렬 큐에서 돈다.
final class MySQLConnection: @unchecked Sendable {
	struct Options {
		var host: String
		var port: Int
		var user: String
		var password: String
		var database: String
	}

	private(set) var serverVersion = ""
	private(set) var connectionID: UInt32 = 0
	private var fd: Int32 = -1
	private var seq: UInt8 = 0
	private let queue = DispatchQueue(label: "iSQL.mysql")
	private var readBuffer = [UInt8]()
	private var readPos = 0

	var isOpen: Bool { fd >= 0 }

	/// 쿼리를 보낸 뒤 알린다 (콘솔): SQL, 걸린 시간(초), 오류. 연결 큐에서 불린다
	var onQuery: (@Sendable (String, Double, String?) -> Void)?

	// MARK: - 바깥에서 쓰는 비동기 API

	static func connect(_ o: Options) async throws -> MySQLConnection {
		let c = MySQLConnection()
		try await c.run { try c.openSync(o) }
		return c
	}

	/// SQL 을 실행하고 결과를 모두 돌려준다 (여러 문장이면 결과도 여러 개)
	func query(_ sql: String) async throws -> [QueryResult] {
		try await run { try self.querySync(sql) }
	}

	/// 바이트 그대로 실행 (SQL 파일 가져오기: 덤프 안 문자열이 UTF-8 이 아닐 수도 있어 String 으로 바꾸지 않는다)
	func query(bytes: [UInt8]) async throws -> [QueryResult] {
		try await run { try self.querySync(bytes: bytes) }
	}

	/// 결과 하나만 필요할 때 (마지막 결과)
	func rows(_ sql: String) async throws -> QueryResult {
		try await query(sql).last ?? QueryResult()
	}

	func close() {
		queue.async { self.closeSync() }
	}

	deinit { if fd >= 0 { Darwin.close(fd) } }

	private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { cont in
			queue.async {
				do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
			}
		}
	}

	// MARK: - 접속

	private func openSync(_ o: Options) throws {
		fd = try Self.openSocket(host: o.host, port: o.port)
		let hs = try readPacket()
		if hs.first == 0xFF { throw parseError(hs) }
		var r = Reader(hs)
		let proto = r.u8()
		guard proto == 10 else { throw MySQLError.protocolError("지원하지 않는 접속 방식입니다 (프로토콜 \(proto)).") }
		serverVersion = r.nulString()
		connectionID = r.u32()
		var scramble = r.bytes(8)
		r.skip(1)
		var serverCaps = UInt32(r.u16())
		var plugin = "mysql_native_password"
		if !r.atEnd {
			_ = r.u8()            // 문자셋
			_ = r.u16()           // 상태
			serverCaps |= UInt32(r.u16()) << 16
			let authLen = Int(r.u8())
			r.skip(10)
			if serverCaps & Cap.secureConnection != 0 {
				let n = max(13, authLen - 8)
				scramble += r.bytes(n).prefix(12)
			}
			if serverCaps & Cap.pluginAuth != 0 { plugin = r.nulString() }
		}

		var caps: UInt32 = Cap.longPassword | Cap.longFlag | Cap.protocol41 | Cap.transactions | Cap.secureConnection
			| Cap.multiStatements | Cap.multiResults | Cap.psMultiResults | Cap.pluginAuth | Cap.pluginAuthLenencData
		if !o.database.isEmpty { caps |= Cap.connectWithDB }
		caps &= serverCaps | Cap.connectWithDB

		let auth = Self.scramble(plugin: plugin, password: o.password, nonce: scramble)
		var p = Writer()
		p.u32(caps)
		p.u32(16 * 1024 * 1024)
		p.u8(45)                               // utf8mb4_general_ci (MariaDB 도 아는 번호)
		p.zeros(23)
		p.nulString(o.user)
		if caps & Cap.pluginAuthLenencData != 0 { p.lenenc(UInt64(auth.count)); p.raw(auth) }
		else { p.u8(UInt8(auth.count)); p.raw(auth) }
		if caps & Cap.connectWithDB != 0 { p.nulString(o.database) }
		p.nulString(plugin)
		try writePacket(p.data)

		try authenticate(plugin: plugin, password: o.password, nonce: scramble)
		// 결과 글자를 utf8mb4 로 받는다
		_ = try querySync("SET NAMES utf8mb4")
	}

	/// 인증 응답을 끝(OK)까지 처리한다
	private func authenticate(plugin startPlugin: String, password: String, nonce startNonce: [UInt8]) throws {
		var plugin = startPlugin
		var nonce = startNonce
		while true {
			let pkt = try readPacket()
			switch pkt.first {
			case 0x00:
				return
			case 0xFF:
				throw parseError(pkt)
			case 0xFE:
				// 다른 인증 방식으로 바꾸자는 요청
				var r = Reader(pkt); r.skip(1)
				plugin = r.nulString()
				nonce = Array(r.rest().prefix(20))
				try writePacket(Self.scramble(plugin: plugin, password: password, nonce: nonce))
			case 0x01:
				guard plugin == "caching_sha2_password", pkt.count >= 2 else { throw MySQLError.protocolError("알 수 없는 인증 응답입니다.") }
				if pkt[1] == 3 { continue }    // 빠른 인증 성공, 다음에 OK 가 온다
				if pkt[1] == 4 {
					// 전체 인증: TLS 가 없으니 서버 공개키를 받아 비밀번호를 RSA 로 암호화해 보낸다
					try writePacket([0x02])
					let keyPkt = try readPacket()
					if keyPkt.first == 0xFF { throw parseError(keyPkt) }
					let pem = String(decoding: keyPkt.dropFirst(), as: UTF8.self)
					try writePacket(try Self.rsaEncryptPassword(password, nonce: nonce, pem: pem))
					continue
				}
				throw MySQLError.protocolError("알 수 없는 인증 응답입니다.")
			default:
				throw MySQLError.protocolError("알 수 없는 인증 응답입니다.")
			}
		}
	}

	static func scramble(plugin: String, password: String, nonce: [UInt8]) -> [UInt8] {
		guard !password.isEmpty else { return [] }
		let pw = Data(password.utf8)
		switch plugin {
		case "caching_sha2_password":
			// SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + nonce)
			let h1 = Array(SHA256.hash(data: pw))
			let h2 = Array(SHA256.hash(data: Data(h1)))
			let h3 = Array(SHA256.hash(data: Data(h2 + nonce)))
			return zip(h1, h3).map { $0 ^ $1 }
		case "mysql_clear_password":
			return Array(pw) + [0]
		default:
			// mysql_native_password: SHA1(pw) XOR SHA1(nonce + SHA1(SHA1(pw)))
			let h1 = Array(Insecure.SHA1.hash(data: pw))
			let h2 = Array(Insecure.SHA1.hash(data: Data(h1)))
			let h3 = Array(Insecure.SHA1.hash(data: Data(nonce + h2)))
			return zip(h1, h3).map { $0 ^ $1 }
		}
	}

	private static func rsaEncryptPassword(_ password: String, nonce: [UInt8], pem: String) throws -> [UInt8] {
		let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
		guard let der = Data(base64Encoded: b64), let pkcs1 = DER.rsaPublicKeyFromSPKI([UInt8](der)) else {
			throw MySQLError.protocolError("서버 공개키를 읽지 못했습니다.")
		}
		let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
		guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, nil) else {
			throw MySQLError.protocolError("서버 공개키를 읽지 못했습니다.")
		}
		let plain = Array(password.utf8) + [0]
		let xored = plain.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] }
		var err: Unmanaged<CFError>?
		guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(xored) as CFData, &err) as Data? else {
			throw MySQLError.protocolError("비밀번호를 암호화하지 못했습니다.")
		}
		return [UInt8](enc)
	}

	// MARK: - 쿼리

	private func querySync(_ sql: String) throws -> [QueryResult] {
		try querySync(bytes: Array(sql.utf8))
	}

	private func querySync(bytes: [UInt8]) throws -> [QueryResult] {
		guard let onQuery else { return try querySyncRaw(bytes: bytes) }
		let start = CFAbsoluteTimeGetCurrent()
		func text() -> String {
			// 콘솔에는 앞부분만 (SQL 파일 가져오기 묶음처럼 큰 것도 있다)
			let head = bytes.count > 4000 ? Array(bytes.prefix(4000)) : bytes
			let s = String(decoding: head, as: UTF8.self)
			return bytes.count > 4000 ? s + " … (\(bytes.count.formatted())바이트)" : s
		}
		do {
			let r = try querySyncRaw(bytes: bytes)
			onQuery(text(), CFAbsoluteTimeGetCurrent() - start, nil)
			return r
		} catch {
			onQuery(text(), CFAbsoluteTimeGetCurrent() - start, error.localizedDescription)
			throw error
		}
	}

	private func querySyncRaw(bytes: [UInt8]) throws -> [QueryResult] {
		guard fd >= 0 else { throw MySQLError.closed }
		seq = 0
		try writePacket([0x03] + bytes)
		var results: [QueryResult] = []
		while true {
			let (result, more) = try readResult()
			results.append(result)
			if !more { break }
		}
		return results
	}

	/// 결과 하나를 읽는다. 뒤에 결과가 더 있으면 more = true
	private func readResult() throws -> (QueryResult, Bool) {
		let first = try readPacket()
		switch first.first {
		case 0x00:
			let ok = parseOK(first)
			var res = QueryResult()
			res.affectedRows = ok.affected
			res.lastInsertID = ok.insertID
			res.info = ok.info
			return (res, ok.status & Status.moreResults != 0)
		case 0xFF:
			throw parseError(first)
		case 0xFB:
			throw MySQLError.protocolError("LOAD DATA LOCAL INFILE 은 지원하지 않습니다.")
		default:
			var r = Reader(first)
			let count = Int(r.lenenc() ?? 0)
			var cols: [Column] = []
			cols.reserveCapacity(count)
			for _ in 0..<count { cols.append(parseColumn(try readPacket())) }
			_ = try readPacket()   // EOF
			var rows: [[Value]] = []
			while true {
				let pkt = try readPacket()
				if pkt.first == 0xFE && pkt.count < 9 {
					var e = Reader(pkt); e.skip(1); _ = e.u16()
					let status = e.u16()
					var res = QueryResult()
					res.columns = cols
					res.rows = rows
					return (res, status & Status.moreResults != 0)
				}
				if pkt.first == 0xFF { throw parseError(pkt) }
				var rr = Reader(pkt)
				var row: [Value] = []
				row.reserveCapacity(count)
				for c in cols {
					if rr.peek() == 0xFB { rr.skip(1); row.append(.null); continue }
					let bytes = rr.lenencBytes()
					if c.isBinary { row.append(.bytes(Data(bytes))) }
					else { row.append(.text(String(decoding: bytes, as: UTF8.self))) }
				}
				rows.append(row)
			}
		}
	}

	private func parseColumn(_ pkt: [UInt8]) -> Column {
		var r = Reader(pkt)
		_ = r.lenencString()               // catalog
		let schema = r.lenencString()
		let table = r.lenencString()
		let orgTable = r.lenencString()
		let name = r.lenencString()
		let orgName = r.lenencString()
		_ = r.lenenc()                     // 고정 길이 0x0c
		let charset = r.u16()
		let length = r.u32()
		let type = r.u8()
		let flags = r.u16()
		let decimals = r.u8()
		return Column(name: name, orgName: orgName, table: table, orgTable: orgTable, schema: schema,
		              charset: charset, length: length, type: type, flags: flags, decimals: decimals)
	}

	private func parseOK(_ pkt: [UInt8]) -> (affected: UInt64, insertID: UInt64, status: UInt16, info: String) {
		var r = Reader(pkt); r.skip(1)
		let affected = r.lenenc() ?? 0
		let insertID = r.lenenc() ?? 0
		let status = r.u16()
		_ = r.u16()
		// info 는 원래 패킷 끝까지인 글자인데, MySQL 8.4 는 길이 바이트를 앞에 붙여 보냈다("(Rows matched…", "&Records…").
		// 첫 바이트가 남은 길이와 딱 맞으면 길이 바이트로 보고 뗀다
		var info = r.rest()
		if let n = info.first, n < 251, Int(n) == info.count - 1 { info.removeFirst() }
		return (affected, insertID, status, String(decoding: info, as: UTF8.self))
	}

	private func parseError(_ pkt: [UInt8]) -> MySQLError {
		var r = Reader(pkt); r.skip(1)
		let code = r.u16()
		var state = ""
		if r.peek() == UInt8(ascii: "#") { r.skip(1); state = String(decoding: r.bytes(5), as: UTF8.self) }
		return .server(code: Int(code), state: state, message: String(decoding: r.rest(), as: UTF8.self))
	}

	// MARK: - 패킷

	private func readPacket() throws -> [UInt8] {
		var out = [UInt8]()
		while true {
			let h = try readExactly(4)
			let len = Int(h[0]) | Int(h[1]) << 8 | Int(h[2]) << 16
			seq = h[3] &+ 1
			out += try readExactly(len)
			if len < 0xFFFFFF { return out }
		}
	}

	private func writePacket(_ payload: [UInt8]) throws {
		var off = 0
		repeat {
			let n = min(0xFFFFFF, payload.count - off)
			var pkt = [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), seq]
			seq &+= 1
			pkt += payload[off..<off + n]
			try writeAll(pkt)
			off += n
			if n < 0xFFFFFF { break }
		} while true
	}

	private func readExactly(_ n: Int) throws -> [UInt8] {
		while readBuffer.count - readPos < n {
			if readPos > 0 { readBuffer.removeFirst(readPos); readPos = 0 }
			var chunk = [UInt8](repeating: 0, count: max(65536, n))
			let got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
			if got <= 0 {
				closeSync()
				throw got == 0 ? MySQLError.closed : MySQLError.io(String(cString: strerror(errno)))
			}
			readBuffer += chunk[0..<got]
		}
		let out = Array(readBuffer[readPos..<readPos + n])
		readPos += n
		return out
	}

	private func writeAll(_ bytes: [UInt8]) throws {
		var off = 0
		while off < bytes.count {
			let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
			if n <= 0 { closeSync(); throw MySQLError.io(String(cString: strerror(errno))) }
			off += n
		}
	}

	private func closeSync() {
		guard fd >= 0 else { return }
		seq = 0
		_ = try? writePacket([0x01])     // COM_QUIT
		Darwin.close(fd)
		fd = -1
	}

	private static func openSocket(host: String, port: Int) throws -> Int32 {
		var hints = addrinfo()
		hints.ai_family = AF_UNSPEC
		hints.ai_socktype = SOCK_STREAM
		var res: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
			throw MySQLError.io("\(host) 주소를 찾지 못했습니다.")
		}
		defer { freeaddrinfo(res) }
		var lastError = "접속하지 못했습니다."
		var ai: UnsafeMutablePointer<addrinfo>? = first
		while let a = ai {
			let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
			if fd >= 0 {
				var on: Int32 = 1
				setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
				setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
				var tv = timeval(tv_sec: 15, tv_usec: 0)
				setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
				if Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
					// 접속 뒤에는 오래 걸리는 쿼리도 기다린다 (읽기 시간 제한 없음)
					return fd
				}
				lastError = String(cString: strerror(errno))
				Darwin.close(fd)
			}
			ai = a.pointee.ai_next
		}
		throw MySQLError.io("\(host):\(port) 에 접속하지 못했습니다 (\(lastError)).")
	}

	private enum Cap {
		static let longPassword: UInt32 = 0x1
		static let longFlag: UInt32 = 0x4
		static let connectWithDB: UInt32 = 0x8
		static let protocol41: UInt32 = 0x200
		static let transactions: UInt32 = 0x2000
		static let secureConnection: UInt32 = 0x8000
		static let multiStatements: UInt32 = 0x10000
		static let multiResults: UInt32 = 0x20000
		static let psMultiResults: UInt32 = 0x40000
		static let pluginAuth: UInt32 = 0x80000
		static let pluginAuthLenencData: UInt32 = 0x200000
	}

	private enum Status {
		static let moreResults: UInt16 = 0x0008
	}
}

// MARK: - 결과 타입

enum Value: Hashable {
	case null
	case text(String)
	case bytes(Data)

	var string: String? {
		switch self {
		case .null: nil
		case .text(let s): s
		case .bytes(let d): String(data: d, encoding: .utf8) ?? "(\(d.count) 바이트)"
		}
	}
}

struct Column: Hashable {
	var name: String
	var orgName: String
	var table: String
	var orgTable: String
	var schema: String
	var charset: UInt16
	var length: UInt32
	var type: UInt8
	var flags: UInt16
	var decimals: UInt8

	/// 문자셋 63(binary) 이고 BLOB·BINARY 계열이면 바이트로 받는다
	var isBinary: Bool { charset == 63 && [249, 250, 251, 252, 253, 254, 255].contains(type) }
	var isPrimaryKey: Bool { flags & 0x2 != 0 }
	/// JSON 컬럼 (MYSQL_TYPE_JSON 245)
	var isJSON: Bool { type == 245 }
	/// 여러 줄 글자 컬럼: TEXT 계열(바이너리 아닌 BLOB 형)·JSON → 칸 안이 아니라 편집 시트로 고친다
	var isLongText: Bool { isJSON || ([249, 250, 251, 252].contains(type) && !isBinary) }
	var isNumeric: Bool { [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(type) }
}

struct QueryResult {
	var columns: [Column] = []
	var rows: [[Value]] = []
	var affectedRows: UInt64 = 0
	var lastInsertID: UInt64 = 0
	var info = ""

	var isResultSet: Bool { !columns.isEmpty }

	/// 이름으로 값 꺼내기 (작은 결과에서만)
	func string(_ row: Int, _ name: String) -> String? {
		guard let i = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
		return rows[row][i].string
	}
}

enum MySQLError: LocalizedError {
	case server(code: Int, state: String, message: String)
	case protocolError(String)
	case io(String)
	case closed

	var errorDescription: String? {
		switch self {
		case .server(let code, _, let message): "\(message) (오류 \(code))"
		case .protocolError(let s): s
		case .io(let s): s
		case .closed: "서버와 연결이 끊어졌습니다."
		}
	}
}

// MARK: - 읽고 쓰기 도우미

struct Reader {
	let b: [UInt8]
	var i = 0
	init(_ b: [UInt8]) { self.b = b }

	var atEnd: Bool { i >= b.count }
	func peek() -> UInt8? { i < b.count ? b[i] : nil }
	mutating func skip(_ n: Int) { i = min(b.count, i + n) }
	mutating func u8() -> UInt8 { guard i < b.count else { return 0 }; defer { i += 1 }; return b[i] }
	mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
	mutating func u24() -> UInt32 { UInt32(u8()) | UInt32(u8()) << 8 | UInt32(u8()) << 16 }
	mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
	mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
	mutating func bytes(_ n: Int) -> [UInt8] {
		let end = min(b.count, i + n)
		defer { i = end }
		return Array(b[i..<end])
	}
	mutating func rest() -> [UInt8] { bytes(b.count - i) }
	mutating func nulString() -> String {
		let start = i
		while i < b.count && b[i] != 0 { i += 1 }
		defer { if i < b.count { i += 1 } }
		return String(decoding: b[start..<i], as: UTF8.self)
	}
	mutating func lenenc() -> UInt64? {
		let f = u8()
		switch f {
		case 0xFB: return nil
		case 0xFC: return UInt64(u16())
		case 0xFD: return UInt64(u24())
		case 0xFE: return u64()
		default: return UInt64(f)
		}
	}
	mutating func lenencBytes() -> [UInt8] { bytes(Int(lenenc() ?? 0)) }
	mutating func lenencString() -> String { String(decoding: lenencBytes(), as: UTF8.self) }
}

struct Writer {
	var data = [UInt8]()
	mutating func u8(_ v: UInt8) { data.append(v) }
	mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { data.append(UInt8(v >> UInt32(s) & 0xFF)) } }
	mutating func zeros(_ n: Int) { data += [UInt8](repeating: 0, count: n) }
	mutating func raw(_ b: [UInt8]) { data += b }
	mutating func nulString(_ s: String) { data += Array(s.utf8) + [0] }
	mutating func lenenc(_ v: UInt64) {
		switch v {
		case ..<251: data.append(UInt8(v))
		case ..<0x10000: data += [0xFC, UInt8(v & 0xFF), UInt8(v >> 8)]
		case ..<0x1000000: data += [0xFD, UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16)]
		default: data.append(0xFE); for s in stride(from: 0, to: 64, by: 8) { data.append(UInt8(v >> UInt64(s) & 0xFF)) }
		}
	}
}

/// 서버가 주는 공개키(SubjectPublicKeyInfo)에서 RSA 키(PKCS#1)만 꺼낸다
enum DER {
	static func rsaPublicKeyFromSPKI(_ der: [UInt8]) -> [UInt8]? {
		var i = 0
		func readLen() -> Int? {
			guard i < der.count else { return nil }
			let f = der[i]; i += 1
			if f < 0x80 { return Int(f) }
			let n = Int(f & 0x7F)
			guard n <= 4, i + n <= der.count else { return nil }
			var len = 0
			for _ in 0..<n { len = len << 8 | Int(der[i]); i += 1 }
			return len
		}
		// SEQUENCE
		guard der.first == 0x30 else { return nil }
		i = 1; guard readLen() != nil else { return nil }
		// 이미 PKCS#1 (SEQUENCE 안에 바로 INTEGER) 이면 그대로
		if i < der.count && der[i] == 0x02 { return der }
		// AlgorithmIdentifier SEQUENCE 건너뛰기
		guard i < der.count, der[i] == 0x30 else { return nil }
		i += 1; guard let algLen = readLen() else { return nil }
		i += algLen
		// BIT STRING
		guard i < der.count, der[i] == 0x03 else { return nil }
		i += 1; guard let bitLen = readLen(), i + bitLen <= der.count else { return nil }
		i += 1   // 남는 비트 수(0)
		return Array(der[i..<i + bitLen - 1])
	}
}
