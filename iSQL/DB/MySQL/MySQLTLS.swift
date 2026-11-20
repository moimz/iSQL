import Foundation
import Darwin
import Security

/// MySQL 연결의 TLS (SSH 없이 바로 붙는 서버: RDS 등).
/// MySQL 은 평문으로 첫 인사(handshake)를 받은 뒤 SSLRequest 를 보내고 같은 소켓에서 TLS 로 바꾼다.
/// Network.framework 는 열린 소켓 중간에 TLS 를 얹을 수 없어서, 맥에 들어 있는 SecureTransport 를 쓴다
/// (애플이 더 고치지 않는다고 표시했지만 동작한다. TLS 1.2 까지 — MySQL 8·MariaDB·RDS 모두 1.2 를 받는다).
/// 외부 라이브러리를 넣지 않는다는 원칙 때문 (2026-11-19)
final class MySQLTLS {
	private let ctx: SSLContext
	/// SecureTransport 콜백이 받을 소켓 번호 (콜백은 값을 잡을 수 없는 C 함수라 포인터로 넘긴다)
	private let fdBox: UnsafeMutablePointer<Int32>

	/// 손잡기(handshake)를 끝낸 TLS. verify: 인증서 사슬 + 호스트 이름 확인, caPath: 그 CA 로 확인 (비면 맥이 믿는 인증서)
	init(fd: Int32, host: String, verify: Bool, caPath: String) throws {
		guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { throw MySQLError.tls("TLS 를 준비하지 못했습니다.") }
		ctx = c
		fdBox = .allocate(capacity: 1)
		fdBox.initialize(to: fd)
		SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
		SSLSetConnection(ctx, UnsafeRawPointer(fdBox))
		SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
		// 이름(SNI)은 IP 가 아닐 때만 보낸다
		if !host.isEmpty && !Self.isIPAddress(host) { SSLSetPeerDomainName(ctx, host, host.utf8.count) }
		// 서버 인증서 확인은 직접 한다 (끄면 확인하지 않고, 켜면 사슬 + 이름)
		SSLSetSessionOption(ctx, .breakOnServerAuth, true)
		while true {
			let st = SSLHandshake(ctx)
			if st == noErr { break }
			if st == errSSLPeerAuthCompleted {
				if verify { try Self.checkTrust(ctx, host: host, caPath: caPath) }
				continue
			}
			if st == errSSLWouldBlock { continue }
			throw MySQLError.tls(Self.describe(st))
		}
	}

	deinit { fdBox.deallocate() }

	/// 협상된 TLS 버전·암호 (상태 표시용)
	var summary: String {
		var p = SSLProtocol.sslProtocolUnknown
		SSLGetNegotiatedProtocolVersion(ctx, &p)
		let v: String = switch p {
		case .tlsProtocol12: "TLS 1.2"
		case .tlsProtocol11: "TLS 1.1"
		case .tlsProtocol1: "TLS 1.0"
		default: "TLS"
		}
		return v
	}

	/// 풀린 글자를 읽는다. 0 = 상대가 닫음
	func read(_ buf: UnsafeMutableRawPointer, _ len: Int) throws -> Int {
		var got = 0
		let st = SSLRead(ctx, buf, len, &got)
		if got > 0 { return got }
		if st == errSSLClosedGraceful || st == errSSLClosedNoNotify { return 0 }
		if st != noErr && st != errSSLWouldBlock { throw MySQLError.tls(Self.describe(st)) }
		return got
	}

	func write(_ buf: UnsafeRawPointer, _ len: Int) throws -> Int {
		var done = 0
		let st = SSLWrite(ctx, buf, len, &done)
		if st != noErr && done == 0 { throw MySQLError.tls(Self.describe(st)) }
		return done
	}

	func close() { SSLClose(ctx) }

	// MARK: 인증서 확인

	static func checkTrust(_ ctx: SSLContext, host: String, caPath: String) throws {
		var trustRef: SecTrust?
		guard SSLCopyPeerTrust(ctx, &trustRef) == noErr, let trust = trustRef else { throw MySQLError.tls("서버 인증서를 받지 못했습니다.") }
		SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
		if !caPath.isEmpty {
			let path = (caPath as NSString).expandingTildeInPath
			guard let data = FileManager.default.contents(atPath: path) else { throw MySQLError.tls("CA 파일을 읽지 못했습니다: \(caPath)") }
			let certs = pemCertificates(data)
			guard !certs.isEmpty else { throw MySQLError.tls("CA 파일에 인증서가 없습니다: \(caPath)") }
			SecTrustSetAnchorCertificates(trust, certs as CFArray)
			// 고른 CA 만 믿는다 (맥이 믿는 인증서는 쓰지 않음)
			SecTrustSetAnchorCertificatesOnly(trust, true)
		}
		var err: CFError?
		if !SecTrustEvaluateWithError(trust, &err) {
			let why = (err as Error?)?.localizedDescription ?? ""
			throw MySQLError.tls("서버 인증서를 믿을 수 없습니다" + (why.isEmpty ? "." : ": \(why)"))
		}
	}

	/// PEM(여러 개 가능) 또는 DER 한 개
	static func pemCertificates(_ data: Data) -> [SecCertificate] {
		let text = String(decoding: data, as: UTF8.self)
		guard text.contains("-----BEGIN CERTIFICATE-----") else {
			return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
		}
		var out: [SecCertificate] = []
		for block in text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
			guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first else { continue }
			let b64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
			if let der = Data(base64Encoded: b64), let c = SecCertificateCreateWithData(nil, der as CFData) { out.append(c) }
		}
		return out
	}

	static func isIPAddress(_ s: String) -> Bool {
		var v4 = in_addr(), v6 = in6_addr()
		return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
	}

	static func describe(_ st: OSStatus) -> String {
		switch st {
		case errSSLClosedAbort, errSSLClosedGraceful: "TLS 연결 중에 서버가 끊었습니다."
		case errSSLProtocol, errSSLNegotiation, errSSLPeerProtocolVersion: "서버와 TLS 방식을 맞추지 못했습니다 (\(st))."
		case errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert, errSSLCertExpired, errSSLHostNameMismatch:
			"서버 인증서를 믿을 수 없습니다 (\(st))."
		default:
			(SecCopyErrorMessageString(st, nil) as String?).map { "TLS 오류: \($0)" } ?? "TLS 오류 (\(st))."
		}
	}
}

// SecureTransport 가 부르는 읽기·쓰기: 막히는 소켓이라 요청한 만큼 다 채운다
private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
	let fd = conn.load(as: Int32.self)
	let want = len.pointee
	var got = 0
	while got < want {
		let n = Darwin.read(fd, data + got, want - got)
		if n > 0 { got += n; continue }
		if n < 0 && errno == EINTR { continue }
		len.pointee = got
		return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort
	}
	len.pointee = got
	return noErr
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
	let fd = conn.load(as: Int32.self)
	let want = len.pointee
	var done = 0
	while done < want {
		let n = Darwin.write(fd, data + done, want - done)
		if n > 0 { done += n; continue }
		if n < 0 && errno == EINTR { continue }
		len.pointee = done
		return errSSLClosedAbort
	}
	len.pointee = done
	return noErr
}
