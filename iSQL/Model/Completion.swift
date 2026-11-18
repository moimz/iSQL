import Foundation

/// 자동완성 후보 하나
struct CompletionItem: Hashable {
	enum Kind: Int { case column, table, view, database, keyword, function }
	var kind: Kind
	/// 넣을 글자 (필요하면 백틱)
	var insert: String
	/// 목록에 보일 이름
	var label: String
	/// 이름 옆 흐린 글자 (컬럼 타입, 테이블의 DB)
	var detail: String
	/// 오른쪽 끝 코멘트
	var comment: String
}

/// 쿼리 패널 자동완성: 커서 앞 낱말과 지금 문장을 보고 키워드·DB·테이블·컬럼 후보를 고른다.
/// 테이블·컬럼은 코멘트로도 찾는다 (한글 코멘트 "회원" → members).
enum SQLCompleter {
	struct Result {
		/// 바꿀 범위 (커서 앞 낱말, 여는 백틱 포함)
		var range: NSRange
		var items: [CompletionItem]
	}

	/// 테이블 이름 뒤(FROM big ▮)에 올 낱말
	static let clauseKeywords = ["WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CROSS JOIN", "ON", "USING",
	                             "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "AS", "SET", "UNION"]

	/// 고르면 뒤에 띄어쓰기를 붙이지 않을 키워드 (보통 뒤에 , ) ; 가 온다)
	private static let noSpaceAfter: Set<String> = ["NULL", "ASC", "DESC", "END", "COMMIT", "ROLLBACK"]

	/// 키워드는 고르면 뒤에 띄어쓰기까지 (SELECT ▮). DB·테이블은 뒤에 . 을 찍는 일이 많아 붙이지 않는다
	static func keywordItem(_ k: String) -> CompletionItem {
		CompletionItem(kind: .keyword, insert: noSpaceAfter.contains(k) ? k : k + " ", label: k, detail: "", comment: "")
	}



	private static func isIdent(_ c: unichar) -> Bool {
		guard let u = UnicodeScalar(c) else { return false }
		return c == 0x5F || c == 0x24 || CharacterSet.alphanumerics.contains(u)
	}

	/// 문장 안에서 커서가 따옴표·주석 안이면 true (그때는 띄우지 않는다)
	private static func insideLiteral(_ s: NSString, from start: Int, to end: Int, _ syntax: SQLSyntax) -> Bool {
		var quote: unichar = 0
		var i = start
		var lineComment = false, blockComment = false
		while i < end {
			let c = s.character(at: i)
			let next: unichar = i + 1 < end ? s.character(at: i + 1) : 0
			if lineComment { if c == 0x0A { lineComment = false } }
			else if blockComment { if c == 0x2A && next == 0x2F { blockComment = false; i += 1 } }
			else if quote != 0 {
				if c == 0x5C && syntax.backslashEscapes && quote != syntax.identifierQuote { i += 1 }
				else if c == quote { quote = 0 }
			} else if syntax.stringQuotes.contains(c) { quote = c }
			else if (c == 0x23 && syntax.hashComments) || (c == 0x2D && next == 0x2D) { lineComment = true }
			else if c == 0x2F && next == 0x2A { blockComment = true; i += 1 }
			i += 1
		}
		return quote != 0 || lineComment || blockComment
	}

	/// 커서 위치의 후보. force 면 낱말이 비어 있어도 (⌥Esc 로 직접 부를 때)
	@MainActor
	static func complete(text: String, caret: Int, session: Session, defaultDB: String, force: Bool = false) -> Result? {
		let s = text as NSString
		guard caret <= s.length else { return nil }
		// 지금 문장
		let syntax = session.dialect.syntax
		let parts = SQLSplitter.split(text, syntax)
		let part = parts.first { $0.range.location <= caret && caret <= NSMaxRange($0.range) }
		let stmtStart = part?.range.location ?? (parts.last.map { NSMaxRange($0.range) } ?? 0)
		let statement = part?.text ?? s.substring(with: NSRange(location: min(stmtStart, caret), length: caret - min(stmtStart, caret)))
		if insideLiteral(s, from: min(stmtStart, caret), to: caret, syntax) { return nil }

		// 커서 앞 낱말 (여는 백틱도 함께 바꾼다)
		var start = caret
		while start > 0, isIdent(s.character(at: start - 1)) { start -= 1 }
		if start > 0, s.character(at: start - 1) == syntax.identifierQuote { start -= 1 }
		let rawPrefix = s.substring(with: NSRange(location: start, length: caret - start))
		let prefix = rawPrefix.hasPrefix(syntax.identifierQuoteString) ? String(rawPrefix.dropFirst()) : rawPrefix

		// 앞에 붙은 "a." / "a.b."
		var qualifiers: [String] = []
		var q = start
		while q > 0, s.character(at: q - 1) == 0x2E, qualifiers.count < 2 {
			var e = q - 1, b = e
			if b > 0, s.character(at: b - 1) == syntax.identifierQuote {
				// `이름`
				e = b - 1; b = e
				while b > 0, s.character(at: b - 1) != syntax.identifierQuote { b -= 1 }
				guard b > 0 else { break }
				qualifiers.insert(s.substring(with: NSRange(location: b, length: e - b)), at: 0)
				q = b - 1
			} else {
				while b > 0, isIdent(s.character(at: b - 1)) { b -= 1 }
				guard b < e else { break }
				qualifiers.insert(s.substring(with: NSRange(location: b, length: e - b)), at: 0)
				q = b
			}
		}
		if prefix.isEmpty && qualifiers.isEmpty && !force { return nil }

		let refs = tableRefs(statement, session: session, defaultDB: defaultDB)
		let before = s.substring(with: NSRange(location: min(stmtStart, q), length: q - min(stmtStart, q)))
		let context = lastKeyword(before)
		// FROM·JOIN 뒤에 테이블(과 별칭)을 이미 쳤고 띄어 쓴 뒤 (FROM big wh▮, FROM big a j▮): WHERE·JOIN 같은 다음 낱말
		let afterTable: Bool = {
			guard qualifiers.isEmpty, ["FROM", "JOIN"].contains(context) else { return false }
			let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let last = trimmed.last, last != ",", last != "(" else { return false }
			return !trimmed.uppercased().hasSuffix(context) && before.last?.isWhitespace == true
		}()
		var items: [CompletionItem] = []

		/// 이름이 그대로 쓸 수 있는 식별자면 그대로, 아니면 감싸기 (서버 종류의 문법으로)
		let dialect = session.dialect
		func ident(_ name: String) -> String { dialect.quoteIfNeeded(name, reserved: syntax.reservedWords) }
		func columns(of t: TableInfo) -> [CompletionItem] {
			(session.columns[t.id] ?? []).map {
				CompletionItem(kind: .column, insert: ident($0.name), label: $0.name, detail: $0.type, comment: $0.comment)
			}
		}
		func tableItem(_ t: TableInfo, qualified: Bool) -> CompletionItem {
			let name = qualified ? ident(t.schema) + "." + ident(t.name) : ident(t.name)
			return CompletionItem(kind: t.isView ? .view : .table, insert: name, label: t.name, detail: t.schema, comment: t.comment)
		}

		if qualifiers.count == 2 {
			if let t = findTable(schema: qualifiers[0], name: qualifiers[1], session: session) { items = columns(of: t) }
		} else if let q0 = qualifiers.first {
			if let r = refs.first(where: { $0.alias?.caseInsensitiveCompare(q0) == .orderedSame })
				?? refs.first(where: { $0.table.name == q0 }) ?? refs.first(where: { $0.table.name.caseInsensitiveCompare(q0) == .orderedSame }) {
				items = columns(of: r.table)
			} else if let db = session.databases.first(where: { $0 == q0 }) ?? session.databases.first(where: { $0.caseInsensitiveCompare(q0) == .orderedSame }) {
				items = session.tables.filter { $0.schema == db }.map { tableItem($0, qualified: false) }
			} else if let t = findTable(schema: nil, name: q0, session: session, defaultDB: defaultDB) {
				items = columns(of: t)
			}
		} else {
			let wantsTable = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "DESCRIBE", "DESC", "TRUNCATE"].contains(context)
			if afterTable { items += clauseKeywords.map(keywordItem) }
			if !wantsTable {
				var seen = Set<String>()
				for r in refs where seen.insert(r.table.id).inserted { items += columns(of: r.table) }
			}
			for t in session.tables {
				items.append(tableItem(t, qualified: t.schema != defaultDB))   // 기본 DB 가 없으면 모두 DB.테이블
			}
			items += session.databases.map { CompletionItem(kind: .database, insert: ident($0), label: $0, detail: "DB", comment: "") }
			if !wantsTable {
				items += syntax.completionKeywords.map(keywordItem)
				items += syntax.completionFunctions(kind: session.kind, version: session.version).map { CompletionItem(kind: .function, insert: $0 + "(", label: $0 + "()", detail: "함수", comment: "") }
			}
			if context == "USE" { items = items.filter { $0.kind == .database } }
		}

		// 걸러서 순서 매기기: 이름 앞부분 > 이름 안 > 코멘트 안
		let p = prefix.lowercased()
		let wantsTable = qualifiers.isEmpty && ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "DESCRIBE", "DESC", "TRUNCATE"].contains(context)
		func kindOrder(_ k: CompletionItem.Kind) -> Int {
			if afterTable { return k == .keyword ? 0 : (k == .table || k == .view ? 1 : 3) }
			switch k {
			case .column: return wantsTable ? 5 : 0
			case .table, .view: return wantsTable ? 0 : 1
			case .database: return wantsTable ? 1 : 3
			case .keyword: return 2
			case .function: return 4
			}
		}
		var scored: [(Int, Int, CompletionItem)] = []
		var seen = Set<String>()
		for it in items {
			let rank: Int
			if p.isEmpty { rank = 0 }
			else if it.label.lowercased().hasPrefix(p) { rank = 0 }
			else if p.count >= 2, it.label.lowercased().contains(p) { rank = 1 }
			else if !it.comment.isEmpty, it.comment.lowercased().contains(p) { rank = 2 }
			else { continue }
			// 다른 DB 의 같은 이름 테이블은 따로, 같은 이름 키워드·함수(LEFT 등)는 하나만
			let key = "\(it.kind == .function ? "f" : "x")|\(it.insert.trimmingCharacters(in: .whitespaces))"
			guard seen.insert(key).inserted else { continue }
			// 다른 DB 테이블은 지금 DB 것보다 뒤로
			let far = (it.kind == .table || it.kind == .view) && it.insert.contains(".") ? 1 : 0
			scored.append((rank, kindOrder(it.kind) * 2 + far, it))
		}
		// 이미 다 친 키워드 하나만 남으면 띄우지 않는다 (SELECT 다 치고 나서 목록이 남는 것)
		if scored.count == 1, scored[0].2.kind == .keyword, scored[0].2.label.lowercased() == p { return nil }
		scored.sort { a, b in
			if a.0 != b.0 { return a.0 < b.0 }
			if a.1 != b.1 { return a.1 < b.1 }
			if a.2.label.count != b.2.label.count { return a.2.label.count < b.2.label.count }
			return a.2.label < b.2.label
		}
		let list = scored.prefix(200).map(\.2)
		guard !list.isEmpty else { return nil }
		return Result(range: NSRange(location: start, length: caret - start), items: Array(list))
	}

	/// 문장에서 커서 앞 마지막 키워드 (FROM, SELECT …)
	private static func lastKeyword(_ s: String) -> String {
		let interesting: Set<String> = ["SELECT", "FROM", "JOIN", "WHERE", "ON", "AND", "OR", "BY", "SET", "UPDATE", "INTO", "TABLE",
		                                "VALUES", "HAVING", "USE", "DESCRIBE", "DESC", "TRUNCATE"]
		let words = s.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
		for w in words.reversed() {
			let u = w.uppercased()
			if interesting.contains(u) { return u }
		}
		return ""
	}

	struct TableRef { var table: TableInfo; var alias: String? }

	/// FROM·JOIN·UPDATE·INTO 뒤의 테이블과 별칭
	@MainActor
	static func tableRefs(_ statement: String, session: Session, defaultDB: String) -> [TableRef] {
		let pattern = #"(?i)\b(?:FROM|JOIN|UPDATE|INTO)\s+(.+?)(?=\b(?:WHERE|ON|SET|GROUP|ORDER|LIMIT|HAVING|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|NATURAL|STRAIGHT_JOIN|VALUES|VALUE|USING|UNION|SELECT|FOR|WINDOW)\b|;|\)|$)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
		let syntax = session.dialect.syntax
		let quote = CharacterSet(charactersIn: syntax.identifierQuoteString)
		let ns = statement as NSString
		var refs: [TableRef] = []
		for m in re.matches(in: statement, range: NSRange(location: 0, length: ns.length)) {
			let list = ns.substring(with: m.range(at: 1))
			for item in list.split(separator: ",") {
				let tokens = tokenize(String(item), syntax.identifierQuoteCharacter)
				guard let first = tokens.first else { continue }
				let nameParts = first.split(separator: ".", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: quote) }
				var alias: String?
				var rest = Array(tokens.dropFirst())
				if rest.first?.uppercased() == "AS" { rest.removeFirst() }
				if let a = rest.first, !syntax.reservedWords.contains(a.uppercased()), !a.hasPrefix("(") { alias = a.trimmingCharacters(in: quote) }
				let t = nameParts.count >= 2
					? findTable(schema: nameParts[nameParts.count - 2], name: nameParts.last!, session: session)
					: findTable(schema: nil, name: nameParts[0], session: session, defaultDB: defaultDB)
				if let t { refs.append(TableRef(table: t, alias: alias)) }
			}
		}
		return refs
	}

	/// 공백으로 나누되 이름 따옴표(백틱) 안 공백은 이어 붙인다
	private static func tokenize(_ s: String, _ quote: Character) -> [String] {
		var out: [String] = [], cur = "", inTick = false
		for ch in s {
			if ch == quote { inTick.toggle(); cur.append(ch) }
			else if ch.isWhitespace && !inTick { if !cur.isEmpty { out.append(cur); cur = "" } }
			else { cur.append(ch) }
		}
		if !cur.isEmpty { out.append(cur) }
		return out
	}

	/// 이름으로 테이블 찾기: DB 를 주면 그 DB, 아니면 지금 DB → 어디든 하나뿐인 것. 대소문자는 같은 것 먼저
	@MainActor
	static func findTable(schema: String?, name: String, session: Session, defaultDB: String = "") -> TableInfo? {
		let all = session.tables
		if let schema {
			return all.first { $0.schema == schema && $0.name == name }
				?? all.first { $0.schema.caseInsensitiveCompare(schema) == .orderedSame && $0.name.caseInsensitiveCompare(name) == .orderedSame }
		}
		if !defaultDB.isEmpty {
			if let t = all.first(where: { $0.schema == defaultDB && $0.name == name }) { return t }
			if let t = all.first(where: { $0.schema == defaultDB && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return t }
		}
		let exact = all.filter { $0.name == name }
		if exact.count == 1 { return exact[0] }
		let loose = all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
		return loose.count == 1 ? loose[0] : exact.first ?? loose.first
	}
}
