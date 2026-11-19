import Foundation
import Darwin

/// Oracle 클라이언트 (thin: Oracle Client 라이브러리 없이 소켓으로 바로 붙는다).
/// python-oracledb thin 모드(Oracle, UPL/Apache-2.0)와 oracle-nio(Apache-2.0)를 보고 iSQL 방식으로 옮겼다:
/// 소켓은 막히는(blocking) 방식이고 모든 작업은 연결마다 하나인 직렬 큐에서 돈다 → 응답을 다 읽은 뒤에 다음 요청을 보낸다.
/// 지원: Oracle 12.1 이상, 비밀번호 인증(12c · 11g 검증자), 서비스 이름 · SID. 아직: TLS(TCPS), 바인드, LOB 내용 읽기
final class OracleConnection: DBConnection, @unchecked Sendable {
	struct Options {
		var host: String
		var port: Int
		var user: String
		var password: String
		/// 서비스 이름 (예: FREEPDB1). sid 가 true 면 SID
		var service: String
		var sid = false
		/// SYSDBA 로 접속
		var sysdba = false
	}

	private(set) var serverVersion = ""
	var isOpen: Bool { fd >= 0 }
	var onQuery: (@Sendable (String, Double, String?) -> Void)?

	private var fd: Int32 = -1
	private let queue = DispatchQueue(label: "iSQL.oracle")
	private var readBuffer = [UInt8]()
	private var readPos = 0

	// 접속 때 서버와 맞춘 것
	private var largeSDU = false
	private var sdu = Int(TNS.sdu)
	private var supportsEndOfResponse = false
	private var fieldVersion = Int(TNS.fieldVersionMax)
	private var compileCaps = OracleConnection.defaultCompileCaps()
	private var runtimeCaps = OracleConnection.defaultRuntimeCaps()
	private var nCharsetID = TNS.charsetUTF16
	/// VARCHAR 최대 길이 (서버가 32K 를 받으면 32767)
	private var maxStringSize: UInt32 = 4000
	private var seq: UInt8 = 0
	/// 다 쓴 커서: 다음 요청에 얹어(piggyback) 닫는다
	private var cursorsToClose: [UInt32] = []

	/// 한 번에 받아 오는 행 수
	private let fetchSize: UInt32 = 500

	// MARK: - 바깥에서 쓰는 비동기 API

	static func connect(_ o: Options) async throws -> OracleConnection {
		let c = OracleConnection()
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
		// 접속 · 인증 중에는 30초 넘게 답이 없으면 끊는다 (끝난 뒤에는 오래 걸리는 쿼리도 기다린다)
		setReadTimeout(30)
		do {
			try negotiate(o)
			try authenticate(o)
		} catch {
			closeSocket()
			throw error
		}
		setReadTimeout(0)
	}

	/// TNS 접속(CONNECT → ACCEPT) 뒤 TTC 프로토콜 · 데이터 형식을 맞춘다
	private func negotiate(_ o: Options) throws {
		let target = o.sid ? "(SID=\(Self.sanitize(o.service)))" : "(SERVICE_NAME=\(Self.sanitize(o.service)))"
		let cid = "(PROGRAM=iSQL)(HOST=\(Self.sanitize(Self.machineName)))(USER=\(Self.sanitize(NSUserName())))"
		let connectString = "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=\(Self.sanitize(o.host)))(PORT=\(o.port)))"
			+ "(CONNECT_DATA=\(target)(CID=\(cid))))"

		var accepted = false
		var resends = 0
		try sendConnect(connectString)
		while !accepted {
			let p = try readPacket()
			switch p.type {
			case TNS.packetAccept:
				try parseAccept(p.payload)
				accepted = true
			case TNS.packetResend:
				// 리스너가 처음 접속을 다시 보내 달라고 하는 경우가 흔하다
				resends += 1
				guard resends < 3 else { throw OracleError.protocolError("서버가 접속을 계속 다시 보내 달라고 합니다.") }
				try sendConnect(connectString)
			case TNS.packetRefuse:
				throw Self.refuseError(p.payload, service: o.service, sid: o.sid)
			case TNS.packetRedirect:
				throw OracleError.refused("서버가 다른 주소로 다시 접속하라고 합니다 (리다이렉트). 아직 지원하지 않습니다.")
			default:
				throw OracleError.protocolError("접속 중에 모르는 패킷이 왔습니다 (\(p.type)).")
			}
		}

		// 프로토콜: 드라이버 이름을 보내고 서버의 문자셋 · 기능 목록을 받는다
		var w = OracleWriter()
		w.u8(TNS.msgProtocol)
		w.u8(6)          // 프로토콜 버전 (8.1 이상)
		w.u8(0)          // 배열 끝
		w.raw(Array("iSQL".utf8))
		w.u8(0)
		try sendData(w.data)
		let r1 = Response(.protocolPhase)
		try readResponse(r1)
		try r1.throwIfError()

		// 데이터 형식 표
		w = OracleWriter()
		w.u8(TNS.msgDataTypes)
		w.u16le(TNS.charsetUTF8)
		w.u16le(TNS.charsetUTF8)
		w.u8(0x01 | 0x02)          // 여러 바이트 문자 · 길이 변환
		w.u8(UInt8(compileCaps.count))
		w.raw(compileCaps)
		w.u8(UInt8(runtimeCaps.count))
		w.raw(runtimeCaps)
		let t = OracleDataTypes.table
		var i = 0
		while i + 2 < t.count {
			if t[i] == 0 { break }
			w.u16(t[i]); w.u16(t[i + 1]); w.u16(t[i + 2]); w.u16(0)
			i += 3
		}
		w.u16(0)
		try sendData(w.data)
		let r2 = Response(.dataTypesPhase)
		try readResponse(r2)
		try r2.throwIfError()
	}

	/// 비밀번호 인증 2단계 (O5LOGON)
	private func authenticate(_ o: Options) throws {
		var mode = TNS.authModeLogon
		if o.sysdba { mode |= TNS.authModeSysDBA }
		let user = Array(o.user.utf8)

		// 1단계: 누구인지 알리고 서버의 세션 키 반쪽 · 검증자 정보를 받는다
		var w = OracleWriter()
		writeFunctionCode(&w, TNS.funcAuthPhaseOne)
		writeAuthHeader(&w, user: user, mode: mode, pairs: 5)
		w.keyValue("AUTH_TERMINAL", "unknown")
		w.keyValue("AUTH_PROGRAM_NM", "iSQL")
		w.keyValue("AUTH_MACHINE", Self.machineName)
		w.keyValue("AUTH_PID", String(getpid()))
		w.keyValue("AUTH_SID", NSUserName())
		try sendData(w.data)
		let r1 = Response(.auth)
		try readResponse(r1)
		try r1.throwIfError()

		let vt = r1.verifierType
		guard vt == TNS.verifier12c || vt == TNS.verifier11g1 || vt == TNS.verifier11g2 else {
			throw OracleError.refused("지원하지 않는 비밀번호 검증 방식입니다 (\(String(vt, radix: 16))). 10g 방식 비밀번호만 있는 계정은 비밀번호를 다시 설정해야 합니다.")
		}
		let v = try OracleAuth.verifier(password: o.password, params: r1.params, verifierType: vt)

		// 2단계: 암호화한 비밀번호와 세션 설정
		w = OracleWriter()
		writeFunctionCode(&w, TNS.funcAuthPhaseTwo)
		writeAuthHeader(&w, user: user, mode: mode | TNS.authModeWithPassword, pairs: vt == TNS.verifier12c ? 7 : 6)
		w.keyValue("AUTH_SESSKEY", v.sessionKey, flags: 1)
		if let s = v.speedyKey { w.keyValue("AUTH_PBKDF2_SPEEDY_KEY", s) }
		w.keyValue("AUTH_PASSWORD", v.encodedPassword)
		w.keyValue("SESSION_CLIENT_CHARSET", "873")
		w.keyValue("SESSION_CLIENT_DRIVER_NAME", "iSQL thn : 2.2")
		w.keyValue("SESSION_CLIENT_VERSION", String(2 << 24 | 2 << 20))
		w.keyValue("AUTH_ALTER_SESSION", Self.alterSessionStatement(), flags: 1)
		try sendData(w.data)
		let r2 = Response(.auth)
		try readResponse(r2)
		try r2.throwIfError()

		guard OracleAuth.serverResponseValid(r2.params["AUTH_SVR_RESPONSE"], comboKey: v.comboKey) else {
			throw OracleError.refused("서버의 인증 응답이 맞지 않습니다.")
		}
		if let n = r2.params["AUTH_VERSION_NO"].flatMap({ UInt32($0) }) {
			serverVersion = fieldVersion >= TNS.fieldVersion18_1Ext1
				? "\(n >> 24 & 0xFF).\(n >> 16 & 0xFF).\(n >> 12 & 0x0F).\(n >> 4 & 0xFF).\(n & 0x0F)"
				: "\(n >> 24 & 0xFF).\(n >> 20 & 0x0F).\(n >> 12 & 0x0F).\(n >> 8 & 0x0F).\(n & 0x0F)"
		}
	}

	private func writeAuthHeader(_ w: inout OracleWriter, user: [UInt8], mode: UInt32, pairs: UInt32) {
		w.u8(user.isEmpty ? 0 : 1)     // 사용자 이름 있음
		w.ub4(UInt32(user.count))
		w.ub4(mode)
		w.u8(1)                        // pointer (authivl)
		w.ub4(pairs)
		w.u8(1)                        // pointer (authovl)
		w.u8(1)                        // pointer (authovln)
		if !user.isEmpty { w.bytesWithLength(user) }
	}

	/// 세션 시간대를 이 맥의 시간대로 (끝에 NUL 이 있어야 서버가 받는다)
	private static func alterSessionStatement() -> String {
		let off = TimeZone.current.secondsFromGMT()
		let sign = off < 0 ? "-" : "+"
		return String(format: "ALTER SESSION SET TIME_ZONE='%@%02d:%02d'", sign, abs(off) / 3600, abs(off) % 3600 / 60) + "\0"
	}

	// MARK: - 쿼리

	private func querySync(_ sql: String) throws -> [QueryResult] {
		let started = Date()
		do {
			let result = try executeSync(sql)
			onQuery?(sql, Date().timeIntervalSince(started), nil)
			return [result]
		} catch {
			onQuery?(sql, Date().timeIntervalSince(started), error.localizedDescription)
			throw error
		}
	}

	enum StatementKind { case query, plsql, ddl, other }

	/// 첫 낱말로 문장 종류를 정하고, SQL 끝의 ; 와 SQL*Plus 의 / 를 뗀다 (PL/SQL 블록의 END; 는 그대로)
	static func prepare(_ sql: String) -> (text: String, kind: StatementKind) {
		var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
		if text.hasSuffix("/"), let nl = text.lastIndex(of: "\n"),
		   text[text.index(after: nl)...].trimmingCharacters(in: .whitespaces) == "/" {
			text = String(text[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		let words = firstWords(text, 6)
		let first = words.first ?? ""
		let kind: StatementKind
		switch first {
		case "SELECT", "WITH": kind = .query
		case "BEGIN", "DECLARE", "CALL": kind = .plsql
		case "CREATE", "ALTER", "DROP", "GRANT", "REVOKE", "ANALYZE", "AUDIT", "NOAUDIT", "COMMENT", "TRUNCATE",
		     "RENAME", "FLASHBACK", "PURGE", "ASSOCIATE", "DISASSOCIATE": kind = .ddl
		default: kind = .other
		}
		// CREATE [OR REPLACE] [EDITIONABLE|NONEDITIONABLE] PROCEDURE/FUNCTION/PACKAGE/TRIGGER/TYPE … 는 본문이 PL/SQL
		let plsqlObjects: Set<String> = ["PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE", "LIBRARY", "JAVA"]
		let isPLSQLBody = kind == .plsql || (first == "CREATE" && words.dropFirst().contains { plsqlObjects.contains($0) })
		if !isPLSQLBody {
			while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
		}
		return (text, kind)
	}

	/// 주석 · 괄호를 건너뛴 앞 낱말들 (대문자)
	private static func firstWords(_ s: String, _ n: Int) -> [String] {
		var out = [String]()
		var cur = ""
		let c = Array(s.unicodeScalars)
		var i = 0
		while i < c.count && out.count < n {
			let ch = c[i]
			if ch == "-" && i + 1 < c.count && c[i + 1] == "-" {
				while i < c.count && c[i] != "\n" { i += 1 }
				continue
			}
			if ch == "/" && i + 1 < c.count && c[i + 1] == "*" {
				i += 2
				while i + 1 < c.count && !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
				i += 2
				continue
			}
			if CharacterSet.letters.contains(ch) || ch == "_" || (CharacterSet.decimalDigits.contains(ch) && !cur.isEmpty) {
				cur.unicodeScalars.append(ch)
			} else if !cur.isEmpty {
				out.append(cur.uppercased()); cur = ""
			}
			i += 1
		}
		if !cur.isEmpty && out.count < n { out.append(cur.uppercased()) }
		return out
	}

	private func executeSync(_ sql: String) throws -> QueryResult {
		guard fd >= 0 else { throw OracleError.closed }
		let (text, kind) = Self.prepare(sql)
		let sqlBytes = Array(text.utf8)
		let isQuery = kind == .query

		try sendExecute(sql: sqlBytes, kind: kind, cursor: 0, defines: nil)
		let resp = Response(.execute)
		try readResponse(resp)
		// 커서는 행을 다 받은 뒤(또는 오류로 끝난 뒤) 다음 요청에 얹어 닫는다
		let cursor = resp.cursorID
		defer { if cursor != 0 && isQuery { cursorsToClose.append(UInt32(cursor)) } }
		try resp.throwIfError()

		// LOB · JSON · VECTOR 열은 정의(define) 없이는 위치만 온다 → 글자 · 바이트로 받게 정의하고 처음부터 다시 실행한다
		if isQuery && cursor != 0 && resp.columns.contains(where: \.needsDefine) {
			resp.defined = true
			resp.columns.forEach { $0.applyDefine() }
			resp.rows.removeAll()
			try sendExecute(sql: sqlBytes, kind: kind, cursor: cursor, defines: resp.columns)
			try readResponse(resp)
			try resp.throwIfError()
		}

		// 남은 행을 받아 온다 (ORA-01403 "더 없음" 이 올 때까지)
		var moreRows = isQuery && resp.errorNumber == 0 && cursor != 0
		while moreRows {
			var f = OracleWriter()
			writePiggybacks(&f)
			writeFunctionCode(&f, TNS.funcFetch)
			f.ub4(UInt32(cursor))
			f.ub4(fetchSize)
			try sendData(f.data)
			resp.errorNumber = 0
			resp.errorMessage = nil
			try readResponse(resp)
			try resp.throwIfError()
			moreRows = resp.errorNumber == 0
		}

		var result = QueryResult()
		result.columns = resp.columns.map(\.column)
		result.rows = resp.rows
		if !isQuery { result.affectedRows = resp.rowCount }
		return result
	}

	/// 실행 요청. cursor 가 0 이면 SQL 을 새로 파싱하고, defines 가 있으면 그 커서의 열을 정의해서 다시 실행한다
	private func sendExecute(sql sqlBytes: [UInt8], kind: StatementKind, cursor: UInt16, defines: [ColumnInfo]?) throws {
		let isQuery = kind == .query
		let parse = cursor == 0
		var options: UInt32 = TNS.execExecute
		var dmlOptions: UInt32 = TNS.execImplicitResultSet
		if parse { options |= TNS.execParse }
		if defines != nil { options |= TNS.execDefine }
		let iterations: UInt32 = isQuery ? fetchSize : 1
		if isQuery { options |= TNS.execFetch }
		if kind != .plsql { options |= TNS.execNotPLSQL }
		// iSQL 은 MySQL 처럼 문장마다 바로 반영한다 (자동 커밋)
		if !isQuery { options |= TNS.execCommit }
		if sqlBytes.isEmpty { dmlOptions = 0 }

		var w = OracleWriter()
		writePiggybacks(&w)
		writeFunctionCode(&w, TNS.funcExecute)
		w.ub4(options)
		w.ub4(UInt32(cursor))      // 커서 번호 (0 = 새로)
		if parse {
			w.u8(1)                // pointer (sql)
			w.ub4(UInt32(sqlBytes.count))
		} else {
			w.u8(0); w.ub4(0)
		}
		w.u8(1)                    // pointer (vector)
		w.ub4(13)                  // al8i4 배열 길이
		w.u8(0); w.u8(0)           // pointer (al8o4, al8o4l)
		w.ub4(0)                   // prefetch buffer size
		w.ub4(iterations)          // prefetch 행 수
		w.ub4(TNS.maxLongLength)   // LONG 최대 길이
		w.u8(0); w.ub4(0)          // 바인드 없음
		w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u8(0)   // al8app, al8txn, al8txl, al8kv, al8kvl
		if let defines {
			w.u8(1); w.ub4(UInt32(defines.count))      // 정의할 열 수
		} else {
			w.u8(0); w.ub4(0)
		}
		w.ub4(0)                   // registration id
		w.u8(0); w.u8(1)           // al8objlist, al8objlen
		w.u8(0); w.ub4(0)          // al8blv
		w.u8(0); w.ub4(0)          // al8dnam
		w.ub4(0)                   // al8regid_msb
		w.u8(0); w.ub4(0); w.u8(0) // DML 행 수 배열 없음
		if fieldVersion >= TNS.fieldVersion12_2 {
			w.u8(0); w.ub4(0)      // SQL 서명
			w.u8(0); w.ub4(0); w.u8(0)   // SQL ID
			if fieldVersion >= TNS.fieldVersion12_2Ext1 { w.u8(0); w.ub4(0) }   // chunk ids
		}
		if parse {
			w.bytesWithLength(sqlBytes)
			w.ub4(1)               // al8i4[0] parse
		} else {
			w.ub4(0)
		}
		w.ub4(isQuery ? (parse ? 0 : iterations) : 1)   // al8i4[1] 실행 횟수
		w.ub4(0); w.ub4(0); w.ub4(0)   // [2] [3] [4]
		w.ub4(0); w.ub4(0)         // [5] [6] SCN
		w.ub4(isQuery ? 1 : 0)     // [7] 조회인지
		w.ub4(0)                   // [8]
		w.ub4(dmlOptions)          // [9]
		w.ub4(0); w.ub4(0); w.ub4(0)   // [10] [11] [12]
		if let defines {
			for c in defines {
				w.u8(c.defineType)
				w.u8(0x01)         // 표시자(indicator) 사용
				w.u8(0); w.u8(0)   // precision · scale 은 늘 0
				w.ub4(c.defineBufferSize(maxString: maxStringSize))
				w.ub4(0)           // 최대 배열 원소 수
				w.ub(0)            // cont flag
				w.ub4(0)           // OID
				w.ub(0)            // version
				w.ub(c.csfrm != 0 ? UInt64(TNS.charsetUTF8) : 0)
				w.u8(c.csfrm)
				w.ub4(0)           // LOB 미리 받기 길이
				if fieldVersion >= TNS.fieldVersion12_2 { w.ub4(0) }   // oaccolid
			}
		}
		try sendData(w.data)
	}

	/// 다 쓴 커서 닫기를 요청 앞에 얹는다
	private func writePiggybacks(_ w: inout OracleWriter) {
		guard !cursorsToClose.isEmpty else { return }
		w.u8(TNS.msgPiggyback)
		w.u8(TNS.funcCloseCursors)
		w.u8(nextSeq())
		if fieldVersion >= TNS.fieldVersion23_1Ext1 { w.ub(0) }
		w.u8(1)
		w.ub4(UInt32(cursorsToClose.count))
		for c in cursorsToClose { w.ub4(c) }
		cursorsToClose.removeAll()
	}

	private func writeFunctionCode(_ w: inout OracleWriter, _ code: UInt8) {
		w.u8(TNS.msgFunction)
		w.u8(code)
		w.u8(nextSeq())
		if fieldVersion >= TNS.fieldVersion23_1Ext1 { w.ub(0) }   // token number
	}

	private func nextSeq() -> UInt8 {
		seq &+= 1
		if seq == 0 { seq = 1 }
		return seq
	}

	// MARK: - 응답 읽기

	/// 응답 하나를 읽는 동안 모은 것
	private final class ColumnInfo {
		var name = ""
		var type: UInt8 = 0
		var csfrm: UInt8 = 0
		var precision: Int8 = 0
		var scale: Int8 = 0
		var bufferSize: UInt32 = 0
		var maxSize: UInt32 = 0
		var nullable = true
		/// 행을 읽을 때 쓰는 형식 (정의하면 CLOB → LONG 처럼 바뀐다)
		var fetchType: UInt8 = 0

		/// 정의 없이는 내용이 오지 않는 열
		var needsDefine: Bool { [TNS.typeCLOB, TNS.typeBLOB, TNS.typeJSON, TNS.typeVector].contains(type) }

		/// 정의할 때 서버에 알리는 형식 (python-oracledb fetch_lobs=False 와 같게)
		var defineType: UInt8 {
			switch type {
			case TNS.typeCLOB, TNS.typeVector: TNS.typeLong
			case TNS.typeBLOB: TNS.typeLongRaw
			case TNS.typeJSON, TNS.typeRowID, TNS.typeURowID: TNS.typeVarchar   // JSON 은 VARCHAR 로 정의해도 LONG 으로 온다
			default: type
			}
		}

		func defineBufferSize(maxString: UInt32) -> UInt32 {
			switch type {
			case TNS.typeRowID, TNS.typeURowID: 5267
			case TNS.typeJSON: maxString
			case TNS.typeCLOB, TNS.typeBLOB, TNS.typeVector: TNS.maxLongLength
			default: bufferSize
			}
		}

		func applyDefine() {
			switch type {
			case TNS.typeCLOB, TNS.typeVector, TNS.typeJSON: fetchType = TNS.typeLong
			case TNS.typeBLOB: fetchType = TNS.typeLongRaw
			case TNS.typeRowID, TNS.typeURowID: fetchType = TNS.typeVarchar
			default: break
			}
		}

		/// QueryResult 의 Column 으로. type 은 아직 MySQL 번호로 바꿔 둔다 (화면이 MySQL 번호로 숫자 · 긴 글자 · 바이트를 가린다)
		var column: Column {
			let (myType, charset): (UInt8, UInt16) = switch type {
			case TNS.typeNumber, TNS.typeBinaryInteger: (246, 33)            // DECIMAL
			case TNS.typeBinaryFloat: (4, 63)
			case TNS.typeBinaryDouble: (5, 63)
			case TNS.typeDate, TNS.typeTimestamp, TNS.typeTimestampTZ, TNS.typeTimestampLTZ: (12, 63)   // DATETIME
			case TNS.typeRaw, TNS.typeLongRaw: (253, 63)                       // VARBINARY
			case TNS.typeBLOB, TNS.typeBFILE: (252, 63)                        // BLOB
			case TNS.typeCLOB, TNS.typeLong: (252, 33)                         // TEXT
			case TNS.typeJSON: (245, 33)
			default: (253, 33)                                                // VARCHAR
			}
			return Column(name: name, orgName: name, table: "", orgTable: "", schema: "", charset: charset,
			                   length: maxSize, type: myType, flags: nullable ? 0 : 1, decimals: UInt8(bitPattern: scale))
		}
	}

	private final class Response {
		enum Phase { case protocolPhase, dataTypesPhase, auth, execute }
		let phase: Phase
		init(_ phase: Phase) { self.phase = phase }

		var params: [String: String] = [:]
		var verifierType: UInt32 = 0
		var errorNumber: UInt32 = 0
		var errorMessage: String?
		var cursorID: UInt16 = 0
		var rowCount: UInt64 = 0
		var columns: [ColumnInfo] = []
		var rows: [[Value]] = []
		var bitVector: [UInt8]?
		/// 열을 정의해서 다시 실행했는지 (그 뒤에 오는 열 정보에도 정의 형식을 다시 입힌다)
		var defined = false

		func throwIfError() throws {
			guard errorNumber != 0, errorNumber != TNS.errNoDataFound else { return }
			throw OracleError.server(code: Int(errorNumber), message: errorMessage ?? "ORA-\(String(format: "%05d", errorNumber))")
		}
	}

	/// 응답 끝까지 메시지를 읽는다. 해석하지 못하면 연결이 어긋난 것이라 끊는다
	private func readResponse(_ resp: Response) throws {
		do {
			try readMessages(resp)
		} catch let e as OracleError {
			if case .server = e { throw e }
			closeSocket()
			throw e
		} catch {
			closeSocket()
			throw error
		}
	}

	private func readMessages(_ resp: Response) throws {
		let r = OracleReader(try nextDataPayload(), more: { [unowned self] in try self.nextDataPayload() })
		while true {
			let t = try r.u8()
			switch t {
			case TNS.msgProtocol:
				try parseProtocol(r)
				return
			case TNS.msgDataTypes:
				// 서버가 받은 형식 표 (쓰지 않음)
				while true {
					if try r.u16() == 0 { break }
					if try r.u16() != 0 { try r.skip(4) }
				}
				return
			case TNS.msgError:
				try parseError(r, resp)
				if !supportsEndOfResponse { return }
			case TNS.msgStatus:
				_ = try r.ub4()            // call status
				_ = try r.ub2()            // end to end seq#
				if !supportsEndOfResponse { return }
			case TNS.msgParameter:
				if resp.phase == .auth { try parseAuthParameters(r, resp) } else { try parseQueryParameters(r) }
			case TNS.msgServerPiggyback:
				try parseServerPiggyback(r)
			case TNS.msgWarning:
				let num = try r.ub2()
				let len = try r.ub2()
				try r.skipUB()             // flags
				if num != 0 && len > 0 { _ = try r.string() }
			case TNS.msgToken:
				_ = try r.ub()
			case TNS.msgEndOfResponse:
				return
			case TNS.msgDescribeInfo:
				try r.skipBytesWithLength()
				resp.columns = try parseDescribeInfo(r)
				if resp.defined { resp.columns.forEach { $0.applyDefine() } }
			case TNS.msgRowHeader:
				try parseRowHeader(r, resp)
			case TNS.msgRowData:
				try parseRowData(r, resp)
			case TNS.msgBitVector:
				_ = try r.ub2()            // 보낸 열 수
				let n = (resp.columns.count + 7) / 8
				resp.bitVector = try r.bytes(n)
			case TNS.msgIOVector:
				try r.skip(1)              // flag
				_ = try r.ub2()            // requests
				_ = try r.ub4()            // iteration
				try r.skipUB()             // iterations this time
				try r.skipUB()             // uac buffer length
				let bv = Int(try r.ub2()); try r.skip(bv)
				let rid = Int(try r.ub2()); try r.skip(rid)
				// 바인드가 없으니 바인드 방향은 없다
			case TNS.msgFlushOutBinds:
				return
			case TNS.msgImplicitResultSet:
				throw OracleError.protocolError("암시적 결과 집합(DBMS_SQL.RETURN_RESULT)은 아직 지원하지 않습니다.")
			default:
				throw OracleError.protocolError("모르는 메시지가 왔습니다 (\(t)).")
			}
		}
	}

	private func parseProtocol(_ r: OracleReader) throws {
		_ = try r.u8()                 // 서버 프로토콜 버전
		try r.skip(1)
		_ = try r.nulTerminated()      // 서버 배너
		_ = try r.u16le()              // 문자셋
		try r.skip(1)                  // 서버 플래그
		let elements = Int(try r.u16le())
		try r.skip(elements * 5)
		let fdoLength = Int(try r.u16())
		let fdo = try r.bytes(fdoLength)
		if fdo.count >= 7 {
			let ix = 6 + Int(fdo[5]) + Int(fdo[6])
			if fdo.count >= ix + 5 { nCharsetID = UInt16(fdo[ix + 3]) << 8 | UInt16(fdo[ix + 4]) }
		}
		if let server = try r.bytesWithLength(), server.count > 7 {
			if Int(server[7]) < fieldVersion {
				fieldVersion = Int(server[7])
				compileCaps[7] = server[7]
			}
		}
		if fieldVersion < TNS.fieldVersion23_4 && supportsEndOfResponse {
			compileCaps[40] &= ~0x20
			supportsEndOfResponse = false
		}
		if let rt = try r.bytesWithLength(), rt.count > 6 {   // 서버 실행 기능: 32K 문자열
			maxStringSize = rt[6] & 0x04 != 0 ? 32767 : 4000
		}
	}

	private func parseError(_ r: OracleReader, _ resp: Response) throws {
		_ = try r.ub4()                // end of call status
		try r.skipUB()                 // end to end seq#
		try r.skipUB()                 // current row number
		try r.skipUB()                 // error number
		try r.skipUB()                 // array elem error
		try r.skipUB()                 // array elem error
		resp.cursorID = try r.ub2()
		_ = try r.sb()                 // error position
		try r.skip(5)                  // sql type, fatal, flags, user cursor options, UPI parameter
		try r.skip(1)                  // warning flags
		_ = try r.ub4(); _ = try r.ub2(); try r.skip(1); _ = try r.ub4(); _ = try r.ub2()   // rowid
		try r.skipUB()                 // OS error
		try r.skip(1); try r.skip(1)   // statement number, call number
		try r.skipUB()                 // padding
		try r.skipUB()                 // success iters
		if try r.ub4() > 0 { try r.skipBytesWithLength() }   // oerrdd (logical rowid)

		// batch 오류 (배열 실행. 내용은 쓰지 않고 건너뛴다)
		let numErrors = Int(try r.ub2())
		if numErrors > 0 {
			let first = try r.u8()
			for _ in 0..<numErrors {
				if first == TNS.longLengthIndicator { try r.skipUB() }
				_ = try r.ub2()
			}
			if first == TNS.longLengthIndicator { try r.skip(1) }
		}
		let numOffsets = Int(try r.ub4())
		if numOffsets > 0 {
			let first = try r.u8()
			for _ in 0..<numOffsets {
				if first == TNS.longLengthIndicator { try r.skipUB() }
				_ = try r.ub4()
			}
			if first == TNS.longLengthIndicator { try r.skip(1) }
		}
		let numMessages = Int(try r.ub2())
		if numMessages > 0 {
			try r.skip(1)
			for _ in 0..<numMessages {
				try r.skipUB()
				_ = try r.string()
				try r.skip(2)
			}
		}

		resp.errorNumber = try r.ub4()
		resp.rowCount = try r.ub()
		if fieldVersion >= TNS.fieldVersion20_1 {
			try r.skipUB()             // sql type
			try r.skipUB()             // server checksum
		}
		if resp.errorNumber != 0 {
			resp.errorMessage = try r.string()?.trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}

	private func parseAuthParameters(_ r: OracleReader, _ resp: Response) throws {
		let n = Int(try r.ub2())
		for _ in 0..<n {
			let key = try r.stringWithLength() ?? ""
			let value = try r.stringWithLength() ?? ""
			if key == "AUTH_VFR_DATA" { resp.verifierType = try r.ub4() } else { try r.skipUB() }
			resp.params[key] = value
		}
	}

	private func parseQueryParameters(_ r: OracleReader) throws {
		let n = Int(try r.ub2())                     // al8o4l
		for _ in 0..<n { try r.skipUB() }
		let txl = Int(try r.ub2()); try r.skip(txl)  // al8txl
		try parseKeywordPairs(r, Int(try r.ub2()))
		let reg = Int(try r.ub2()); try r.skip(reg)  // registration
	}

	private func parseKeywordPairs(_ r: OracleReader, _ n: Int) throws {
		for _ in 0..<n {
			if try r.ub2() > 0 { _ = try r.string() }          // 글자 값
			if try r.ub2() > 0 { try r.skipBytesWithLength() } // 바이트 값
			_ = try r.ub2()                                     // 키워드 번호
		}
	}

	private func parseServerPiggyback(_ r: OracleReader) throws {
		let op = try r.u8()
		switch op {
		case 1, 3: break                                         // query cache invalidation, trace event
		case 2: _ = try r.ub2(); try r.skipBytesWithLength()     // OS pid (MTS)
		case 4:                                                  // session return
			try r.skipUB(); try r.skip(1)
			let n = Int(try r.ub2())
			if n > 0 {
				try r.skip(1)
				for _ in 0..<n {
					if try r.ub2() > 0 { try r.skipBytesWithLength() }
					if try r.ub2() > 0 { try r.skipBytesWithLength() }
					try r.skipUB()
				}
			}
			_ = try r.ub4()                                      // session flags
			_ = try r.ub4()                                      // session id
			_ = try r.ub2()                                      // serial
		case 5:                                                  // sync
			try r.skipUB(); try r.skip(1)
			let n = Int(try r.ub2())
			try r.skip(1)
			try parseKeywordPairs(r, n)
			try r.skipUB()
		case 7:                                                  // LTXID
			if try r.ub4() > 0 { try r.skipBytesWithLength() }
		case 8:                                                  // AC replay context
			try r.skipUB(); try r.skip(1); try r.skipUB(); try r.skipUB(); try r.skip(1)
			if try r.ub4() > 0 { try r.skipBytesWithLength() }
		case 9:                                                  // ext sync
			try r.skipUB(); try r.skip(1)
		case 10:                                                 // session signature
			try r.skipUB(); try r.skip(1); try r.skipUB(); try r.skipUB(); try r.skipUB()
		default:
			throw OracleError.protocolError("모르는 서버 알림입니다 (\(op)).")
		}
	}

	private func parseDescribeInfo(_ r: OracleReader) throws -> [ColumnInfo] {
		try r.skipUB()                                 // 최대 행 크기
		let count = Int(try r.ub4())
		if count > 0 { try r.skip(1) }
		var cols = [ColumnInfo]()
		cols.reserveCapacity(count)
		for _ in 0..<count {
			let c = ColumnInfo()
			c.type = try r.u8()
			c.fetchType = c.type
			try r.skip(1)                              // flags
			c.precision = Int8(bitPattern: try r.u8())
			c.scale = Int8(bitPattern: try r.u8())
			c.bufferSize = try r.ub4()
			try r.skipUB()                             // 최대 배열 원소 수
			try r.skipUB()                             // cont flags
			if try r.ub4() > 0 { try r.skipBytesWithLength() }   // OID
			try r.skipUB()                             // version
			try r.skipUB()                             // charset id
			c.csfrm = try r.u8()
			c.maxSize = try r.ub4()
			if c.type == TNS.typeRaw { c.maxSize = c.bufferSize }
			if fieldVersion >= TNS.fieldVersion12_2 { try r.skipUB() }   // oaccolid
			c.nullable = try r.u8() != 0
			try r.skip(1)                              // v7 이름 길이
			c.name = try r.stringWithLength() ?? ""
			try r.skipStringWithLength()               // 형식 스키마
			try r.skipStringWithLength()               // 형식 이름
			try r.skipUB()                             // 열 위치
			try r.skipUB()                             // uds flags
			if fieldVersion >= TNS.fieldVersion23_1 {
				try r.skipStringWithLength()           // domain schema
				try r.skipStringWithLength()           // domain name
			}
			if fieldVersion >= TNS.fieldVersion23_1Ext3 {
				if try r.ub4() > 0 {                   // annotations
					try r.skip(1)
					let n = Int(try r.ub4())
					try r.skip(1)
					for _ in 0..<n {
						try r.skipStringWithLength()
						try r.skipStringWithLength()
						try r.skipUB()
					}
					try r.skipUB()
				}
			}
			if fieldVersion >= TNS.fieldVersion23_4 {
				try r.skipUB()                         // vector dimensions
				try r.skip(1)                          // vector format
				try r.skip(1)                          // vector flags
			}
			cols.append(c)
		}
		if try r.ub4() > 0 { try r.skipBytesWithLength() }   // current date
		try r.skipUB(); try r.skipUB(); try r.skipUB(); try r.skipUB()   // dcbflag, dcbmdbz, dcbmnpr, dcbmxpr
		if try r.ub4() > 0 { try r.skipBytesWithLength() }   // dcbqcky
		return cols
	}

	private func parseRowHeader(_ r: OracleReader, _ resp: Response) throws {
		try r.skip(1)                  // flags
		try r.skipUB()                 // requests
		try r.skipUB()                 // iteration number
		try r.skipUB()                 // iterations
		try r.skipUB()                 // buffer length
		let n = Int(try r.ub4())
		if n > 0 {
			try r.skip(1)              // 반복된 길이
			resp.bitVector = try r.bytes(n)
		}
		if try r.ub4() > 0 { try r.skipBytesWithLength() }   // rxhrid
	}

	private func parseRowData(_ r: OracleReader, _ resp: Response) throws {
		var row = [Value]()
		row.reserveCapacity(resp.columns.count)
		let previous = resp.rows.last
		for (i, c) in resp.columns.enumerated() {
			// bit vector 에서 꺼진 열은 앞 행과 같은 값이라 보내지 않는다
			if let bv = resp.bitVector, i / 8 < bv.count, bv[i / 8] & (1 << (i % 8)) == 0, let previous {
				row.append(previous[i])
			} else {
				row.append(try readColumn(r, c))
			}
		}
		resp.bitVector = nil
		resp.rows.append(row)
	}

	private func readColumn(_ r: OracleReader, _ c: ColumnInfo) throws -> Value {
		let t = c.fetchType
		if c.bufferSize == 0 && t != TNS.typeLong && t != TNS.typeLongRaw && t != TNS.typeURowID { return .null }
		var value: Value
		switch t {
		case TNS.typeVarchar, TNS.typeChar, TNS.typeLong:
			if let b = try r.bytesWithLength() {
				if c.csfrm == TNS.csNChar && nCharsetID == TNS.charsetUTF16 {
					value = .text(String(data: Data(b), encoding: .utf16BigEndian) ?? "")
				} else {
					value = .text(String(decoding: b, as: UTF8.self))
				}
			} else { value = .null }
		case TNS.typeRaw, TNS.typeLongRaw:
			value = try r.bytesWithLength().map { .bytes(Data($0)) } ?? .null
		case TNS.typeNumber, TNS.typeBinaryInteger:
			value = try Self.decoded(r.bytesWithLength(), OracleValues.number)
		case TNS.typeDate, TNS.typeTimestamp, TNS.typeTimestampTZ, TNS.typeTimestampLTZ:
			value = try Self.decoded(r.bytesWithLength()) { OracleValues.dateTime($0, type: t) }
		case TNS.typeBinaryFloat:
			value = try Self.decoded(r.bytesWithLength(), OracleValues.binaryFloat)
		case TNS.typeBinaryDouble:
			value = try Self.decoded(r.bytesWithLength(), OracleValues.binaryDouble)
		case TNS.typeIntervalDS:
			value = try Self.decoded(r.bytesWithLength(), OracleValues.intervalDS)
		case TNS.typeIntervalYM:
			value = try Self.decoded(r.bytesWithLength(), OracleValues.intervalYM)
		case TNS.typeBoolean:
			value = try r.bytesWithLength().map { .text($0.last == 1 ? "TRUE" : "FALSE") } ?? .null
		case TNS.typeRowID:
			let len = try r.u8()
			if len == 0 || len == TNS.nullLengthIndicator {
				value = .null
			} else {
				let rba = try r.ub4(), part = try r.ub2()
				try r.skip(1)
				let block = try r.ub4(), slot = try r.ub2()
				value = OracleValues.rowID(rba: rba, partition: part, block: block, slot: slot).map { .text($0) } ?? .null
			}
		case TNS.typeURowID:
			if try r.bytesWithLength() == nil {
				value = .null
			} else {
				let d = try r.bytesWithLength() ?? []
				if d.count >= 13 && d[0] == 1 {
					func u32(_ o: Int) -> UInt32 { UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3]) }
					let s = OracleValues.rowID(rba: u32(1), partition: UInt16(d[5]) << 8 | UInt16(d[6]),
					                           block: u32(7), slot: UInt16(d[11]) << 8 | UInt16(d[12]))
					value = s.map { .text($0) } ?? .null
				} else {
					value = .text("*" + Data(d.dropFirst()).base64EncodedString().replacingOccurrences(of: "=", with: ""))
				}
			}
		case TNS.typeCLOB, TNS.typeBLOB, TNS.typeBFILE:
			// 정의하지 않은 LOB 은 위치(locator)만 온다 (첫 실행 응답. 이 행은 버리고 정의해서 다시 실행한다).
			// BFILE 은 정의하지 않으므로 그대로 위치만 보여 준다
			if try r.ub4() > 0 {
				_ = try r.bytesWithLength()
				value = .text(t == TNS.typeBFILE ? "(BFILE)" : "(LOB)")
			} else { value = .null }
		case TNS.typeJSON, TNS.typeVector:
			// 정의하지 않은 JSON · VECTOR 는 이진(OSON · 벡터) 데이터가 미리 붙어 온다 (python read_oson). 이 행도 버린다
			if try r.ub4() > 0 {
				try r.skipUB()             // size
				try r.skipUB()             // chunk size
				_ = try r.bytesWithLength()
				_ = try r.bytesWithLength() // locator
				value = .text("(\(t == TNS.typeJSON ? "JSON" : "VECTOR"))")
			} else { value = .null }
		case TNS.typeCursor:
			try r.skip(1)
			_ = try parseDescribeInfo(r)
			let id = try r.ub2()
			if id != 0 { cursorsToClose.append(UInt32(id)) }
			value = .text("(커서)")
		case TNS.typeObject:
			if try r.ub4() > 0 { try r.skipBytesWithLength() }   // type oid
			if try r.ub4() > 0 { try r.skipBytesWithLength() }   // oid
			if try r.ub4() > 0 { try r.skipBytesWithLength() }   // snapshot
			try r.skipUB()                                       // version
			let len = try r.ub4()
			try r.skipUB()                                       // flags
			if len > 0 { try r.skipBytesWithLength() }
			value = .text("(객체)")
		default:
			throw OracleError.protocolError("아직 읽을 수 없는 열 형식입니다 (\(c.name): 형식 \(t)).")
		}
		if t == TNS.typeLong || t == TNS.typeLongRaw {
			try r.skipUB()             // null indicator
			try r.skipUB()             // return code
		}
		return value
	}

	/// 값 바이트를 글자로. 풀지 못하면 16진수로 보여 준다 (앱이 죽지 않게)
	private static func decoded(_ b: [UInt8]?, _ f: ([UInt8]) -> String?) -> Value {
		guard let b else { return .null }
		return f(b).map { .text($0) } ?? .text("0x" + OracleAuth.hexString(b))
	}

	// MARK: - 패킷

	private func sendConnect(_ connectString: String) throws {
		let cs = Array(connectString.utf8)
		var w = OracleWriter()
		w.u16(TNS.versionDesired)
		w.u16(TNS.versionMinimum)
		w.u16(TNS.gsoDontCare)
		w.u16(UInt16(TNS.sdu))
		w.u16(UInt16(TNS.sdu))
		w.u16(TNS.protocolCharacteristics)
		w.u16(0)                       // line turnaround
		w.u16(1)                       // value of 1
		w.u16(UInt16(cs.count))
		w.u16(74)                      // 접속 글자까지의 거리
		w.u32(0)                       // max receivable data
		let nsi = TNS.nsiSupportSecurityReneg | TNS.nsiDisableNA
		w.u8(nsi); w.u8(nsi)
		w.u64(0); w.u64(0); w.u64(0)
		w.u32(TNS.sdu); w.u32(TNS.sdu)
		w.u32(0)                       // connect flags 1
		w.u32(0)                       // connect flags 2 (OOB 확인 안 함)
		if cs.count > TNS.maxConnectData {
			try writePacket(type: TNS.packetConnect, w.data)
			try writePacket(type: TNS.packetData, [0, 0] + cs)
		} else {
			try writePacket(type: TNS.packetConnect, w.data + cs)
		}
	}

	private func parseAccept(_ p: [UInt8]) throws {
		guard p.count >= 28 else { throw OracleError.protocolError("접속 응답이 짧습니다.") }
		func u16(_ o: Int) -> UInt16 { UInt16(p[o]) << 8 | UInt16(p[o + 1]) }
		func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) }
		let version = u16(0)
		guard version >= TNS.versionMinAccepted else {
			throw OracleError.refused("Oracle 12.1 이상만 접속할 수 있습니다 (서버 프로토콜 \(version)).")
		}
		sdu = Int(min(u32(24), TNS.sdu * 8))
		if sdu < 512 { sdu = Int(TNS.sdu) }
		var flags: UInt32 = 0
		if version >= TNS.versionMinOOBCheck && p.count >= 37 { flags = u32(33) }
		largeSDU = version >= TNS.versionMinLargeSDU
		if version >= TNS.versionMinEndOfResponse && flags & TNS.acceptFlagHasEndOfResponse != 0 {
			compileCaps[40] |= 0x20
			supportsEndOfResponse = true
		}
	}

	/// 메시지를 데이터 패킷들로 나눠 보낸다 (패킷 하나는 SDU 를 넘지 않는다)
	private func sendData(_ payload: [UInt8], flags: UInt16 = 0) throws {
		let maxChunk = sdu - 10
		var off = 0
		repeat {
			let n = min(maxChunk, payload.count - off)
			try writePacket(type: TNS.packetData, [UInt8(flags >> 8), UInt8(flags & 0xFF)] + payload[off..<off + n])
			off += n
		} while off < payload.count
	}

	private func writePacket(type: UInt8, _ body: [UInt8]) throws {
		let len = body.count + 8
		var h = [UInt8]()
		if largeSDU {
			h = [UInt8(len >> 24 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)]
		} else {
			h = [UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF), 0, 0]
		}
		h += [type, 0, 0, 0]
		try writeAll(h + body)
	}

	private func readPacket() throws -> (type: UInt8, flags: UInt8, payload: [UInt8]) {
		let h = try readExactly(8)
		let len = largeSDU
			? Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
			: Int(h[0]) << 8 | Int(h[1])
		guard len >= 8 else { throw OracleError.protocolError("패킷 길이가 잘못되었습니다 (\(len)).") }
		return (h[4], h[5], try readExactly(len - 8))
	}

	/// 다음 데이터 패킷의 내용 (앞 2바이트 data flags 는 뗀다).
	/// 서버가 오류를 알리려고 break 표시를 보내면 reset 표시를 주고받은 뒤 이어지는 데이터 패킷을 돌려준다
	private func nextDataPayload() throws -> [UInt8] {
		var p = try readPacket()
		if p.type == TNS.packetMarker {
			try writePacket(type: TNS.packetMarker, [1, 0, TNS.markerReset])
			while !(p.type == TNS.packetMarker && p.payload.count >= 3 && p.payload[2] == TNS.markerReset) {
				p = try readPacket()
			}
			repeat { p = try readPacket() } while p.type == TNS.packetMarker
		}
		guard p.type == TNS.packetData else {
			if p.type == TNS.packetRefuse { throw Self.refuseError(p.payload, service: "", sid: false) }
			throw OracleError.protocolError("데이터가 아닌 패킷이 왔습니다 (\(p.type)).")
		}
		guard p.payload.count >= 2 else { return [] }
		return Array(p.payload.dropFirst(2))
	}

	private static func refuseError(_ p: [UInt8], service: String, sid: Bool) -> OracleError {
		var text = ""
		if p.count >= 4 {
			let n = Int(p[2]) << 8 | Int(p[3])
			text = String(decoding: p.dropFirst(4).prefix(n), as: UTF8.self)
		}
		let code = text.range(of: #"\(ERR=(\d+)\)"#, options: .regularExpression).map {
			String(text[$0]).filter(\.isNumber)
		} ?? ""
		switch code {
		case "12514":
			return .refused("서버(리스너)가 서비스 이름 \(service) 을 모릅니다 (ORA-12514). 서비스 이름을 확인하세요.")
		case "12505":
			return .refused("서버(리스너)가 SID \(service) 를 모릅니다 (ORA-12505). SID 대신 서비스 이름으로 접속해 보세요.")
		case "":
			return .refused("서버가 접속을 거절했습니다. \(text)")
		default:
			return .refused("서버가 접속을 거절했습니다 (ORA-\(code)).")
		}
	}

	// MARK: - 소켓

	private func readExactly(_ n: Int) throws -> [UInt8] {
		while readBuffer.count - readPos < n {
			if readPos > 0 { readBuffer.removeFirst(readPos); readPos = 0 }
			var chunk = [UInt8](repeating: 0, count: max(65536, n))
			let got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
			if got <= 0 {
				let timedOut = got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
				closeSocket()
				if timedOut { throw OracleError.io("서버가 답하지 않습니다.") }
				throw got == 0 ? OracleError.closed : OracleError.io(String(cString: strerror(errno)))
			}
			readBuffer += chunk[0..<got]
		}
		let out = Array(readBuffer[readPos..<readPos + n])
		readPos += n
		return out
	}

	private func writeAll(_ bytes: [UInt8]) throws {
		guard fd >= 0 else { throw OracleError.closed }
		var off = 0
		while off < bytes.count {
			let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
			if n <= 0 { closeSocket(); throw OracleError.io(String(cString: strerror(errno))) }
			off += n
		}
	}

	private func setReadTimeout(_ seconds: Int) {
		guard fd >= 0 else { return }
		var tv = timeval(tv_sec: seconds, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
	}

	/// 로그오프를 알리고 끊는다
	private func closeSync() {
		guard fd >= 0 else { return }
		setReadTimeout(3)
		var w = OracleWriter()
		writePiggybacks(&w)
		writeFunctionCode(&w, TNS.funcLogoff)
		if (try? sendData(w.data)) != nil {
			try? readMessages(Response(.execute))
		}
		if fd >= 0 { try? sendData([], flags: TNS.dataFlagsEOF) }
		closeSocket()
	}

	private func closeSocket() {
		guard fd >= 0 else { return }
		Darwin.close(fd)
		fd = -1
		readBuffer.removeAll()
		readPos = 0
	}

	private static func openSocket(host: String, port: Int) throws -> Int32 {
		var hints = addrinfo()
		hints.ai_family = AF_UNSPEC
		hints.ai_socktype = SOCK_STREAM
		var res: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
			throw OracleError.io("\(host) 주소를 찾지 못했습니다.")
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
		throw OracleError.io("\(host):\(port) 에 접속하지 못했습니다 (\(lastError)).")
	}

	// MARK: - 기본값

	private static var machineName: String { ProcessInfo.processInfo.hostName }

	/// 접속 글자의 ( ) = 는 구조를 깨므로 바꾼다
	private static func sanitize(_ s: String) -> String {
		String(s.map { "()=".contains($0) ? "?" : $0 })
	}

	/// 클라이언트가 할 수 있는 것 (python-oracledb capabilities.pyx 와 같은 값)
	private static func defaultCompileCaps() -> [UInt8] {
		var c = [UInt8](repeating: 0, count: 53)
		c[0] = 6                               // SQL version
		c[4] = 8 | 2 | 32 | 64 | 0x80          // logon types: O5LOGON, O5LOGON_NP, O7LOGON, O8 long identifier, O9 long password
		c[5] = 0x08 | 0x10                     // feature backport
		c[7] = TNS.fieldVersionMax             // field version
		c[8] = 1                               // server define conv
		c[15] = 0x20 | 0x01 | 0x08             // TTC1: fast bvec, end of call status, ind rcd
		c[16] = 0x10 | 0x80                    // OCI1: fast session propagate, app ctx piggyback
		c[17] = 3                              // TDS version
		c[18] = 7                              // RPC version
		c[19] = 3                              // RPC sig
		c[21] = 1                              // DBF version
		c[23] = 0x01 | 0x02 | 0x40 | 0x08 | 0x80 | 0x04   // LOB
		c[27] = 1                              // UB2 DTY
		c[42] = 0x01 | 0x04                    // LOB2
		c[37] = 0x10 | 0x20 | 0x80             // TTC3: implicit results, big chunk clr, keep out order
		c[26] = 0x04                           // TTC2: ZLNP
		c[31] = 0x10                           // OCI2: DRCP
		c[34] = 12                             // client fn max
		c[40] = 0x04                           // TTC4: inband notification
		c[44] = 0x08                           // TTC5: vector support
		c[52] = 0x01                           // vector features: binary
		return c
	}

	private static func defaultRuntimeCaps() -> [UInt8] {
		var c = [UInt8](repeating: 0, count: 11)
		c[0] = 2                               // compat 8.1
		c[6] = 0x01 | 0x04                     // TTC: zero copy, 32K
		return c
	}
}

