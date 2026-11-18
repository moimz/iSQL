import Foundation

/// 서버가 알려 준 버전 글자에서 읽은 숫자 버전 (8.4.13, 11.4.13 …). 버전마다 다른 기능·함수를 가를 때 쓴다
struct ServerVersion: Comparable, Sendable, CustomStringConvertible {
	var parts: [Int]

	init(_ parts: Int...) { self.parts = parts }

	/// "8.4.13", "11.4.13-MariaDB-ubu2404", "5.5.5-10.11.6-MariaDB" (옛 MariaDB 는 앞에 5.5.5- 를 붙인다) → 숫자들. 못 읽으면 nil
	init?(_ text: String) {
		var t = text
		if t.hasPrefix("5.5.5-") { t.removeFirst(6) }
		let head = t.prefix { $0.isNumber || $0 == "." }
		let nums = head.split(separator: ".").compactMap { Int($0) }
		guard !nums.isEmpty else { return nil }
		parts = nums
	}

	static func < (a: ServerVersion, b: ServerVersion) -> Bool {
		for i in 0..<max(a.parts.count, b.parts.count) {
			let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
			if x != y { return x < y }
		}
		return false
	}
	static func == (a: ServerVersion, b: ServerVersion) -> Bool { !(a < b) && !(b < a) }

	var description: String { parts.map(String.init).joined(separator: ".") }
}

/// 자동 완성 함수 하나: 어느 DB 종류에서 몇 버전부터 있는지 (없는 종류는 빠진다)
struct SQLFunction: Sendable {
	let name: String
	let since: [SQLKind: ServerVersion]

	/// 이 종류·버전 서버에 있는지 (버전을 모르면 종류만 본다)
	func available(_ kind: SQLKind, _ version: ServerVersion?) -> Bool {
		guard let first = since[kind] else { return false }
		guard let version else { return true }
		return version >= first
	}
}
