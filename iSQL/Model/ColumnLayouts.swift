import Foundation

/// 테이블 하나의 표 컬럼 설정: 순서·숨김·너비·고정 (사용자 2026-11-19: 늘 기억하고 iCloud 로 같이).
/// 컬럼은 이름(GridColumn.key)으로 적는다. structure(컬럼 이름·타입)가 지금 테이블과 다르면 쓰지 않고 지운다
/// (구조가 바뀌었는데 옛 너비·순서·고정을 억지로 맞추는 게 더 이상하다 — 사용자)
struct TableColumnLayout: Codable, Equatable {
	var structure: String
	/// 보이는 순서대로 모든 컬럼 이름 (숨긴 것도 그 자리에)
	var order: [String]
	var hidden: [String]
	/// 처음 너비와 다른 컬럼만
	var widths: [String: Double]
	/// 왼쪽 고정 컬럼 수 (0 = 없음)
	var frozen: Int
	var modified = Date()

	/// 내용이 같은지 (고친 시각은 빼고)
	func same(as o: TableColumnLayout?) -> Bool {
		guard let o else { return false }
		return structure == o.structure && order == o.order && hidden == o.hidden && frozen == o.frozen
			&& widths.keys.sorted() == o.widths.keys.sorted() && widths.allSatisfy { abs($0.value - (o.widths[$0.key] ?? -99)) < 1 }
	}
}

/// iCloud Data/Layouts/<서버id>.json = { "db.테이블": TableColumnLayout }. 저장한 서버만 (나만 보는 뷰·쿼리와 같이)
enum ColumnLayoutStore {
	static var dir: URL {
		let d = StorageLocation.shared.servers.deletingLastPathComponent().appendingPathComponent("Layouts", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}
	static func url(_ server: UUID) -> URL { dir.appendingPathComponent(server.uuidString + ".json") }

	static func load(_ server: UUID) -> [String: TableColumnLayout] {
		let u = url(server)
		if !FileManager.default.fileExists(atPath: u.path) {
			let ph = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
			if FileManager.default.fileExists(atPath: ph.path) { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
			return [:]
		}
		var out: [String: TableColumnLayout] = [:]
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &error) { r in
			if let d = try? Data(contentsOf: r) { out = (try? decoder.decode([String: TableColumnLayout].self, from: d)) ?? [:] }
		}
		return out
	}

	/// 이 맥에서 바꾼 테이블만 파일에 반영한다 (다른 맥이 바꾼 다른 테이블은 그대로). 합친 결과를 돌려준다.
	/// 같은 테이블을 두 맥이 바꿨으면 늦게 고친 쪽 (지운 것은 지운 쪽이 이긴다)
	static func save(_ server: UUID, changes: [String: TableColumnLayout?]) -> [String: TableColumnLayout] {
		var all = load(server)
		for (key, l) in changes {
			if let l {
				if let theirs = all[key], theirs.modified > l.modified { continue }
				all[key] = l
			} else {
				all[key] = nil
			}
		}
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		e.dateEncodingStrategy = .iso8601
		if all.isEmpty { StorageLocation.remove(url(server)) }
		else if let d = try? e.encode(all) { StorageLocation.write(d, to: url(server)) }
		return all
	}

	private static let decoder: JSONDecoder = {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}()
}
