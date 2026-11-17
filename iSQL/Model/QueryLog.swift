import Foundation
import Observation

/// 콘솔: 앱이 서버에 보낸 쿼리 (앱이 켜져 있는 동안만, 최근 2,000개)
@Observable
final class QueryLog {
	@MainActor static let shared = QueryLog()

	struct Entry: Identifiable {
		let id: Int
		let time: Date
		let server: String
		let database: String
		let sql: String
		let seconds: Double
		let error: String?
	}

	private(set) var entries: [Entry] = []
	@ObservationIgnored private var nextID = 0
	static let limit = 2000

	@MainActor
	func add(server: String, database: String, sql: String, seconds: Double, error: String?) {
		nextID += 1
		entries.append(Entry(id: nextID, time: Date(), server: server, database: database,
		                     sql: sql.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds, error: error))
		if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
	}

	@MainActor func clear() { entries = [] }
}
