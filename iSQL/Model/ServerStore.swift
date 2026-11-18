import Foundation
import Observation

/// 서버 목록. 파일은 StorageLocation 에 서버마다 하나씩 둔다
@Observable
final class ServerStore {
	private(set) var servers: [Server] = []

	private var dir: URL { StorageLocation.shared.servers }
	private static let encoder: JSONEncoder = {
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		e.dateEncodingStrategy = .iso8601
		return e
	}()
	private static let decoder: JSONDecoder = {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}()

	var isCloud: Bool { StorageLocation.shared.isCloud }

	/// 그룹 이름 (순서대로). 서버가 없는 그룹도 있다. groups.json 에 저장
	private(set) var groups: [String] = []

	/// 사이드바·메뉴에 보일 순서: 그룹 없는 서버가 먼저, 그다음 그룹 순서. 빈 그룹도 나온다
	var grouped: [(group: String, servers: [Server])] {
		let byGroup = Dictionary(grouping: servers, by: \.group)
		var names = groups
		// groups.json 에 없는 그룹 이름(예전에 묶음으로 넣은 것)은 뒤에 붙인다
		for g in byGroup.keys.sorted() where !g.isEmpty && !names.contains(g) { names.append(g) }
		var out: [(String, [Server])] = []
		if let ungrouped = byGroup[""], !ungrouped.isEmpty { out.append(("", Self.sorted(ungrouped))) }
		for g in names { out.append((g, Self.sorted(byGroup[g] ?? []))) }
		return out
	}

	/// 순서가 있으면 그 순서, 없으면 이름순으로 뒤에
	static func sorted(_ list: [Server]) -> [Server] {
		list.sorted { a, b in
			switch (a.order, b.order) {
			case let (x?, y?) where x != y: return x < y
			case (_?, nil): return true
			case (nil, _?): return false
			default: return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
			}
		}
	}

	// MARK: - 그룹

	func addGroup(_ name: String) {
		let n = name.trimmingCharacters(in: .whitespaces)
		guard !n.isEmpty else { return }
		syncGroupNames()
		if !groups.contains(n) { groups.append(n); saveGroups() }
	}

	/// 그룹을 지우고 그 안 서버는 그룹 없음으로 옮긴다
	func deleteGroup(_ name: String) {
		for var s in servers where s.group == name { s.group = ""; save(s) }
		groups.removeAll { $0 == name }
		saveGroups()
	}

	/// 그룹을 다른 그룹 앞으로 (before 가 nil 이면 맨 뒤로)
	func moveGroup(_ name: String, before target: String?) {
		syncGroupNames()
		guard name != target, groups.contains(name) else { return }
		groups.removeAll { $0 == name }
		if let target, let i = groups.firstIndex(of: target) { groups.insert(name, at: i) } else { groups.append(name) }
		saveGroups()
	}

	/// 서버를 그 그룹의 target 앞으로 옮긴다 (target 이 nil 이면 그룹 맨 뒤). 그룹 안 순서를 다시 매긴다
	func moveServer(_ id: UUID, toGroup group: String, before target: UUID?) {
		guard id != target, var moving = servers.first(where: { $0.id == id }) else { return }
		var list = Self.sorted(servers.filter { $0.group == group && $0.id != id })
		moving.group = group
		if let target, let i = list.firstIndex(where: { $0.id == target }) { list.insert(moving, at: i) } else { list.append(moving) }
		for (i, var s) in list.enumerated() {
			let old = servers.first { $0.id == s.id }
			s.order = Double(i)
			if old?.order != s.order || old?.group != s.group { save(s) }
		}
	}

	/// 서버에만 있던 그룹 이름도 groups 에 넣어 둔다 (순서를 바꿀 수 있게)
	private func syncGroupNames() {
		for g in Set(servers.map(\.group)).sorted() where !g.isEmpty && !groups.contains(g) { groups.append(g) }
	}

	private func saveGroups() {
		guard let data = try? Self.encoder.encode(groups) else { return }
		StorageLocation.write(data, to: StorageLocation.shared.groups)
	}

	func load() {
		StorageLocation.shared.downloadAll()
		let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
		var loaded: [Server] = []
		var hidden: Set<UUID> = []
		for f in files where f.pathExtension == "json" {
			guard let data = try? Data(contentsOf: f), var s = try? Self.decoder.decode(Server.self, from: data) else { continue }
			// 2.0 에서 만든 다른 DB 종류(mariadb·postgres 등)는 목록에 넣지 않고 파일도 건드리지 않는다
			guard s.isSupportedKind else { hidden.insert(s.id); continue }
			// 옛 파일(kind 없음)에는 "mysql" 을 적어 둔다. 고친 시각(modified)과 모르는 칸은 그대로
			if s.kind == nil {
				s.kind = Server.mysqlKind
				if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
					obj["kind"] = Server.mysqlKind
					if let out = Self.json(obj) { StorageLocation.write(out, to: f) }
				}
			}
			loaded.append(s)
		}
		hiddenIDs = hidden
		// 아직 안 받은 파일의 서버는 지우지 않고 그대로 둔다
		let waiting = StorageLocation.shared.placeholderIDs()
		for s in servers where waiting.contains(s.id) && !loaded.contains(where: { $0.id == s.id }) { loaded.append(s) }
		if loaded != servers { servers = loaded }
		if let data = try? Data(contentsOf: StorageLocation.shared.groups), let g = try? Self.decoder.decode([String].self, from: data), g != groups {
			groups = g
		}
	}

	func save(_ server: Server) {
		// 2.0 의 다른 DB 종류 서버 파일은 1.0 이 절대 다시 쓰지 않는다
		// (.isql 가져오기로 들어온 다른 종류 서버도 1.0 에는 넣지 않는다)
		guard !hiddenIDs.contains(server.id), server.isSupportedKind else { return }
		var s = server
		s.modified = Date()
		if s.kind == nil { s.kind = Server.mysqlKind }
		if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
		guard var data = try? Self.encoder.encode(s) else { return }
		let file = dir.appendingPathComponent(s.id.uuidString + ".json")
		if let old = try? Data(contentsOf: file), let merged = Self.keepingUnknownKeys(new: data, old: old) { data = merged }
		StorageLocation.write(data, to: file)
	}

	/// 2.0 에서 만든 다른 DB 종류라 목록에 넣지 않은 서버 id. 저장·삭제 대상에서 빠진다
	private(set) var hiddenIDs: Set<UUID> = []

	/// 새로 쓸 내용에 원래 파일의 "이 버전이 모르는 칸"을 다시 붙인다 (2.0 이 넣은 새 칸을 1.0 이 지우지 않게).
	/// 모르는 칸 = 원래 파일에는 있는데, 원래 파일을 읽어 다시 쓰면 사라지는 칸. 안쪽 객체(ssh 등)도 같은 방식
	static func keepingUnknownKeys(new: Data, old: Data) -> Data? {
		guard let oldObj = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
		      let oldServer = try? decoder.decode(Server.self, from: old),
		      let roundTrip = (try? encoder.encode(oldServer)).flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
		      var newObj = (try? JSONSerialization.jsonObject(with: new)) as? [String: Any] else { return nil }
		let extra = unknown(oldObj, known: roundTrip)
		guard !extra.isEmpty else { return nil }
		merge(&newObj, extra)
		return json(newObj)
	}

	private static func unknown(_ old: [String: Any], known: [String: Any]) -> [String: Any] {
		var out: [String: Any] = [:]
		for (k, v) in old {
			guard let kv = known[k] else { out[k] = v; continue }
			if let od = v as? [String: Any], let kd = kv as? [String: Any] {
				let inner = unknown(od, known: kd)
				if !inner.isEmpty { out[k] = inner }
			}
		}
		return out
	}

	private static func merge(_ target: inout [String: Any], _ extra: [String: Any]) {
		for (k, v) in extra {
			if var t = target[k] as? [String: Any], let e = v as? [String: Any] {
				merge(&t, e)
				target[k] = t
			} else if target[k] == nil {
				target[k] = v
			}
		}
	}

	private static func json(_ obj: [String: Any]) -> Data? {
		try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
	}

	func delete(_ server: Server) {
		guard !hiddenIDs.contains(server.id) else { return }
		servers.removeAll { $0.id == server.id }
		StorageLocation.remove(dir.appendingPathComponent(server.id.uuidString + ".json"))
		QueryStore.remove(server.id)
		Keychain.delete(server.mysqlPasswordKey)
		Keychain.delete(server.sshSecretKey)
	}

	func duplicate(_ server: Server) -> Server {
		var copy = server
		copy.id = UUID()
		copy.name = server.displayName + " 복사본"
		Keychain.set(Keychain.get(server.mysqlPasswordKey), for: copy.mysqlPasswordKey)
		Keychain.set(Keychain.get(server.sshSecretKey), for: copy.sshSecretKey)
		save(copy)
		return copy
	}
}
