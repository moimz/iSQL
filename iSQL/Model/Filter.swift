import Foundation

/// 필터 한 줄: [✓] [컬럼] [연산자] [값]
struct FilterRow: Identifiable, Equatable {
	var id = UUID()
	var enabled = true
	var column: String
	var op: FilterOp = .eq
	var value = ""
	/// JSON 컬럼 안 경로 ($.user.name). 비면 컬럼 전체
	var path = ""

	/// 이 줄이 만드는 조건 (값이 필요한데 비었으면 nil)
	func sql(_ dialect: any SQLDialect) -> String? {
		guard enabled, !column.isEmpty else { return nil }
		let path = self.path.trimmingCharacters(in: .whitespaces)
		let col = dialect.quote(column)
		let c = path.isEmpty ? col : dialect.jsonPath(col, path)
		let v = value
		if op.needsValue && v.isEmpty { return nil }
		func lit(_ s: String) -> String { dialect.literal(.text(s)) }
		// JSON 경로 값은 글자로 나온다 → 크기 비교는 숫자면 숫자로 ('9' > '60' 이 참이 되지 않게)
		func cmp(_ s: String) -> String {
			let t = s.trimmingCharacters(in: .whitespaces)
			return !path.isEmpty && Double(t) != nil && Double(t)!.isFinite ? t : lit(s)
		}
		switch op {
		case .gt: return "\(c) > \(cmp(v))"
		case .ge: return "\(c) >= \(cmp(v))"
		case .lt: return "\(c) < \(cmp(v))"
		case .le: return "\(c) <= \(cmp(v))"
		case .jsonAnywhere: return dialect.jsonSearch(col, v, path: path.isEmpty ? nil : path)
		case .jsonContains: return dialect.jsonContains(col, FilterOp.jsonCandidate(v), path: path.isEmpty ? nil : path)
		case .jsonHasPath, .jsonNoPath:
			guard !path.isEmpty else { return nil }
			return dialect.jsonContainsPath(col, path) + (op == .jsonHasPath ? "" : " = 0")
		case .eq: return "\(c) = \(lit(v))"
		case .ne: return "\(c) != \(lit(v))"
		case .like: return "\(c) LIKE \(lit(v))"
		case .notLike: return "\(c) NOT LIKE \(lit(v))"
		case .in, .notIn:
			let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
			guard !items.isEmpty else { return nil }
			return "\(c) \(op == .in ? "IN" : "NOT IN") (\(items.map(lit).joined(separator: ", ")))"
		case .isNull: return "\(c) IS NULL"
		case .notNull: return "\(c) IS NOT NULL"
		case .isEmpty: return "(\(c) IS NULL OR \(c) = '')"
		}
	}
}

enum FilterOp: String, CaseIterable, Identifiable {
	case eq = "="
	case ne = "≠"
	case gt = ">"
	case ge = "≥"
	case lt = "<"
	case le = "≤"
	// 포함 · 포함 안 함 · 시작 · 끝은 뺐다: LIKE 에 % 를 직접 (사용자 2026-11-18)
	case like = "LIKE"
	case notLike = "NOT LIKE"
	case `in` = "IN"
	case notIn = "NOT IN"
	case isNull = "NULL"
	case notNull = "NULL 아님"
	case isEmpty = "비어 있음"
	// JSON 컬럼에서만 (경로 칸과 같이 쓴다, 사용자 2026-11-18: 함수 이름을 기억하지 않아도 되게)
	case jsonAnywhere = "JSON 어디든 포함"
	case jsonContains = "배열·객체에 포함"
	case jsonHasPath = "경로 있음"
	case jsonNoPath = "경로 없음"

	var id: String { rawValue }
	/// JSON 컬럼에서만 보이는 연산자
	static let jsonOps: [FilterOp] = [.jsonAnywhere, .jsonContains, .jsonHasPath, .jsonNoPath]
	var isJSONOnly: Bool { Self.jsonOps.contains(self) }
	/// LIKE 값 안의 \ % _ 를 글자 그대로 찾게
	var needsValue: Bool { ![.isNull, .notNull, .isEmpty, .jsonHasPath, .jsonNoPath].contains(self) }
	var placeholder: String {
		switch self {
		case .in, .notIn: "쉼표로 나눔: 1, 2, 3"
		case .like, .notLike: "% 와 _ 를 직접 씀"
		case .jsonAnywhere: "찾을 글자 (% 를 쓸 수 있음)"
		case .jsonContains: "값 (글자·숫자, 또는 JSON)"
		default: "값"
		}
	}
	/// 메뉴에서 구분선을 넣을 자리
	var groupEnd: Bool { [.le, .notLike, .notIn, .isEmpty].contains(self) }

	/// "배열·객체에 포함" 의 값 → JSON 글자: 숫자·true·false·null·{…}·[…] 는 그대로, 나머지는 "글자"
	static func jsonCandidate(_ v: String) -> String {
		let t = v.trimmingCharacters(in: .whitespaces)
		if Double(t) != nil || ["true", "false", "null"].contains(t) || t.hasPrefix("{") || t.hasPrefix("[") { return t }
		let data = try? JSONSerialization.data(withJSONObject: [t], options: [.withoutEscapingSlashes])
		return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\(t)\""
	}
}

/// 테이블마다 최근에 적용한 WHERE 절 (최대 10개, 이 맥에만)
enum WhereHistory {
	static let limit = 10

	private static func key(_ server: UUID?, _ table: String) -> String { "where.\(server?.uuidString ?? "-").\(table)" }

	static func load(server: UUID?, table: String) -> [String] {
		UserDefaults.standard.stringArray(forKey: key(server, table)) ?? []
	}

	static func remember(_ clause: String, server: UUID?, table: String) -> [String] {
		let c = clause.trimmingCharacters(in: .whitespacesAndNewlines)
		var list = load(server: server, table: table)
		guard !c.isEmpty else { return list }
		list.removeAll { $0 == c }
		list.insert(c, at: 0)
		list = Array(list.prefix(limit))
		UserDefaults.standard.set(list, forKey: key(server, table))
		return list
	}

	static func remove(_ clause: String, server: UUID?, table: String) -> [String] {
		var list = load(server: server, table: table)
		list.removeAll { $0 == clause }
		UserDefaults.standard.set(list, forKey: key(server, table))
		return list
	}
}
