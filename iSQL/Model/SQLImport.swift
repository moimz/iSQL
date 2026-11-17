import Foundation
import Observation

/// .sql 파일을 조금씩 읽어 문장 하나씩 꺼낸다 (큰 덤프도 메모리에 다 올리지 않는다).
/// 따옴표·백틱 안, 주석 안의 구분자는 자르지 않고, mysql 클라이언트처럼 `DELIMITER ;;` 를 알아듣는다.
/// `/*! … */`(버전 조건 주석)·`/*+ … */`(힌트)는 실행되는 글이라 문장에 남기고, 보통 주석은 뺀다.
/// 바이트 그대로 다룬다 (덤프 안 문자열이 UTF-8 이 아닐 수도 있어서).
final class SQLDumpReader: @unchecked Sendable {
	struct Statement {
		var bytes: [UInt8]
		/// 문장이 시작한 줄 (1부터)
		var line: Int
	}

	let size: Int64
	/// 지금까지 읽은 바이트 (진행률)
	private(set) var consumed: Int64 = 0
	private(set) var line = 1

	private let handle: FileHandle
	private var buf: [UInt8] = []
	private var pos = 0
	private var eof = false
	private var delimiter: [UInt8] = [UInt8(ascii: ";")]
	private static let chunk = 1 << 20

	init(url: URL) throws {
		handle = try FileHandle(forReadingFrom: url)
		size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		// UTF-8 BOM 은 건너뛴다
		if peek(0) == 0xEF, peek(1) == 0xBB, peek(2) == 0xBF { pos = 3; consumed = 3 }
	}

	deinit { try? handle.close() }

	/// k 번째 앞 바이트 (모자라면 파일에서 더 읽는다)
	private func peek(_ k: Int) -> UInt8? {
		while pos + k >= buf.count {
			guard !eof else { return nil }
			let more = (try? handle.read(upToCount: Self.chunk)) ?? nil
			guard let more, !more.isEmpty else { eof = true; return nil }
			if pos > 0 { buf.removeSubrange(0..<pos); pos = 0 }
			buf.append(contentsOf: more)
		}
		return buf[pos + k]
	}

	@discardableResult
	private func take() -> UInt8 {
		let b = buf[pos]
		pos += 1
		consumed += 1
		if b == 0x0A { line += 1 }
		return b
	}

	private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

	private func matchesDelimiter() -> Bool {
		for (i, d) in delimiter.enumerated() where peek(i) != d { return false }
		return true
	}

	/// 문장 맨 앞의 `DELIMITER x` (대소문자 무시) 면 그 줄을 먹고 구분자를 바꾼다
	private func takeDelimiterCommand() -> Bool {
		let word = Array("DELIMITER".utf8)
		for (i, w) in word.enumerated() {
			guard let b = peek(i), b & 0xDF == w else { return false }
		}
		guard let sep = peek(word.count), sep == 0x20 || sep == 0x09 else { return false }
		for _ in 0...word.count { take() }
		var rest: [UInt8] = []
		while let b = peek(0), b != 0x0A { rest.append(take()) }
		while let l = rest.last, Self.isSpace(l) { rest.removeLast() }
		while let f = rest.first, Self.isSpace(f) { rest.removeFirst() }
		if !rest.isEmpty { delimiter = rest }
		return true
	}

	private enum State { case normal, quote(UInt8), lineComment, blockComment(keep: Bool) }

	/// 다음 문장. 파일 끝이면 nil
	func next() -> Statement? {
		var out: [UInt8] = []
		out.reserveCapacity(4096)
		var startLine = 0
		var state = State.normal
		/// 공백·주석이 아닌 글이 있었나 (없으면 문장이 아니다)
		var content: Bool { !out.isEmpty }
		func begin() { if out.isEmpty { startLine = line } }

		while let b = peek(0) {
			switch state {
			case .normal:
				if !content && (b == 0x44 || b == 0x64), takeDelimiterCommand() { continue }
				if matchesDelimiter() {
					for _ in delimiter { take() }
					if content { return Statement(bytes: out, line: startLine) }
					continue
				}
				switch b {
				case 0x27, 0x22, 0x60:   // ' " `
					begin(); out.append(take()); state = .quote(b)
				case 0x23:   // #
					take(); state = .lineComment
				case 0x2D where peek(1) == 0x2D && (peek(2).map(Self.isSpace) ?? true):   // "-- "
					take(); take(); state = .lineComment
				case 0x2F where peek(1) == 0x2A:   // /*
					let keep = peek(2) == 0x21 || peek(2) == 0x2B   // /*! 또는 /*+
					if keep { begin(); out.append(take()); out.append(take()) } else { take(); take() }
					state = .blockComment(keep: keep)
				default:
					if Self.isSpace(b) {
						let c = take()
						if content { out.append(c) }
					} else {
						begin(); out.append(take())
					}
				}
			case .quote(let q):
				let c = take()
				out.append(c)
				if c == 0x5C && q != 0x60 {   // \ 다음 글자는 그대로
					if peek(0) != nil { out.append(take()) }
				} else if c == q {
					if peek(0) == q { out.append(take()) } else { state = .normal }   // '' 는 따옴표 하나
				}
			case .lineComment:
				let c = take()
				if c == 0x0A { state = .normal; if content { out.append(0x0A) } }
			case .blockComment(let keep):
				if b == 0x2A && peek(1) == 0x2F {
					if keep { out.append(take()); out.append(take()) } else { take(); take(); if content { out.append(0x20) } }
					state = .normal
				} else {
					let c = take()
					if keep { out.append(c) }
				}
			}
		}
		return content ? Statement(bytes: out, line: startLine) : nil
	}
}

/// SQL 파일 가져오기 요청 (DB 오른쪽 클릭 → 파일 고르기 → 창이 제목바 시트로 띄운다)
struct ImportRequest: Identifiable {
	let id = UUID()
	/// 넣을 데이터베이스 (nil = 파일에 적힌 대로)
	let schema: String?
	/// 작업은 요청과 함께 만든다 (시트가 다시 그려져도 진행 상태가 남게)
	let job: SQLImportJob
}

/// SQL 파일 가져오기: 따로 연 연결에서 문장 하나씩 실행한다.
/// 가져오기 전용 연결이라 덤프의 USE·SET(FOREIGN_KEY_CHECKS, SQL_MODE, NAMES …)이 앱이 쓰는 연결에 남지 않는다.
/// 오류가 나면 그 문장에서 멈추고 줄 번호·문장을 보여 준다 → 그만두기 / 건너뛰고 계속.
@MainActor
@Observable
final class SQLImportJob {
	struct Failure {
		var line: Int
		var message: String
		/// 문장 앞부분
		var preview: String
	}

	@ObservationIgnored private weak var session: Session?
	private(set) var url: URL
	private(set) var fileSize: Int64 = 0

	private(set) var running = false
	private(set) var finished = false
	/// 오류로 멈춤 (그만두기 / 건너뛰고 계속 을 기다림)
	private(set) var failure: Failure?
	private(set) var message: String?
	private(set) var isError = false

	private(set) var bytesDone: Int64 = 0
	private(set) var statements = 0
	private(set) var skipped = 0
	private(set) var line = 0

	var fraction: Double { fileSize > 0 ? min(1, Double(bytesDone) / Double(fileSize)) : 0 }

	@ObservationIgnored private var reader: SQLDumpReader?
	@ObservationIgnored private var conn: MySQLConnection?
	@ObservationIgnored private var cancelled = false
	@ObservationIgnored private var started = Date()
	@ObservationIgnored private var lastUpdate = Date.distantPast
	@ObservationIgnored private var touched: String?

	init(url: URL, session: Session) {
		self.url = url
		self.session = session
		fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
	}

	/// 시작 전에만: 다른 파일로 바꾸기
	func change(to url: URL) {
		guard !running, !finished else { return }
		self.url = url
		fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
	}

	func start(schema: String?, disableForeignKeys: Bool) async {
		guard let session, !running, !finished else { return }
		running = true
		cancelled = false
		message = nil
		isError = false
		started = Date()
		touched = schema
		do {
			reader = try SQLDumpReader(url: url)
			let c = try await session.sideConnection(purpose: "SQL 가져오기")
			conn = c
			if disableForeignKeys { _ = try await c.query("SET FOREIGN_KEY_CHECKS = 0") }
			if let schema { _ = try await c.query("USE " + TableInspector.ident(schema)) }
		} catch {
			finish(error: error.localizedDescription)
			return
		}
		await loop()
	}

	/// 오류 난 문장을 건너뛰고 이어서
	func skipAndContinue() async {
		guard failure != nil else { return }
		failure = nil
		skipped += 1
		running = true
		await loop()
	}

	/// 멈춘 상태에서 그만두기, 또는 도는 중에 그만두기 (문장 사이에서 멈춘다)
	func cancel() {
		if running { cancelled = true; return }
		if failure != nil {
			failure = nil
			finish(error: "그만뒀습니다 (\(statements.formatted())개 실행함)")
		}
	}

	private func loop() async {
		guard let reader, let conn else { return }
		while !cancelled {
			// 문장 나누기는 메인 밖에서 (큰 파일도 화면이 멈추지 않게)
			let next = await Task.detached { reader.next() }.value
			guard let s = next else { break }
			line = s.line
			do {
				_ = try await conn.query(bytes: s.bytes)
			} catch {
				bytesDone = reader.consumed
				running = false
				failure = Failure(line: s.line, message: error.localizedDescription, preview: Self.preview(s.bytes))
				return
			}
			statements += 1
			if Date().timeIntervalSince(lastUpdate) > 0.1 {
				bytesDone = reader.consumed
				lastUpdate = Date()
			}
		}
		bytesDone = reader.consumed
		if cancelled {
			finish(error: "그만뒀습니다 (\(statements.formatted())개 실행함)")
		} else {
			let secs = Date().timeIntervalSince(started)
			var m = "문장 \(statements.formatted())개 실행 (\(secs < 10 ? String(format: "%.1f", secs) : String(Int(secs)))초)"
			if skipped > 0 { m += " · 건너뜀 \(skipped)개" }
			finish(message: m)
		}
	}

	private func finish(message m: String? = nil, error e: String? = nil) {
		running = false
		finished = true
		isError = e != nil
		message = e ?? m
		conn?.close()
		conn = nil
		reader = nil
		let schema = touched
		Task { await session?.dataImported(schema: schema) }
	}

	/// 오류 창에 보일 문장 앞부분 (공백은 한 칸으로)
	private static func preview(_ bytes: [UInt8]) -> String {
		let head = String(decoding: bytes.prefix(400), as: UTF8.self)
		let flat = head.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		return bytes.count > 400 ? flat + " …" : flat
	}
}
