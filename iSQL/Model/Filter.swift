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
		let c = path.isEmpty ? dialect.quote(column) : dialect.jsonPath(dialect.quote(column), path)
		let v = value
		if op.needsValue && v.isEmpty { return nil }
		func lit(_ s: String) -> String { dialect.literal(.text(s)) }
		switch op {
		case .eq: return "\(c) = \(lit(v))"
		case .ne: return "\(c) != \(lit(v))"
		case .gt: return "\(c) > \(lit(v))"
		case .ge: return "\(c) >= \(lit(v))"
		case .lt: return "\(c) < \(lit(v))"
		case .le: return "\(c) <= \(lit(v))"
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

	var id: String { rawValue }
	/// LIKE 값 안의 \ % _ 를 글자 그대로 찾게
	var needsValue: Bool { ![.isNull, .notNull, .isEmpty].contains(self) }
	var placeholder: String {
		switch self {
		case .in, .notIn: "쉼표로 나눔: 1, 2, 3"
		case .like, .notLike: "% 와 _ 를 직접 씀"
		default: "값"
		}
	}
	/// 메뉴에서 구분선을 넣을 자리
	var groupEnd: Bool { [.le, .notLike, .notIn].contains(self) }
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
