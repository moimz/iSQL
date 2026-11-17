import Foundation
import CommonCrypto

/// 다른 앱에서 내보낸 접속 목록을 iSQL 서버로 읽는다 (가져오기 시트에서 .isql 이 아닌 파일).
/// 지금: Sequel Ace 즐겨찾기 내보내기(plist, 비밀번호 없음), DBeaver 프로젝트 내보내기(.dbp, 비밀번호 있음). 다음: MySQL Workbench.
/// 비밀번호가 없는 파일은 처음 접속할 때 로그인 시트가 묻는다
enum OtherAppImport {
	struct Result {
		var app: String
		var items: [ServerTransfer.Item]
		/// 가져오지 못한 것 (소켓 접속 등)
		var skipped: [String]
		/// 파일에 비밀번호가 들어 있는지 (Sequel Ace 없음, DBeaver 있음)
		var hasPasswords = false
	}

	enum Failure: LocalizedError {
		case unknown
		case empty(String)
		var errorDescription: String? {
			switch self {
			case .unknown: "읽을 수 없는 파일입니다 (iSQL .isql, Sequel Ace 즐겨찾기 내보내기, DBeaver 프로젝트 내보내기 .dbp 를 넣을 수 있습니다)"
			case .empty(let app): "\(app) 파일에 가져올 접속이 없습니다"
			}
		}
	}

	/// 파일 내용을 보고 어느 앱 것인지 정한다. existing: 이 맥 서버 목록 (같은 접속이면 그 서버를 덮어쓰도록 id 를 맞춘다)
	static func read(_ url: URL, existing: [Server]) throws -> Result {
		let data = try Data(contentsOf: url)
		if let r = try dbeaver(url, data: data, existing: existing) {
			guard !r.items.isEmpty else { throw Failure.empty(r.app) }
			return r
		}
		if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
		   let r = sequelAce(plist, existing: existing) {
			guard !r.items.isEmpty else { throw Failure.empty(r.app) }
			return r
		}
		throw Failure.unknown
	}

	// MARK: Sequel Ace

	/// Sequel Ace 즐겨찾기 내보내기: { SPConnectionFavorites: [ {name, host, port, user, database, type, ssh…, colorIndex} ] }.
	/// 앱 안 Favorites.plist 처럼 그룹(Children)으로 묶인 것도 펼쳐서 읽는다 (그룹은 가져오지 않는다)
	private static func sequelAce(_ root: [String: Any], existing: [Server]) -> Result? {
		let top = root["SPConnectionFavorites"] ?? (root["Favorites Root"] as? [String: Any])?["Children"]
		guard let list = top as? [Any] else { return nil }
		var r = Result(app: "Sequel Ace", items: [], skipped: [])
		func walk(_ list: [Any]) {
			for case let d as [String: Any] in list {
				if let children = d["Children"] as? [Any] { walk(children); continue }
				guard d["host"] != nil || d["sshHost"] != nil else { continue }
				let name = str(d["name"])
				// type: 0 TCP/IP, 1 소켓, 2 SSH 터널, 3 AWS IAM
				let type = int(d["type"]) ?? 0
				guard type == 0 || type == 2 else {
					r.skipped.append("\(name.isEmpty ? str(d["host"]) : name): " + (type == 1 ? "소켓 접속" : "AWS IAM 접속") + "은 iSQL 에서 쓸 수 없습니다")
					continue
				}
				var s = Server()
				s.name = name
				s.host = str(d["host"]).isEmpty ? "127.0.0.1" : str(d["host"])
				s.port = int(d["port"]) ?? 3306
				s.user = str(d["user"])
				s.database = str(d["database"])
				let colors: [ServerColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
				if let c = int(d["colorIndex"]), colors.indices.contains(c) { s.color = colors[c] }
				if type == 2 {
					s.ssh.enabled = true
					s.ssh.host = str(d["sshHost"])
					s.ssh.port = int(d["sshPort"]) ?? 22
					s.ssh.user = str(d["sshUser"])
					// 키를 지정하지 않았으면 키 방식 + 빈 경로 = ~/.ssh/config·ssh-agent 가 고른다 (SSH 비밀번호도 파일에 없다)
					s.ssh.auth = .key
					if (int(d["sshKeyLocationEnabled"]) ?? 0) != 0 { s.ssh.keyPath = abbreviate(str(d["sshKeyLocation"])) }
				}
				if let same = existing.first(where: { sameConnection($0, s) }) { s.id = same.id }
				r.items.append(ServerTransfer.Item(server: s))
			}
		}
		walk(list)
		return r
	}

	// MARK: DBeaver

	/// DBeaver 파일 > 프로젝트 내보내기(.dbp = zip): projects/<이름>/.dbeaver/data-sources.json(접속) + credentials-config.json(사용자·비밀번호, DBeaver 기본 키로 AES-128-CBC).
	/// data-sources.json 을 바로 골라도 옆의 credentials-config.json 을 같이 읽는다. MySQL·MariaDB 만, 폴더(그룹)는 안 가져온다
	private static func dbeaver(_ url: URL, data: Data, existing: [Server]) throws -> Result? {
		var sources: [(json: Data, creds: Data?)] = []
		if data.starts(with: [0x50, 0x4B]) {                                   // zip (.dbp)
			let names = unzip(url, args: ["-Z1"]).map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
			for n in names where n.hasSuffix("/.dbeaver/data-sources.json") {
				guard let json = unzip(url, args: ["-p", n]) else { continue }
				let credPath = String(n.dropLast("data-sources.json".count)) + "credentials-config.json"
				sources.append((json, names.contains(credPath) ? unzip(url, args: ["-p", credPath]) : nil))
			}
			if sources.isEmpty { return nil }
		} else if url.lastPathComponent.hasPrefix("data-sources") && url.pathExtension == "json" {
			let cred = url.deletingLastPathComponent().appendingPathComponent("credentials-config.json")
			sources.append((data, try? Data(contentsOf: cred)))
		} else {
			return nil
		}
		var r = Result(app: "DBeaver", items: [], skipped: [], hasPasswords: true)
		for src in sources {
			guard let root = try? JSONSerialization.jsonObject(with: src.json) as? [String: Any],
			      let conns = root["connections"] as? [String: Any] else { continue }
			let creds = src.creds.flatMap(dbeaverCredentials) ?? [:]
			// DBeaver 는 접속을 만든 순서대로 id 가 늘어난다 → id 순서로
			for (cid, value) in conns.sorted(by: { $0.key < $1.key }) {
				guard let c = value as? [String: Any], let cfg = c["configuration"] as? [String: Any] else { continue }
				let name = str(c["name"])
				let provider = str(c["provider"]).lowercased()
				guard provider == "mysql" || provider == "mariadb" else {
					r.skipped.append("\(name.isEmpty ? cid : name): \(provider.isEmpty ? "알 수 없는" : provider) 접속은 iSQL 에서 쓸 수 없습니다")
					continue
				}
				let cred = creds[cid]?["#connection"]
				var s = Server()
				s.name = name
				s.host = str(cfg["host"]).isEmpty ? "127.0.0.1" : str(cfg["host"])
				s.port = int(cfg["port"]) ?? 3306
				s.user = cred?["user"] ?? str(cfg["user"])
				s.database = str(cfg["database"])
				var sshPassword: String?
				if let ssh = (cfg["handlers"] as? [String: Any])?["ssh_tunnel"] as? [String: Any], (ssh["enabled"] as? Bool) == true,
				   let p = ssh["properties"] as? [String: Any] {
					let sc = creds[cid]?["network/ssh_tunnel"]
					s.ssh.enabled = true
					s.ssh.host = str(p["host"])
					s.ssh.port = int(p["port"]) ?? 22
					s.ssh.user = sc?["user"] ?? str(p["user"])
					if str(p["authType"]).uppercased() == "PASSWORD" {
						s.ssh.auth = .password
						sshPassword = sc?["password"]
					} else {
						// PUBLIC_KEY / AGENT: 키 경로만 (키 암호는 묻지 않고 넣지 않는다)
						s.ssh.auth = .key
						s.ssh.keyPath = abbreviate(str(p["keyPath"]))
					}
				}
				if let same = existing.first(where: { sameConnection($0, s) }) { s.id = same.id }
				r.items.append(ServerTransfer.Item(server: s, mysqlPassword: cred?["password"].flatMap { $0.isEmpty ? nil : $0 },
				                                   sshPassword: sshPassword.flatMap { $0.isEmpty ? nil : $0 }))
			}
		}
		return r
	}

	/// credentials-config.json: 앞 16바이트 = IV, 나머지 = AES-128-CBC(PKCS7). 키는 DBeaver 에 박혀 있는 기본 키(널리 알려진 값, 사용자가 따로 암호를 걸지 않았을 때)
	/// → { 접속 id: { "#connection": {user, password}, "network/ssh_tunnel": {user, password} } }
	private static func dbeaverCredentials(_ data: Data) -> [String: [String: [String: String]]]? {
		guard data.count > 16 else { return nil }
		let key: [UInt8] = [0xba, 0xbb, 0x4a, 0x9f, 0x77, 0x4a, 0xb8, 0x53, 0xc9, 0x6c, 0x2d, 0x65, 0x3d, 0xfe, 0x54, 0x4a]
		let iv = [UInt8](data.prefix(16))
		let body = [UInt8](data.dropFirst(16))
		var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
		var len = 0
		let st = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
		                 key, key.count, iv, body, body.count, &out, out.count, &len)
		guard st == kCCSuccess, let obj = try? JSONSerialization.jsonObject(with: Data(out.prefix(len))) as? [String: Any] else { return nil }
		var r: [String: [String: [String: String]]] = [:]
		for (cid, v) in obj {
			guard let sections = v as? [String: Any] else { continue }
			for (sec, kv) in sections {
				guard let kv = kv as? [String: Any] else { continue }
				r[cid, default: [:]][sec] = kv.compactMapValues { $0 as? String }
			}
		}
		return r
	}

	/// /usr/bin/unzip 로 zip 안 내용 (-Z1 = 이름 목록, -p 이름 = 그 파일 내용)
	private static func unzip(_ url: URL, args: [String]) -> Data? {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
		p.arguments = Array(args.prefix(1)) + [url.path] + Array(args.dropFirst())
		let pipe = Pipe()
		p.standardOutput = pipe
		p.standardError = FileHandle.nullDevice
		guard (try? p.run()) != nil else { return nil }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		p.waitUntilExit()
		return p.terminationStatus == 0 ? data : nil
	}

	/// 같은 접속인지 (호스트·포트·사용자·SSH 호스트·SSH 사용자). localhost·127.0.0.1·::1 은 같은 곳으로 본다
	/// (Sequel Ace 는 SSH 너머 MySQL 호스트를 localhost 로 두는 일이 많다)
	static func sameConnection(_ a: Server, _ b: Server) -> Bool {
		func h(_ x: String) -> String { ["localhost", "127.0.0.1", "::1"].contains(x.lowercased()) ? "localhost" : x.lowercased() }
		return h(a.host) == h(b.host) && a.port == b.port && a.user == b.user
			&& a.ssh.enabled == b.ssh.enabled
			&& (!a.ssh.enabled || (a.ssh.host.lowercased() == b.ssh.host.lowercased() && a.ssh.user == b.ssh.user))
	}

	private static func str(_ v: Any?) -> String { ((v as? String) ?? (v as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespaces) }
	/// Sequel Ace 는 포트를 글자로 둔다 (비어 있으면 기본)
	private static func int(_ v: Any?) -> Int? {
		if let n = v as? NSNumber { return n.intValue }
		if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
		return nil
	}
	/// /Users/<나>/… → ~/… (다른 맥에서 내보낸 경로라도 ~/.ssh 아래면 이 맥의 ~/.ssh 로)
	private static func abbreviate(_ path: String) -> String {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		if parts.count > 3, parts[1] == "Users" { return "~/" + parts[3...].joined(separator: "/") }
		return path
	}
}
