import Foundation

/// 다른 앱에서 내보낸 접속 목록을 iSQL 서버로 읽는다 (가져오기 시트에서 .isql 이 아닌 파일).
/// 지금: Sequel Ace 즐겨찾기 내보내기(plist). 다음: DBeaver · MySQL Workbench (사용자가 파일을 주면).
/// 다른 앱 파일에는 비밀번호가 없다 → 처음 접속할 때 로그인 시트가 묻는다
enum OtherAppImport {
	struct Result {
		var app: String
		var items: [ServerTransfer.Item]
		/// 가져오지 못한 것 (소켓 접속 등)
		var skipped: [String]
	}

	enum Failure: LocalizedError {
		case unknown
		case empty(String)
		var errorDescription: String? {
			switch self {
			case .unknown: "읽을 수 없는 파일입니다 (iSQL .isql, Sequel Ace 즐겨찾기 내보내기 파일을 넣을 수 있습니다)"
			case .empty(let app): "\(app) 파일에 가져올 접속이 없습니다"
			}
		}
	}

	/// 파일 내용을 보고 어느 앱 것인지 정한다. existing: 이 맥 서버 목록 (같은 접속이면 그 서버를 덮어쓰도록 id 를 맞춘다)
	static func read(_ url: URL, existing: [Server]) throws -> Result {
		let data = try Data(contentsOf: url)
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
