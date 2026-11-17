import Foundation

/// ⌘K 빠른 열기: 지금 서버의 테이블·뷰·DB 를 이름 몇 글자로 찾는다
enum QuickOpen {
	struct Item: Identifiable, Equatable {
		enum Kind: Equatable { case table(TableInfo), database(String) }
		let kind: Kind
		var id: String {
			switch kind {
			case .table(let t): t.id
			case .database(let s): Session.databaseTabID(s)
			}
		}
	}

	/// 찾기. 빈 글이면 최근 연 것(최근이 앞)
	static func search(_ query: String, tables: [TableInfo], databases: [String], recent: [String], limit: Int = 60) -> [Item] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		if q.isEmpty {
			let byID = Dictionary(tables.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
			return recent.compactMap { id in
				if let s = Session.databaseOf(tab: id) { return databases.contains(s) ? Item(kind: .database(s)) : nil }
				return byID[id].map { Item(kind: .table($0)) }
			}
		}
		var scored: [(Int, Int, Item)] = []
		let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
		for t in tables {
			var best = score(q, t.name)
			// "db.테" 처럼 점을 넣으면 DB 이름까지 맞춘다
			if let full = score(q, t.id) { best = max(best ?? .min, q.contains(".") ? full + 50 : full - 60) }
			if best == nil, !t.comment.isEmpty, t.comment.lowercased().contains(q) { best = 100 }
			guard var s = best else { continue }
			if let r = recentRank[t.id] { s += max(0, 40 - r * 2) }
			scored.append((s, t.name.count, Item(kind: .table(t))))
		}
		for d in databases {
			guard var s = score(q, d) else { continue }
			if let r = recentRank[Session.databaseTabID(d)] { s += max(0, 40 - r * 2) }
			scored.append((s, d.count, Item(kind: .database(d))))
		}
		scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
		return scored.prefix(limit).map(\.2)
	}

	/// 이름에 대한 점수 (nil = 안 걸림). 같음 > 앞부분 > 단어 처음 > 이어진 글자 > 띄엄띄엄
	static func score(_ q: String, _ target: String) -> Int? {
		let t = target.lowercased()
		if t == q { return 1000 }
		if t.hasPrefix(q) { return 800 - min(100, t.count - q.count) }
		if let r = t.range(of: q) {
			let i = t.distance(from: t.startIndex, to: r.lowerBound)
			let wordStart = isBoundary(Array(t), i)
			return (wordStart ? 700 : 600) - min(100, i)
		}
		// 띄엄띄엄: 글자가 순서대로 다 있으면. 단어 처음·이어진 글자에 가산, 건너뛴 글자만큼 감점
		let chars = Array(t)
		var qi = q.startIndex
		var s = 300
		var last = -2
		for (i, c) in chars.enumerated() where qi < q.endIndex {
			guard c == q[qi] else { continue }
			if isBoundary(chars, i) { s += 25 }
			if i == last + 1 { s += 15 } else if last >= 0 { s -= min(20, i - last) }
			last = i
			qi = q.index(after: qi)
		}
		return qi == q.endIndex ? s : nil
	}

	private static func isBoundary(_ chars: [Character], _ i: Int) -> Bool {
		i == 0 || "_.- ".contains(chars[i - 1])
	}
}
