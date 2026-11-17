import Foundation
import CryptoKit
import CommonCrypto
import UniformTypeIdentifiers

extension UTType {
	/// iSQL 서버 목록 파일 (.isql). Info.plist(iSQL-Info.plist)의 UTExportedTypeDeclarations 와 같은 이름
	static let isqlServers = UTType(exportedAs: "com.moimz.isql.servers")
}

/// 서버 내보내기·가져오기 (.isql).
/// 파일 = "ISQLSRV1" + PBKDF2 반복 수(4바이트) + 소금(16바이트) + AES-256-GCM 봉투(nonce 12 + 암호문 + 태그 16).
/// 안은 JSON: 서버 설정, MySQL 비밀번호, SSH 비밀번호(비밀번호 방식일 때), SSH 키 파일 내용(키 방식이고 키 파일을 지정했을 때).
/// **SSH 키에 걸린 암호는 넣지 않는다** (사용자 결정: 가져온 사람이 직접 넣든지 말든지)
enum ServerTransfer {
	static let magic = Data("ISQLSRV1".utf8)
	static let rounds: UInt32 = 310_000

	struct Payload: Codable {
		var format = "isql-servers"
		var version = 1
		var exported = Date()
		/// 쓰지 않음 (늘 비어 있다). 그룹은 받는 사람이 자기 식으로 만들어 두므로 내보내지 않는다 (2026-11-17 사용자)
		var groups: [String] = []
		var servers: [Item] = []
	}

	struct Item: Codable, Identifiable {
		var server: Server
		var mysqlPassword: String?
		/// SSH 가 비밀번호 방식일 때만
		var sshPassword: String?
		/// SSH 가 키 방식이고 키 파일을 지정했을 때만
		var sshKey: KeyFile?
		var id: UUID { server.id }
	}

	struct KeyFile: Codable {
		/// 내보낸 맥에서의 경로 (~/.ssh/id_x)
		var originalPath: String
		var content: Data
		/// 키 자체에 암호가 걸려 있는지 (그 암호는 파일에 없다)
		var encrypted: Bool
		var fileName: String { (originalPath as NSString).lastPathComponent }
	}

	enum Failure: LocalizedError {
		case notISQL, wrongPassword, unsupported(Int), noServers, keyMissing(String)
		var errorDescription: String? {
			switch self {
			case .notISQL: "iSQL 서버 파일(.isql)이 아닙니다"
			case .wrongPassword: "암호가 맞지 않거나 파일이 손상됐습니다"
			case .unsupported(let v): "이 iSQL 보다 새 버전에서 만든 파일입니다 (형식 \(v))"
			case .noServers: "내보낼 서버를 고르세요"
			case .keyMissing(let p): "SSH 키 파일을 읽지 못했습니다: \(p)"
			}
		}
	}

	// MARK: 내보내기

	/// 고른 서버를 Payload 로 (비밀번호는 키체인에서, 키 파일은 디스크에서 읽는다). 그룹은 빼고 내보낸다
	static func payload(_ servers: [Server]) throws -> (Payload, warnings: [String]) {
		guard !servers.isEmpty else { throw Failure.noServers }
		var p = Payload()
		var warnings: [String] = []
		for var s in servers {
			s.group = ""
			var item = Item(server: s, mysqlPassword: Keychain.get(s.mysqlPasswordKey))
			if s.ssh.enabled {
				if s.ssh.auth == .password {
					item.sshPassword = Keychain.get(s.sshSecretKey)
				} else if !s.ssh.keyPath.isEmpty {
					let path = (s.ssh.keyPath as NSString).expandingTildeInPath
					if let data = FileManager.default.contents(atPath: path) {
						item.sshKey = KeyFile(originalPath: s.ssh.keyPath, content: data, encrypted: isEncryptedKey(data))
					} else {
						warnings.append("\(s.displayName): SSH 키 파일이 없어 빼고 내보냅니다 (\(s.ssh.keyPath))")
					}
				}
			}
			if item.mysqlPassword == nil { warnings.append("\(s.displayName): 저장된 MySQL 비밀번호가 없습니다") }
			p.servers.append(item)
		}
		return (p, warnings)
	}

	static func seal(_ p: Payload, password: String) throws -> Data {
		let enc = JSONEncoder()
		enc.dateEncodingStrategy = .iso8601
		let json = try enc.encode(p)
		var salt = Data(count: 16)
		_ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
		let key = derive(password, salt: salt, rounds: rounds)
		let box = try AES.GCM.seal(json, using: key)
		var out = magic
		var r = rounds.bigEndian
		out.append(Data(bytes: &r, count: 4))
		out.append(salt)
		out.append(box.combined!)
		return out
	}

	// MARK: 가져오기

	static func open(_ data: Data, password: String) throws -> Payload {
		guard data.count > magic.count + 4 + 16 + 28, data.prefix(magic.count) == magic else { throw Failure.notISQL }
		var i = magic.count
		let r = data.subdata(in: i..<(i + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
		i += 4
		let salt = data.subdata(in: i..<(i + 16))
		i += 16
		let key = derive(password, salt: salt, rounds: r)
		let json: Data
		do {
			json = try AES.GCM.open(try AES.GCM.SealedBox(combined: data.subdata(in: i..<data.count)), using: key)
		} catch {
			throw Failure.wrongPassword
		}
		let dec = JSONDecoder()
		dec.dateDecodingStrategy = .iso8601
		let p = try dec.decode(Payload.self, from: json)
		guard p.format == "isql-servers" else { throw Failure.notISQL }
		guard p.version <= 1 else { throw Failure.unsupported(p.version) }
		return p
	}

	/// 가져온 서버를 목록·키체인에 넣는다. keyPassphrases: 서버 id → 사용자가 직접 넣은 SSH 키 암호 (없으면 안 넣음).
	/// 새 서버는 무조건 그룹 없음(그룹을 만들지 않는다), 이미 있는 서버를 덮어쓰면 이 맥에서 넣어 둔 그룹 그대로
	@MainActor
	static func apply(_ items: [Item], store: ServerStore, keyPassphrases: [UUID: String]) throws {
		for item in items {
			var s = item.server
			// 덮어쓸 때 그룹·목록 순서는 이 맥에서 정해 둔 그대로
			let old = store.servers.first { $0.id == s.id }
			s.group = old?.group ?? ""
			s.order = old?.order
			if let k = item.sshKey { s.ssh.keyPath = try installKey(k) }
			store.save(s)
			// 파일에 없는 비밀번호는 이 맥에 있던 것을 그대로 둔다 (덮어쓸 때 지우지 않게)
			if let pw = item.mysqlPassword { Keychain.set(pw, for: s.mysqlPasswordKey) }
			if s.ssh.auth == .password {
				if let pw = item.sshPassword { Keychain.set(pw, for: s.sshSecretKey) }
			} else if let pp = keyPassphrases[s.id], !pp.isEmpty {
				Keychain.set(pp, for: s.sshSecretKey)
			}
		}
	}

	/// 이 맥에 같은 키가 있으면 그 경로, 없으면 ~/.ssh 에 저장한 경로 (~ 로 시작)
	static func installKey(_ k: KeyFile) throws -> String {
		if let existing = existingKey(k) { return existing }
		let fm = FileManager.default
		let sshDir = (("~/.ssh") as NSString).expandingTildeInPath
		if !fm.fileExists(atPath: sshDir) {
			try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		}
		let base = k.fileName.isEmpty ? "isql_key" : k.fileName
		var name = base
		var n = 2
		while fm.fileExists(atPath: sshDir + "/" + name) { name = "\(base)-\(n)"; n += 1 }
		let path = sshDir + "/" + name
		guard fm.createFile(atPath: path, contents: k.content, attributes: [.posixPermissions: 0o600]) else {
			throw Failure.keyMissing(path)
		}
		return "~/.ssh/" + name
	}

	/// 이 맥에 내용이 똑같은 키가 있는지: 내보낸 쪽 경로 그대로 → ~/.ssh 안 파일들
	static func existingKey(_ k: KeyFile) -> String? {
		let fm = FileManager.default
		let original = (k.originalPath as NSString).expandingTildeInPath
		if fm.contents(atPath: original) == k.content { return k.originalPath }
		let sshDir = ("~/.ssh" as NSString).expandingTildeInPath
		for f in (try? fm.contentsOfDirectory(atPath: sshDir)) ?? [] {
			let p = sshDir + "/" + f
			var isDir: ObjCBool = false
			guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
			      let attrs = try? fm.attributesOfItem(atPath: p), (attrs[.size] as? Int) == k.content.count else { continue }
			if fm.contents(atPath: p) == k.content { return "~/.ssh/" + f }
		}
		return nil
	}

	// MARK: 도움

	/// 키 파일에 암호가 걸려 있는지 (OpenSSH 새 형식·옛 PEM·PuTTY)
	static func isEncryptedKey(_ data: Data) -> Bool {
		let text = String(decoding: data, as: UTF8.self)
		if text.contains("ENCRYPTED") { return true }                      // PEM: Proc-Type: 4,ENCRYPTED / BEGIN ENCRYPTED PRIVATE KEY
		if text.contains("PuTTY-User-Key-File") { return !text.contains("Encryption: none") }
		if text.contains("BEGIN OPENSSH PRIVATE KEY") {
			let body = text.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
			guard let raw = Data(base64Encoded: body) else { return false }
			let magic = Data("openssh-key-v1\0".utf8)
			guard raw.count > magic.count + 4, raw.prefix(magic.count) == magic else { return false }
			let lenBytes = raw.subdata(in: magic.count..<(magic.count + 4))
			let len = Int(lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
			let start = magic.count + 4
			guard raw.count >= start + len else { return false }
			return String(decoding: raw.subdata(in: start..<(start + len)), as: UTF8.self) != "none"
		}
		return false
	}

	private static func derive(_ password: String, salt: Data, rounds: UInt32) -> SymmetricKey {
		var key = [UInt8](repeating: 0, count: 32)
		let pw = Array(password.utf8)
		salt.withUnsafeBytes { s in
			_ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
			                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
			                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, key.count)
		}
		return SymmetricKey(data: key)
	}
}
