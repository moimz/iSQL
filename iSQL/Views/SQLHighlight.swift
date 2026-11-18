import SwiftUI
import AppKit

/// SQL 글자에 색: 키워드·문자열·숫자·주석. 보기 전용(CREATE 문)과 편집기(쿼리 패널·루틴 탭)가 같은 규칙을 쓴다
enum SQLHighlight {
	enum Kind { case keyword, string, number, comment }


	/// 색칠할 자리 (UTF-16 범위). 이름(`…`)은 칠하지 않는다
	static func tokens(_ ns: NSString, _ syntax: SQLSyntax, limit: Int = .max) -> [(NSRange, Kind)] {
		let n = min(ns.length, limit)
		var out: [(NSRange, Kind)] = []
		var buf = [unichar](repeating: 0, count: n)
		ns.getCharacters(&buf, range: NSRange(location: 0, length: n))
		func isWord(_ c: unichar) -> Bool {
			if c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 36 { return true }
			guard c >= 128, let s = Unicode.Scalar(c) else { return false }
			return CharacterSet.letters.contains(s)
		}
		var i = 0
		while i < n {
			let c = buf[i]
			if syntax.stringQuotes.contains(c) {   // ' "
				var j = i + 1
				while j < n {
					if buf[j] == 92 && syntax.backslashEscapes { j += 2; continue }   // \
					if buf[j] == c { if j + 1 < n, buf[j + 1] == c { j += 2; continue }; break }
					j += 1
				}
				let end = min(j + 1, n)
				out.append((NSRange(location: i, length: end - i), .string)); i = end
			} else if c == syntax.identifierQuote {   // `
				var j = i + 1
				while j < n, buf[j] != c { j += 1 }
				i = min(j + 1, n)
			} else if c == 47, i + 1 < n, buf[i + 1] == 42 {   // /*
				var j = i + 2
				while j + 1 < n, !(buf[j] == 42 && buf[j + 1] == 47) { j += 1 }
				let end = min(j + 2, n)
				out.append((NSRange(location: i, length: end - i), .comment)); i = end
			} else if (c == 35 && syntax.hashComments) || (c == 45 && i + 1 < n && buf[i + 1] == 45) {   // # 또는 --
				var j = i
				while j < n, buf[j] != 10 { j += 1 }
				out.append((NSRange(location: i, length: j - i), .comment)); i = j
			} else if isWord(c) && !(c >= 48 && c <= 57) {
				var j = i
				while j < n, isWord(buf[j]) { j += 1 }
				// 키워드는 영문뿐이라 짧은 낱말만 확인 (앞이 . 이면 이름: t.name)
				if j - i <= 20, !(i > 0 && buf[i - 1] == 46) {
					let w = ns.substring(with: NSRange(location: i, length: j - i)).uppercased()
					if syntax.highlightKeywords.contains(w) { out.append((NSRange(location: i, length: j - i), .keyword)) }
				}
				i = j
			} else if c >= 48 && c <= 57 {
				var j = i
				while j < n, (buf[j] >= 48 && buf[j] <= 57) || buf[j] == 46 { j += 1 }
				// 이름 안의 숫자(t1)가 아닐 때만
				if !(i > 0 && isWord(buf[i - 1])) { out.append((NSRange(location: i, length: j - i), .number)) }
				i = j
			} else {
				i += 1
			}
		}
		return out
	}

	static func color(_ k: Kind) -> NSColor {
		switch k {
		case .keyword: .systemBlue
		case .string: .systemRed
		case .number: .systemOrange
		case .comment: .secondaryLabelColor
		}
	}

	/// 보기 전용 글
	static func attributed(_ sql: String, _ syntax: SQLSyntax) -> AttributedString {
		// SwiftUI Text 는 AppKit 색 속성을 쓰지 않아 SwiftUI 색으로 넣는다
		var a = AttributedString(sql)
		for (r, k) in tokens(sql as NSString, syntax) {
			guard let sr = Range(r, in: sql), let ar = Range(sr, in: a) else { continue }
			a[ar].foregroundColor = Color(nsColor: color(k))
		}
		return a
	}

	/// 편집기 글을 칠한다: 글자색만 바꾸고(실행 취소에 남지 않음) 글꼴·커서는 그대로. 아주 긴 글은 앞부분만
	@MainActor
	static func apply(to tv: NSTextView, _ syntax: SQLSyntax) {
		guard let storage = tv.textStorage else { return }
		let ns = storage.string as NSString
		let all = NSRange(location: 0, length: ns.length)
		storage.beginEditing()
		storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
		for (r, k) in tokens(ns, syntax, limit: 300_000) { storage.addAttribute(.foregroundColor, value: color(k), range: r) }
		storage.endEditing()
		tv.typingAttributes[.foregroundColor] = NSColor.labelColor
	}

	// MARK: 줄바꿈 (뷰 정의처럼 한 줄로 온 SELECT 를 읽기 좋게)

	/// 괄호 밖의 FROM·WHERE·JOIN·GROUP BY·ORDER BY·HAVING·LIMIT·UNION 앞에서 줄을 나누고,
	/// SELECT 목록의 쉼표 뒤에서 들여 줄을 나눈다. 글자·이름·주석 안은 건드리지 않는다
	static func format(_ sql: String, _ syntax: SQLSyntax) -> String {
		let ns = sql as NSString
		let n = ns.length
		// 건드리면 안 되는 범위: 글자·주석 + 이름(`…`)
		var skip = tokens(ns, syntax).filter { $0.1 == .string || $0.1 == .comment }.map(\.0)
		do {
			var i = 0
			while i < n {
				if ns.character(at: i) == syntax.identifierQuote {
					var j = i + 1
					while j < n, ns.character(at: j) != syntax.identifierQuote { j += 1 }
					skip.append(NSRange(location: i, length: min(j + 1, n) - i)); i = j + 1
				} else { i += 1 }
			}
		}
		func skipped(_ p: Int) -> Bool { skip.contains { NSLocationInRange(p, $0) } }
		let breakBefore: Set<String> = ["FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "STRAIGHT_JOIN"]
		let joinMods: Set<String> = ["LEFT", "RIGHT", "INNER", "CROSS", "OUTER", "NATURAL"]
		var out = ""
		var depth = 0
		var inSelectList = false
		var prevWord = ""
		var i = 0
		while i < n {
			let c = ns.character(at: i)
			if skipped(i) {
				if let r = skip.first(where: { NSLocationInRange(i, $0) }) {
					out += ns.substring(with: NSRange(location: i, length: NSMaxRange(r) - i)); i = NSMaxRange(r); continue
				}
			}
			if c == 40 { depth += 1 } else if c == 41 { depth = max(0, depth - 1) }
			let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
			if isLetter {
				var j = i
				while j < n, let s = Unicode.Scalar(ns.character(at: j)), CharacterSet.alphanumerics.contains(s) || s == "_" { j += 1 }
				let word = ns.substring(with: NSRange(location: i, length: j - i))
				let up = word.uppercased()
				if depth == 0 {
					let breaks = breakBefore.contains(up) && !(up == "JOIN" && joinMods.contains(prevWord))
						&& !(joinMods.contains(up) && joinMods.contains(prevWord))
					if breaks || (up == "SELECT" && prevWord == "AS") {
						while out.hasSuffix(" ") { out.removeLast() }
						if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
					}
					if up == "SELECT" { inSelectList = true } else if up == "FROM" { inSelectList = false }
				}
				out += word
				prevWord = up
				i = j
				continue
			}
			if c == 44, depth == 0, inSelectList {   // ,
				out += ",\n\t"
				i += 1
				while i < n, ns.character(at: i) == 32 { i += 1 }
				continue
			}
			out += String(utf16CodeUnits: [c], count: 1)
			i += 1
		}
		return out
	}
}
