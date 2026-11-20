import Foundation
import Darwin
import Security

/// SQL Server 클라이언트 (TDS 7.4, 외부 라이브러리 없이 소켓으로 바로).
/// 순서: PRELOGIN(암호화 정하기) → TLS 손잡기(PRELOGIN 패킷 안에 감싸서) → LOGIN7(TLS 안) → SQL Batch → 토큰 읽기.
/// 소켓은 막히는(blocking) 방식이고 모든 작업은 연결마다 하나인 직렬 큐에서 돈다.
/// 지원: SQL Server 2012 이상, SQL 로그인(아이디·비밀번호). 아직: Windows 인증·Entra ID, 바인드(RPC), MARS
final class SQLServerConnection: DBConnection, @unchecked Sendable {
	struct Options {
		var host: String
		var port: Int
		var user: String
		var password: String
		/// 접속하자마자 쓸 DB (비면 로그인 기본 DB)
		var database: String
		/// off = 로그인만 암호화(서버가 원하면 전부), preferred·required = 전부 암호화(인증서 확인 안 함), verify = 전부 + 인증서 확인
		var tls: TLSMode = .required
		/// 인증서 이름 확인용 원래 서버 이름 (SSH 터널이면 host 는 127.0.0.1)
		var tlsHost = ""
		var tlsCA = ""
		var appName = "iSQL"
	}

	private(set) var serverVersion = ""
	/// 지금 DB (ENVCHANGE 로 알려 준다)
	private(set) var currentDatabase = ""
	var isOpen: Bool { fd >= 0 }
	var tlsSummary: String? { tls?.summary }
	var onQuery: (@Sendable (String, Double, String?) -> Void)?

	private var fd: Int32 = -1
	private let queue = DispatchQueue(label: "iSQL.sqlserver")
	private var tls: TDSTLS?
	private var readBuffer = [UInt8]()
	private var readPos = 0
	/// 보내는 패킷 크기 (서버가 ENVCHANGE 로 바꿔 준다)
	private var packetSize = 4096
	private var packetID: UInt8 = 1
	/// BEGIN TRAN 뒤 서버가 준 트랜잭션 번호 (Batch 머리에 넣는다, 없으면 0)
	private var transaction: [UInt8] = Array(repeating: 0, count: 8)

	// 쿼리 취소 (ATTENTION): 다른 스레드에서 같은 소켓에 보낸다
	private let stateLock = NSLock()
	/// 쓰기 한 번에 하나 (요청 패킷 사이에 ATTENTION 이 끼지 않게)
	private let writeLock = NSLock()
	private var busy = false
	private var attentionSent = false
	/// 이번 응답에 취소 확인(DONE + ATTN)이 왔는지
	private var sawAttention = false

	// MARK: - 바깥에서 쓰는 비동기 API

	static func connect(_ o: Options) async throws -> SQLServerConnection {
		let c = SQLServerConnection()
		try await c.run { try c.openSync(o) }
		return c
	}

	func query(_ sql: String) async throws -> [QueryResult] {
		try await run { try self.querySync(sql) }
	}

	func query(bytes: [UInt8]) async throws -> [QueryResult] {
		try await query(String(decoding: bytes, as: UTF8.self))
	}

	func rows(_ sql: String) async throws -> QueryResult {
		try await query(sql).last(where: \.isResultSet) ?? QueryResult()
	}

	func close() { queue.async { self.closeSync() } }

	/// 실행 중인 요청 취소: ATTENTION 패킷(내용 없음)을 보낸다. 서버는 하던 것을 멈추고 DONE(ATTN)으로 알린다 ([MS-TDS] 2.2.1.7).
	/// 연결은 그대로 쓸 수 있다
	func cancel() {
		stateLock.lock()
		guard busy, !attentionSent, fd >= 0 else { stateLock.unlock(); return }
		attentionSent = true
		stateLock.unlock()
		DispatchQueue.global(qos: .userInitiated).async {
			let pkt: [UInt8] = [TDS.packetAttention, TDS.statusEOM, 0, 8, 0, 0, 1, 0]
			self.writeLock.lock()
			defer { self.writeLock.unlock() }
			_ = self.rawWrite(pkt)
		}
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
		do {
			// 1. PRELOGIN: 암호화 정하기
			let clientEncrypt = o.tls == .off ? TDS.encryptOff : TDS.encryptOn
			try writeMessage(TDS.packetPrelogin, Self.prelogin(encrypt: clientEncrypt))
			let pre = try readMessage()
			let serverEncrypt = try Self.preloginEncryption(pre.payload)
			// 둘 다 OFF = 로그인 패킷만 암호화, 어느 쪽이 ON·REQ = 전부, 서버 NOT_SUP = 없음
			let loginOnly: Bool
			switch (clientEncrypt, serverEncrypt) {
			case (_, TDS.encryptNotSup):
				if o.tls == .required || o.tls == .verify {
					throw TDSError.protocolError("서버가 암호화(TLS)를 지원하지 않습니다. 서버 설정에서 TLS 를 \"사용 안 함\" 이나 \"지원하면 사용\" 으로 바꾸세요.")
				}
				loginOnly = false
			case (TDS.encryptOff, TDS.encryptOff): loginOnly = true
			default: loginOnly = false
			}
			if serverEncrypt != TDS.encryptNotSup {
				// 2. TLS 손잡기: 손잡는 동안의 TLS 레코드는 PRELOGIN 패킷에 감싸 주고받는다
				tls = try TDSTLS(fd: fd, host: o.tlsHost.isEmpty ? o.host : o.tlsHost, verify: o.tls == .verify, caPath: o.tlsCA)
			}
			// 3. LOGIN7 (TLS 안)
			try writeMessage(TDS.packetLogin7, Self.login7(o, packetSize: UInt32(packetSize)))
			// 로그인만 암호화면 이제부터 평문 (close_notify 없이 그냥 그만 쓴다)
			if loginOnly { tls = nil }
			let reply = try readMessage()
			var loggedIn = false
			_ = try parse(reply.payload) { token, _ in
				if token == TDS.tokenLoginAck { loggedIn = true }
			}
			guard loggedIn else { throw TDSError.protocolError("로그인 응답(LOGINACK)이 없습니다.") }
		} catch {
			closeSync()
			throw error
		}
	}

	/// PRELOGIN 요청: 항목 목록(종류 1·위치 2·길이 2, 빅 엔디언) + 0xFF + 내용
	private static func prelogin(encrypt: UInt8) -> [UInt8] {
		let items: [(UInt8, [UInt8])] = [
			(TDS.preVersion, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),
			(TDS.preEncryption, [encrypt]),
			(TDS.preInstOpt, [0x00]),
			(TDS.preThreadID, withUnsafeBytes(of: UInt32(getpid()).bigEndian) { Array($0) }),
			(TDS.preMARS, [0x00]),
		]
		var head: [UInt8] = [], body: [UInt8] = []
		var offset = items.count * 5 + 1
		for (t, v) in items {
			head += [t, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(v.count >> 8), UInt8(v.count & 0xFF)]
			body += v
			offset += v.count
		}
		return head + [TDS.preTerminator] + body
	}

	private static func preloginEncryption(_ p: [UInt8]) throws -> UInt8 {
		var i = 0
		while i < p.count, p[i] != TDS.preTerminator {
			guard i + 5 <= p.count else { break }
			let t = p[i], off = Int(p[i + 1]) << 8 | Int(p[i + 2]), len = Int(p[i + 3]) << 8 | Int(p[i + 4])
			if t == TDS.preEncryption, len >= 1, off < p.count { return p[off] }
			i += 5
		}
		throw TDSError.protocolError("PRELOGIN 응답에 암호화 항목이 없습니다.")
	}

	/// LOGIN7: 고정 94바이트(길이·버전·옵션·글자 위치들) + 글자들(UTF-16)
	private static func login7(_ o: Options, packetSize: UInt32) -> [UInt8] {
		let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac"
		// 위치 표 순서: 호스트 · 사용자 · 비밀번호 · 앱 · 서버 · (확장) · 클라이언트 라이브러리 · 언어 · DB
		let fields: [[UInt8]] = [
			TDS.utf16le(String(host.prefix(128))), TDS.utf16le(o.user), TDS.scramble(o.password), TDS.utf16le(o.appName),
			TDS.utf16le(o.host), [], TDS.utf16le("iSQL"), [], TDS.utf16le(o.database),
		]
		let fixed = 94
		var data: [UInt8] = []
		var offsets: [(UInt16, UInt16)] = []
		for f in fields {
			offsets.append((UInt16(fixed + data.count), UInt16(f.count / 2)))
			data += f
		}
		var p: [UInt8] = []
		func le32(_ v: UInt32) { p += withUnsafeBytes(of: v.littleEndian) { Array($0) } }
		func le16(_ v: UInt16) { p += withUnsafeBytes(of: v.littleEndian) { Array($0) } }
		le32(UInt32(fixed + data.count))
		le32(TDS.version74)
		le32(packetSize)
		le32(0x0700_0000)              // 클라이언트 프로그램 버전
		le32(UInt32(getpid()))
		le32(0)                        // 연결 ID
		p.append(0xE0)                 // OptionFlags1: USE DB · DB 바꾸기 실패면 오류 · SET LANGUAGE
		p.append(0x03)                 // OptionFlags2: 언어 실패면 오류 · ODBC (ANSI_NULLS 등 표준 설정)
		p.append(0x00)                 // TypeFlags
		p.append(0x00)                 // OptionFlags3
		le32(0)                        // 시간대
		le32(0)                        // LCID
		for (off, len) in offsets { le16(off); le16(len) }
		p += [0, 0, 0, 0, 0, 0]        // 클라이언트 MAC
		le16(UInt16(fixed + data.count)); le16(0)   // SSPI 없음
		le16(UInt16(fixed + data.count)); le16(0)   // AtchDBFile
		le16(UInt16(fixed + data.count)); le16(0)   // ChangePassword
		le32(0)                        // SSPI 긴 길이
		return p + data
	}

	// MARK: - 쿼리

	/// GO 줄이 있으면 배치마다 따로 보내고 결과를 이어 붙인다 (SET SHOWPLAN_TEXT 처럼 배치에 혼자 있어야 하는 문장)
	private func querySync(_ sql: String) throws -> [QueryResult] {
		let batches = TSQLScript.batches(sql)
		guard batches.count > 1 else { return try batchSync(sql) }
		var out: [QueryResult] = []
		for b in batches { out += try batchSync(b) }
		return out
	}

	private func batchSync(_ sql: String) throws -> [QueryResult] {
		let start = Date()
		stateLock.lock(); busy = true; attentionSent = false; stateLock.unlock()
		sawAttention = false
		defer { stateLock.lock(); busy = false; attentionSent = false; stateLock.unlock() }
		do {
			// ALL_HEADERS: 트랜잭션 머리 (길이 4 + [길이 4, 종류 2, 트랜잭션 8, 대기 요청 수 4])
			var body: [UInt8] = []
			body += withUnsafeBytes(of: UInt32(22).littleEndian) { Array($0) }
			body += withUnsafeBytes(of: UInt32(18).littleEndian) { Array($0) }
			body += [0x02, 0x00]
			body += transaction
			body += withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) }
			body += TDS.utf16le(sql)
			try writeMessage(TDS.packetSQLBatch, body)
			let reply = try readMessage()
			let results: [QueryResult]
			do { results = try parse(reply.payload) { _, _ in } } catch { try finishAttention(); throw error }
			try finishAttention()
			onQuery?(sql, Date().timeIntervalSince(start), nil)
			return results
		} catch {
			onQuery?(sql, Date().timeIntervalSince(start), error.localizedDescription)
			throw error
		}
	}

	/// 응답 토큰들을 읽어 결과로. 결과 표(COLMETADATA·ROW)마다 하나, 행 수만 있는 문장(DONE+COUNT)마다 하나.
	/// 오류(심각도 11 이상)가 있으면 다 읽은 뒤 첫 오류를 던진다. onToken 은 로그인 응답 확인용
	private func parse(_ p: [UInt8], onToken: (UInt8, inout TDSReader) throws -> Void) throws -> [QueryResult] {
		var r = TDSReader(p)
		var results: [QueryResult] = []
		var cols: [TDSColumn] = []
		var current: QueryResult?
		var firstError: TDSError?
		var infos: [String] = []
		while !r.atEnd {
			let token = try r.u8()
			try onToken(token, &r)
			switch token {
			case TDS.tokenColMetadata:
				if let c = current { results.append(c) }
				cols = try readColMetadata(&r)
				current = QueryResult(columns: cols.map(\.column))
			case TDS.tokenRow, TDS.tokenNBCRow:
				var nulls: [UInt8] = []
				if token == TDS.tokenNBCRow { nulls = Array(try r.bytes((cols.count + 7) / 8)) }
				var row: [Value] = []
				row.reserveCapacity(cols.count)
				for (k, c) in cols.enumerated() {
					if !nulls.isEmpty, nulls[k / 8] & (1 << UInt8(k % 8)) != 0 { row.append(.null); continue }
					row.append(try readValue(&r, c))
				}
				current?.rows.append(row)
			case TDS.tokenDone, TDS.tokenDoneProc, TDS.tokenDoneInProc:
				let status = try r.u16()
				_ = try r.u16()
				let count = try r.u64()
				if status & TDS.doneAttn != 0 { sawAttention = true }
				if var c = current {
					if status & TDS.doneCount != 0 { c.affectedRows = count }
					results.append(c)
					current = nil
					cols = []
				} else if status & TDS.doneCount != 0 {
					results.append(QueryResult(affectedRows: count))
				}
			case TDS.tokenError, TDS.tokenInfo:
				let len = Int(try r.u16())
				var m = TDSReader(Array(try r.bytes(len)))
				let number = Int(try m.u32()), state = Int(try m.u8()), severity = Int(try m.u8())
				let message = try m.usVarChar()
				_ = try m.bVarChar()                    // 서버 이름
				let proc = try m.bVarChar()
				let line = Int(try m.u32())
				if token == TDS.tokenError || severity > 10 {
					if firstError == nil { firstError = .server(number: number, state: state, severity: severity, message: message, line: line, procedure: proc) }
				} else {
					infos.append(message)
				}
			case TDS.tokenLoginAck:
				let len = Int(try r.u16())
				var m = TDSReader(Array(try r.bytes(len)))
				_ = try m.u8()                              // 인터페이스
				_ = try m.u32()                             // TDS 버전
				_ = try m.bVarChar()                        // 프로그램 이름 ("Microsoft SQL Server")
				let major = try m.u8(), minor = try m.u8()
				let b1 = try m.u8(), b2 = try m.u8()
				serverVersion = "SQL Server \(major).\(minor).\(Int(b1) << 8 | Int(b2))"
			case TDS.tokenEnvChange:
				let len = Int(try r.u16())
				try envChange(Array(try r.bytes(len)))
			case TDS.tokenOrder, TDS.tokenTabName, TDS.tokenColInfo, TDS.tokenSSPI, TDS.tokenFedAuthInfo:
				try r.skip(Int(try r.u16()))
			case TDS.tokenFeatureExtAck:
				// 기능 번호 1 + 길이 4 + 내용 … 0xFF 로 끝
				while true {
					let f = try r.u8()
					if f == 0xFF { break }
					try r.skip(Int(try r.u32()))
				}
			case TDS.tokenSessionState:
				try r.skip(Int(try r.u32()))
			case TDS.tokenReturnStatus:
				_ = try r.u32()
			case TDS.tokenReturnValue:
				// RPC 에서만 온다 (지금은 Batch 만 보낸다): 순번 2, 이름, 상태 1, 형식, 값
				_ = try r.u16(); _ = try r.bVarChar(); _ = try r.u8()
				var c = try readTypeInfo(&r, userType: try r.u32(), flags: try r.u16())
				c.name = ""
				_ = try readValue(&r, c)
			default:
				throw TDSError.protocolError("알 수 없는 응답 토큰 0x\(String(token, radix: 16)) (위치 \(r.i - 1)).")
			}
		}
		if let c = current { results.append(c) }
		if let e = firstError { throw e }
		if !infos.isEmpty {
			if results.isEmpty { results.append(QueryResult()) }
			results[results.count - 1].info = infos.joined(separator: "\n")
		}
		return results.isEmpty ? [QueryResult()] : results
	}

	/// 취소를 보냈으면 확인(DONE + ATTN)까지 읽고 "취소됨" 을 던진다. 확인이 이번 응답에 없으면 다음 메시지를 더 읽는다
	private func finishAttention() throws {
		stateLock.lock(); let sent = attentionSent; stateLock.unlock()
		guard sent || sawAttention else { return }
		var guardCount = 0
		while !sawAttention && guardCount < 1000 {
			guardCount += 1
			let m = try readMessage()
			_ = try? parse(m.payload) { _, _ in }
		}
		throw TDSError.cancelled
	}

	private func envChange(_ b: [UInt8]) throws {
		var m = TDSReader(b)
		let type = try m.u8()
		switch type {
		case 1:   // DB
			currentDatabase = try m.bVarChar()
		case 4:   // 패킷 크기
			if let n = Int(try m.bVarChar()), n >= 512 { packetSize = n }
		case 8:   // 트랜잭션 시작: 새 값 = 트랜잭션 번호 8바이트
			let v = Array(try m.bVarByte())
			if v.count == 8 { transaction = v }
		case 9, 10, 17:   // 커밋 · 롤백 · 트랜잭션 끝
			transaction = Array(repeating: 0, count: 8)
		default: break
		}
	}

	// MARK: - 형식·값

	private func readColMetadata(_ r: inout TDSReader) throws -> [TDSColumn] {
		let count = Int(try r.u16())
		if count == 0xFFFF { return [] }
		var cols: [TDSColumn] = []
		for _ in 0..<count {
			let userType = try r.u32(), flags = try r.u16()
			var c = try readTypeInfo(&r, userType: userType, flags: flags)
			// TEXT·NTEXT·IMAGE 는 테이블 이름 조각이 붙는다
			if [TDS.typeText, TDS.typeNText, TDS.typeImage].contains(c.type) {
				let parts = Int(try r.u8())
				for _ in 0..<parts { _ = try r.usVarChar() }
			}
			c.name = try r.bVarChar()
			cols.append(c)
		}
		return cols
	}

	private func readTypeInfo(_ r: inout TDSReader, userType: UInt32, flags: UInt16) throws -> TDSColumn {
		var c = TDSColumn()
		c.userType = userType
		c.flags = flags
		c.type = try r.u8()
		switch c.type {
		case TDS.typeNull: c.maxLength = 0
		case TDS.typeInt1, TDS.typeBit: c.maxLength = 1
		case TDS.typeInt2: c.maxLength = 2
		case TDS.typeInt4, TDS.typeDateTim4, TDS.typeFlt4, TDS.typeMoney4: c.maxLength = 4
		case TDS.typeInt8, TDS.typeMoney, TDS.typeDateTime, TDS.typeFlt8: c.maxLength = 8
		case TDS.typeGUID, TDS.typeIntN, TDS.typeBitN, TDS.typeFltN, TDS.typeMoneyN, TDS.typeDateTimN:
			c.maxLength = Int(try r.u8())
		case TDS.typeDecimal, TDS.typeNumeric, TDS.typeDecimalN, TDS.typeNumericN:
			c.maxLength = Int(try r.u8())
			c.precision = try r.u8()
			c.scale = try r.u8()
		case TDS.typeDateN:
			c.maxLength = 3
		case TDS.typeTimeN, TDS.typeDateTime2N, TDS.typeDateTimeOffsetN:
			c.scale = try r.u8()
		case TDS.typeBigVarChar, TDS.typeBigChar, TDS.typeNVarChar, TDS.typeNChar:
			c.maxLength = Int(try r.u16())
			c.collation = Array(try r.bytes(5))
		case TDS.typeBigVarBin, TDS.typeBigBinary:
			c.maxLength = Int(try r.u16())
		case TDS.typeVarChar, TDS.typeChar, TDS.typeVarBinary, TDS.typeBinary:
			c.maxLength = Int(try r.u8())
		case TDS.typeText, TDS.typeNText:
			c.maxLength = Int(try r.u32())
			c.collation = Array(try r.bytes(5))
		case TDS.typeImage, TDS.typeVariant:
			c.maxLength = Int(try r.u32())
		case TDS.typeXML:
			if try r.u8() != 0 { _ = try r.bVarChar(); _ = try r.bVarChar(); _ = try r.usVarChar() }
			c.maxLength = 0xFFFF
		case TDS.typeUDT:
			c.maxLength = Int(try r.u16())
			_ = try r.bVarChar(); _ = try r.bVarChar()
			c.udtName = try r.bVarChar()
			_ = try r.usVarChar()
			c.maxLength = 0xFFFF
		default:
			throw TDSError.protocolError("알 수 없는 데이터 형식 0x\(String(c.type, radix: 16)).")
		}
		return c
	}

	/// 행 안의 값 하나
	private func readValue(_ r: inout TDSReader, _ c: TDSColumn) throws -> Value {
		switch c.type {
		case TDS.typeNull: return .null
		case TDS.typeInt1: return .text(String(try r.u8()))
		case TDS.typeBit: return .text(try r.u8() != 0 ? "1" : "0")
		case TDS.typeInt2, TDS.typeInt4, TDS.typeInt8: return .text(String(TDSValues.int(try r.bytes(c.maxLength))))
		case TDS.typeFlt4, TDS.typeFlt8: return .text(TDSValues.float(try r.bytes(c.maxLength)))
		case TDS.typeMoney, TDS.typeMoney4: return .text(TDSValues.money(try r.bytes(c.maxLength)))
		case TDS.typeDateTime: return .text(TDSValues.dateTime(try r.bytes(8)))
		case TDS.typeDateTim4: return .text(TDSValues.smallDateTime(try r.bytes(4)))
		default: break
		}
		if c.isPLP {
			guard let data = try readPLP(&r) else { return .null }
			return value(data[...], c)
		}
		// 길이 앞머리: 1바이트(BYTELEN) · 2바이트(USHORTLEN, 0xFFFF = NULL) · TEXT 계열은 글자 포인터 + 4바이트
		let len: Int
		switch c.type {
		case TDS.typeBigVarChar, TDS.typeBigChar, TDS.typeNVarChar, TDS.typeNChar, TDS.typeBigVarBin, TDS.typeBigBinary:
			let n = try r.u16()
			if n == 0xFFFF { return .null }
			len = Int(n)
		case TDS.typeText, TDS.typeNText, TDS.typeImage:
			let ptr = Int(try r.u8())
			if ptr == 0 { return .null }
			try r.skip(ptr + 8)                    // 글자 포인터 + 시각 표시
			len = Int(try r.u32())
		case TDS.typeVariant:
			let n = Int(try r.u32())
			if n == 0 { return .null }
			return try variant(Array(try r.bytes(n)))
		default:
			len = Int(try r.u8())
			if len == 0 { return .null }
		}
		return value(try r.bytes(len), c)
	}

	/// PLP: 전체 길이 8바이트(모두 1 = NULL) + 조각(길이 4 + 내용)… + 길이 0
	private func readPLP(_ r: inout TDSReader) throws -> [UInt8]? {
		let total = try r.u64()
		if total == UInt64.max { return nil }
		var out: [UInt8] = []
		if total != UInt64.max - 1, total < 1 << 31 { out.reserveCapacity(Int(total)) }
		while true {
			let n = Int(try r.u32())
			if n == 0 { break }
			out += try r.bytes(n)
		}
		return out
	}

	/// 길이를 뗀 값 바이트 → 화면 값
	private func value(_ b: ArraySlice<UInt8>, _ c: TDSColumn) -> Value {
		switch c.type {
		case TDS.typeIntN: return .text(String(TDSValues.int(b)))
		case TDS.typeBitN: return .text(b.first.map { $0 != 0 ? "1" : "0" } ?? "")
		case TDS.typeFltN: return .text(TDSValues.float(b))
		case TDS.typeMoneyN: return .text(TDSValues.money(b))
		case TDS.typeDateTimN: return .text(b.count == 4 ? TDSValues.smallDateTime(b) : TDSValues.dateTime(b))
		case TDS.typeDecimal, TDS.typeNumeric, TDS.typeDecimalN, TDS.typeNumericN:
			guard let sign = b.first else { return .null }
			return .text(TDSValues.withScale(TDSValues.decimalDigits(b.dropFirst()), negative: sign == 0, scale: Int(c.scale)))
		case TDS.typeGUID: return .text(TDSValues.guid(b))
		case TDS.typeDateN: return .text(TDSValues.date(days: Int(TDSValues.uint(b))))
		case TDS.typeTimeN: return .text(TDSValues.time(units: TDSValues.uint(b), scale: Int(c.scale)))
		case TDS.typeDateTime2N:
			let tb = TDSValues.timeBytes(Int(c.scale))
			return .text(TDSValues.date(days: Int(TDSValues.uint(b.dropFirst(tb)))) + " " + TDSValues.time(units: TDSValues.uint(b.prefix(tb)), scale: Int(c.scale)))
		case TDS.typeDateTimeOffsetN: return .text(TDSValues.dateTimeOffset(b, scale: Int(c.scale)))
		case TDS.typeNVarChar, TDS.typeNChar, TDS.typeNText, TDS.typeXML: return .text(TDS.string(utf16le: b))
		case TDS.typeBigVarChar, TDS.typeBigChar, TDS.typeText, TDS.typeVarChar, TDS.typeChar: return .text(TDSValues.text(b, c.collation))
		default: return .bytes(Data(b))   // BINARY · VARBINARY · IMAGE · UDT
		}
	}

	/// sql_variant: 바탕 형식 1 + 속성 길이 1 + 속성 + 값
	private func variant(_ b: [UInt8]) throws -> Value {
		var r = TDSReader(b)
		var c = TDSColumn()
		c.type = try r.u8()
		let propLen = Int(try r.u8())
		var props = TDSReader(Array(try r.bytes(propLen)))
		switch c.type {
		case TDS.typeDecimalN, TDS.typeNumericN: c.precision = try props.u8(); c.scale = try props.u8()
		case TDS.typeTimeN, TDS.typeDateTime2N, TDS.typeDateTimeOffsetN: c.scale = try props.u8()
		case TDS.typeBigVarChar, TDS.typeBigChar: c.collation = Array(try props.bytes(5))
		default: break
		}
		let rest = try r.bytes(r.remaining)
		switch c.type {
		case TDS.typeInt1: return .text(String(rest.first ?? 0))
		case TDS.typeBit: return .text((rest.first ?? 0) != 0 ? "1" : "0")
		case TDS.typeInt2, TDS.typeInt4, TDS.typeInt8: return .text(String(TDSValues.int(rest)))
		case TDS.typeFlt4, TDS.typeFlt8: return .text(TDSValues.float(rest))
		case TDS.typeMoney, TDS.typeMoney4: return .text(TDSValues.money(rest))
		case TDS.typeDateTime: return .text(TDSValues.dateTime(rest))
		case TDS.typeDateTim4: return .text(TDSValues.smallDateTime(rest))
		default: return value(rest, c)
		}
	}

	// MARK: - 패킷

	/// 메시지 하나를 패킷들로 나눠 보낸다 (마지막 패킷에 EOM)
	private func writeMessage(_ type: UInt8, _ payload: [UInt8]) throws {
		// 메시지 하나를 다 보낼 때까지 ATTENTION 이 끼지 않게
		writeLock.lock()
		defer { writeLock.unlock() }
		let room = packetSize - 8
		var off = 0
		repeat {
			let n = min(room, payload.count - off)
			let last = off + n >= payload.count
			let total = n + 8
			var pkt: [UInt8] = [type, last ? TDS.statusEOM : 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0, packetID, 0]
			packetID = packetID &+ 1
			pkt += payload[off..<(off + n)]
			try writeAll(pkt)
			off += n
		} while off < payload.count
	}

	/// 메시지 하나 (EOM 까지 패킷들을 이어 붙인 내용)
	private func readMessage() throws -> (type: UInt8, payload: [UInt8]) {
		var out: [UInt8] = []
		var type: UInt8 = 0
		while true {
			let h = try readExactly(8)
			type = h[0]
			let len = Int(h[2]) << 8 | Int(h[3])
			guard len >= 8 else { throw TDSError.protocolError("패킷 길이가 이상합니다 (\(len)).") }
			out += try readExactly(len - 8)
			if h[1] & TDS.statusEOM != 0 { return (type, out) }
		}
	}

	private func readExactly(_ n: Int) throws -> [UInt8] {
		while readBuffer.count - readPos < n {
			if readPos > 0 { readBuffer.removeFirst(readPos); readPos = 0 }
			var chunk = [UInt8](repeating: 0, count: max(65536, n))
			let got: Int
			if let tls {
				do { got = try chunk.withUnsafeMutableBytes { try tls.read($0.baseAddress!, $0.count) } }
				catch { closeSync(); throw error }
			} else {
				got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
			}
			if got <= 0 {
				closeSync()
				throw got == 0 ? TDSError.closed : TDSError.io(String(cString: strerror(errno)))
			}
			readBuffer += chunk[0..<got]
		}
		let out = Array(readBuffer[readPos..<readPos + n])
		readPos += n
		return out
	}

	/// ATTENTION 용: 실패해도 연결을 닫지 않는다 (읽는 쪽이 알아서 끝난다)
	private func rawWrite(_ bytes: [UInt8]) -> Bool {
		var off = 0
		while off < bytes.count {
			let n: Int
			if let tls {
				n = (try? bytes.withUnsafeBytes { try tls.write($0.baseAddress! + off, bytes.count - off) }) ?? -1
			} else {
				n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
			}
			if n <= 0 { return false }
			off += n
		}
		return true
	}

	/// writeLock 을 잡은 채로 부른다 (writeMessage)
	private func writeAll(_ bytes: [UInt8]) throws {
		var off = 0
		while off < bytes.count {
			let n: Int
			if let tls {
				n = (try? bytes.withUnsafeBytes { try tls.write($0.baseAddress! + off, bytes.count - off) }) ?? -1
			} else {
				n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
			}
			if n <= 0 { closeSync(); throw TDSError.io(String(cString: strerror(errno))) }
			off += n
		}
	}

	private func closeSync() {
		guard fd >= 0 else { return }
		tls?.close()
		tls = nil
		Darwin.close(fd)
		fd = -1
	}

	private static func openSocket(host: String, port: Int) throws -> Int32 {
		var hints = addrinfo()
		hints.ai_family = AF_UNSPEC
		hints.ai_socktype = SOCK_STREAM
		var res: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
			throw TDSError.io("\(host) 주소를 찾지 못했습니다.")
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
				if Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
				lastError = String(cString: strerror(errno))
				Darwin.close(fd)
			}
			ai = a.pointee.ai_next
		}
		throw TDSError.io("\(host):\(port) 에 접속하지 못했습니다 (\(lastError)).")
	}
}

// MARK: - TLS (손잡는 동안은 PRELOGIN 패킷에 감싸고, 그 뒤로는 소켓에 그대로)

/// SQL Server 의 TLS: 손잡기 레코드를 TDS PRELOGIN 패킷 안에 넣어 주고받는다 ([MS-TDS] 3.3.5.2).
/// 손잡기가 끝나면 TLS 레코드를 소켓에 바로 쓰고 읽으며, 그 안에 TDS 패킷이 들어간다. SecureTransport (MySQLTLS 와 같은 이유)
final class TDSTLS {
	final class IO {
		let fd: Int32
		var handshaking = true
		var out: [UInt8] = []
		var inBuf: [UInt8] = []
		var packetID: UInt8 = 1
		init(fd: Int32) { self.fd = fd }

		func rawWrite(_ b: [UInt8]) -> Bool {
			var off = 0
			while off < b.count {
				let n = b.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, b.count - off) }
				if n < 0 && errno == EINTR { continue }
				if n <= 0 { return false }
				off += n
			}
			return true
		}

		func rawRead(_ n: Int) -> [UInt8]? {
			var out = [UInt8](repeating: 0, count: n)
			var got = 0
			while got < n {
				let k = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
				if k < 0 && errno == EINTR { continue }
				if k <= 0 { return nil }
				got += k
			}
			return out
		}

		/// 모아 둔 손잡기 레코드를 PRELOGIN 패킷(들)로
		func flush() -> Bool {
			guard !out.isEmpty else { return true }
			var off = 0
			let room = 4096 - 8
			while off < out.count {
				let n = min(room, out.count - off)
				let last = off + n >= out.count
				var pkt: [UInt8] = [TDS.packetPrelogin, last ? TDS.statusEOM : 0, UInt8((n + 8) >> 8), UInt8((n + 8) & 0xFF), 0, 0, packetID, 0]
				packetID = packetID &+ 1
				pkt += out[off..<(off + n)]
				if !rawWrite(pkt) { return false }
				off += n
			}
			out = []
			return true
		}
	}

	private let ctx: SSLContext
	private let io: IO
	private let ioRef: Unmanaged<IO>

	init(fd: Int32, host: String, verify: Bool, caPath: String) throws {
		guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { throw TDSError.protocolError("TLS 를 준비하지 못했습니다.") }
		ctx = c
		io = IO(fd: fd)
		ioRef = Unmanaged.passRetained(io)
		SSLSetIOFuncs(ctx, tdsTLSRead, tdsTLSWrite)
		SSLSetConnection(ctx, UnsafeRawPointer(ioRef.toOpaque()))
		SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
		if !host.isEmpty && !MySQLTLS.isIPAddress(host) { SSLSetPeerDomainName(ctx, host, host.utf8.count) }
		SSLSetSessionOption(ctx, .breakOnServerAuth, true)
		while true {
			let st = SSLHandshake(ctx)
			if st == noErr { break }
			if st == errSSLPeerAuthCompleted {
				if verify { try MySQLTLS.checkTrust(ctx, host: host, caPath: caPath) }
				continue
			}
			if st == errSSLWouldBlock { continue }
			throw TDSError.protocolError(MySQLTLS.describe(st))
		}
		guard io.flush() else { throw TDSError.io("TLS 손잡기를 보내지 못했습니다.") }
		io.handshaking = false
	}

	deinit { ioRef.release() }

	var summary: String {
		var p = SSLProtocol.sslProtocolUnknown
		SSLGetNegotiatedProtocolVersion(ctx, &p)
		return p == .tlsProtocol12 ? "TLS 1.2" : "TLS"
	}

	func read(_ buf: UnsafeMutableRawPointer, _ len: Int) throws -> Int {
		var got = 0
		let st = SSLRead(ctx, buf, len, &got)
		if got > 0 { return got }
		if st == errSSLClosedGraceful || st == errSSLClosedNoNotify { return 0 }
		if st != noErr && st != errSSLWouldBlock { throw TDSError.protocolError(MySQLTLS.describe(st)) }
		return got
	}

	func write(_ buf: UnsafeRawPointer, _ len: Int) throws -> Int {
		var done = 0
		let st = SSLWrite(ctx, buf, len, &done)
		if st != noErr && done == 0 { throw TDSError.protocolError(MySQLTLS.describe(st)) }
		return done
	}

	func close() { SSLClose(ctx) }
}

private func tdsTLSRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
	let io = Unmanaged<TDSTLS.IO>.fromOpaque(conn).takeUnretainedValue()
	let want = len.pointee
	if !io.handshaking {
		guard let b = io.rawRead(want) else { len.pointee = 0; return errSSLClosedAbort }
		b.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: want) }
		return noErr
	}
	// 손잡는 중: 먼저 보낼 것을 보내고, 모자라면 PRELOGIN 패킷을 더 읽어 내용만 모은다
	guard io.flush() else { len.pointee = 0; return errSSLClosedAbort }
	while io.inBuf.count < want {
		guard let h = io.rawRead(8) else { len.pointee = 0; return errSSLClosedAbort }
		let plen = Int(h[2]) << 8 | Int(h[3])
		guard plen >= 8, let body = io.rawRead(plen - 8) else { len.pointee = 0; return errSSLClosedAbort }
		io.inBuf += body
	}
	io.inBuf.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: want) }
	io.inBuf.removeFirst(want)
	return noErr
}

private func tdsTLSWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
	let io = Unmanaged<TDSTLS.IO>.fromOpaque(conn).takeUnretainedValue()
	let bytes = Array(UnsafeRawBufferPointer(start: data, count: len.pointee))
	if io.handshaking { io.out += bytes; return noErr }
	return io.rawWrite(bytes) ? noErr : errSSLClosedAbort
}
