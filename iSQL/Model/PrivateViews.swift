import Foundation
import AppKit

/// 나만 보는 뷰: 서버에 CREATE VIEW 하지 않고 SELECT 를 이름 붙여 iCloud 에 둔다 (내 맥끼리 같이 씀, 사용자 2026-11-17).
/// 저장된 서버는 Data/Views/<서버id>.json, 저장 안 한 접속·시험 앱은 메모리에만
struct PrivateView: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	/// 사이드바에서 보일 DB (쿼리 안의 DB 안 붙인 테이블도 이 DB 로 푼다)
	var schema: String
	var sql: String
	var created = Date()

	static let prefix = "pv:"
	var tabID: String { Self.prefix + id.uuidString }
	static func id(ofTab t: String) -> UUID? { t.hasPrefix(prefix) ? UUID(uuidString: String(t.dropFirst(prefix.count))) : nil }
}

enum PrivateViewStore {
	static var dir: URL {
		let d = StorageLocation.shared.servers.deletingLastPathComponent().appendingPathComponent("Views", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}
	static func url(_ server: UUID) -> URL { dir.appendingPathComponent(server.uuidString + ".json") }

	static func load(_ server: UUID) -> [PrivateView] {
		let u = url(server)
		if !FileManager.default.fileExists(atPath: u.path) {
			let ph = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
			if FileManager.default.fileExists(atPath: ph.path) { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
			return []
		}
		var out: [PrivateView] = []
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &error) { r in
			if let d = try? Data(contentsOf: r) { out = (try? JSONDecoder().decode([PrivateView].self, from: d)) ?? [] }
		}
		return out
	}

	static func save(_ server: UUID, _ list: [PrivateView]) {
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let d = try? e.encode(list) else { return }
		if list.isEmpty { StorageLocation.remove(url(server)) } else { StorageLocation.write(d, to: url(server)) }
	}
}
