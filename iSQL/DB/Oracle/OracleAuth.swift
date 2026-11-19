import Foundation
import CommonCrypto
import CryptoKit

/// Oracle 비밀번호 인증 (O5LOGON) 계산. python-oracledb auth.pyx · crypto.pyx 를 옮김.
/// AES-CBC(IV 0, 직접 덧붙임) · PBKDF2-SHA512 는 CryptoKit 에 없어서 맥에 들어 있는 CommonCrypto 를 쓴다 (외부 라이브러리 없음)
enum OracleAuth {
	struct Verifier {
		/// AUTH_SESSKEY (클라이언트 쪽 세션 키 반쪽, 16진수)
		var sessionKey: String
		/// AUTH_PBKDF2_SPEEDY_KEY (12c 검증자만)
		var speedyKey: String?
		/// AUTH_PASSWORD (암호화한 비밀번호, 16진수)
		var encodedPassword: String
		/// 서버 응답(AUTH_SVR_RESPONSE)을 확인할 키
		var comboKey: [UInt8]
	}

	/// 1단계 응답(AUTH_VFR_DATA · AUTH_SESSKEY …)과 비밀번호로 2단계에 보낼 값을 만든다
	static func verifier(password: String, params: [String: String], verifierType: UInt32) throws -> Verifier {
		let pw = Array(password.utf8)
		guard let vfr = params["AUTH_VFR_DATA"].flatMap(hex), let serverKey = params["AUTH_SESSKEY"].flatMap(hex) else {
			throw OracleError.protocolError("서버가 인증 정보를 보내지 않았습니다.")
		}
		let is12c = verifierType == TNS.verifier12c
		let keyLength = is12c ? 32 : 24
		let passwordHash: [UInt8]
		var passwordKey: [UInt8] = []
		if is12c {
			guard let n = params["AUTH_PBKDF2_VGEN_COUNT"].flatMap({ Int($0) }) else { throw OracleError.protocolError("AUTH_PBKDF2_VGEN_COUNT 가 없습니다.") }
			passwordKey = try pbkdf2(pw, salt: vfr + Array("AUTH_PBKDF2_SPEEDY_KEY".utf8), length: 64, rounds: n)
			passwordHash = Array(SHA512.hash(data: passwordKey + vfr)).prefix(32).map { $0 }
		} else {
			passwordHash = Array(Insecure.SHA1.hash(data: pw + vfr)) + [0, 0, 0, 0]
		}

		// 서버 쪽 세션 키 반쪽을 풀고, 우리 쪽 반쪽을 만들어 암호화한다
		let partA = try aesCBC(decrypt: true, key: passwordHash, serverKey)
		let partB = random(partA.count)
		let encodedClientKey = try encrypt(passwordHash, partB)

		let sessionKey: String
		let comboKey: [UInt8]
		if partA.count == 48 {
			// 11g 검증자
			sessionKey = String(hexString(encodedClientKey).prefix(96))
			var b = [UInt8](repeating: 0, count: 24)
			for i in 16..<40 { b[i - 16] = partA[i] ^ partB[i] }
			let p1 = Array(Insecure.MD5.hash(data: Array(b[0..<16])))
			let p2 = Array(Insecure.MD5.hash(data: Array(b[16...])))
			comboKey = Array((p1 + p2).prefix(keyLength))
		} else {
			sessionKey = String(hexString(encodedClientKey).prefix(64))
			guard let salt = params["AUTH_PBKDF2_CSK_SALT"].flatMap(hex), let n = params["AUTH_PBKDF2_SDER_COUNT"].flatMap({ Int($0) }) else {
				throw OracleError.protocolError("AUTH_PBKDF2_CSK_SALT 가 없습니다.")
			}
			let temp = Array(partB.prefix(keyLength)) + Array(partA.prefix(keyLength))
			comboKey = try pbkdf2(Array(hexString(temp).utf8), salt: salt, length: keyLength, rounds: n)
		}

		var speedyKey: String?
		if is12c {
			let s = try encrypt(comboKey, random(16) + passwordKey)
			speedyKey = hexString(Array(s.prefix(80)))
		}
		let encodedPassword = hexString(try encrypt(comboKey, random(16) + pw))
		return Verifier(sessionKey: sessionKey, speedyKey: speedyKey, encodedPassword: encodedPassword, comboKey: comboKey)
	}

	/// 2단계 응답의 AUTH_SVR_RESPONSE 가 우리 키로 풀리는지 (가짜 서버 막기)
	static func serverResponseValid(_ value: String?, comboKey: [UInt8]) -> Bool {
		guard let value, let enc = hex(value), let dec = try? aesCBC(decrypt: true, key: comboKey, enc), dec.count >= 32 else { return false }
		return Array(dec[16..<32]) == Array("SERVER_TO_CLIENT".utf8)
	}

	// MARK: - 암호 도구

	/// 덧붙임: 16 바이트 단위가 되게 모자란 수(n)를 n 바이트로 (꼭 맞으면 16 바이트 한 덩이 더)
	static func encrypt(_ key: [UInt8], _ plain: [UInt8]) throws -> [UInt8] {
		let n = 16 - plain.count % 16
		return try aesCBC(decrypt: false, key: key, plain + [UInt8](repeating: UInt8(n), count: n))
	}

	/// AES-CBC, IV 0, 덧붙임 없음
	static func aesCBC(decrypt: Bool, key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
		guard input.count % 16 == 0 else { throw OracleError.protocolError("암호 길이가 맞지 않습니다.") }
		var out = [UInt8](repeating: 0, count: input.count + 16)
		var moved = 0
		let iv = [UInt8](repeating: 0, count: 16)
		let st = CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
		                 key, key.count, iv, input, input.count, &out, out.count, &moved)
		guard st == kCCSuccess else { throw OracleError.protocolError("암호 계산에 실패했습니다 (\(st)).") }
		return Array(out.prefix(moved))
	}

	static func pbkdf2(_ password: [UInt8], salt: [UInt8], length: Int, rounds: Int) throws -> [UInt8] {
		var out = [UInt8](repeating: 0, count: length)
		let st = password.withUnsafeBufferPointer { p in
			p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { pp in
				CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pp, password.count, salt, salt.count,
				                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(rounds), &out, length)
			}
		}
		guard st == kCCSuccess else { throw OracleError.protocolError("키 계산에 실패했습니다 (\(st)).") }
		return out
	}

	static func random(_ n: Int) -> [UInt8] {
		var b = [UInt8](repeating: 0, count: n)
		_ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
		return b
	}

	/// 대문자 16진수
	static func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

	static func hex(_ s: String) -> [UInt8]? {
		let c = Array(s.utf8)
		guard c.count % 2 == 0 else { return nil }
		var out = [UInt8]()
		out.reserveCapacity(c.count / 2)
		var i = 0
		while i < c.count {
			guard let hi = nibble(c[i]), let lo = nibble(c[i + 1]) else { return nil }
			out.append(hi << 4 | lo)
			i += 2
		}
		return out
	}

	private static func nibble(_ c: UInt8) -> UInt8? {
		switch c {
		case 48...57: c - 48
		case 65...70: c - 55
		case 97...102: c - 87
		default: nil
		}
	}
}
