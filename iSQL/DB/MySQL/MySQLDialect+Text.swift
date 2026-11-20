import Foundation

/// MySQL 의 정의 글 다루기·EXPLAIN (1.x 의 RoutineEditor·DatabaseCopy·DatabaseRename 에서 모았다)
extension MySQLDialect {
	var syntax: SQLSyntax { .mysql }

	// MARK: EXPLAIN

	func explain(_ body: String) -> String { "EXPLAIN \(body)" }
	/// 나무 모양 계획 (MySQL 8 의 FORMAT=TREE. MariaDB·옛 MySQL 은 오류 → 부르는 쪽이 표만 쓴다)
	func explainTree(_ body: String) -> String? { mariadb ? nil : "EXPLAIN FORMAT=TREE \(body)" }

	// MARK: 루틴 정의 글

	/// 앞뒤 공백, 끝의 ; 와 DELIMITER 줄을 뗀다 (서버에 보낼 때는 한 문장이라 DELIMITER 가 필요 없다)
	func cleanDefinition(_ s: String) -> String {
		var lines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DELIMITER ") }
		while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
		var t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		for end in ["$$", "//", ";;", ";"] where t.hasSuffix(end) { t = String(t.dropLast(end.count)).trimmingCharacters(in: .whitespacesAndNewlines); break }
		return t
	}

	/// "CREATE … VIEW" → "CREATE OR REPLACE … VIEW"
	func createOrReplace(_ s: String) -> String {
		guard !s.uppercased().contains("OR REPLACE"),
		      let r = s.range(of: #"^\s*CREATE\b"#, options: [.regularExpression, .caseInsensitive]) else { return s }
		return s.replacingCharacters(in: r, with: "CREATE OR REPLACE")
	}

	/// 트리거 본문의 ; 때문에 DELIMITER ;; 로 감싼다 (mysqldump 와 같게). DEFINER 는 빼서 다른 서버 · 계정으로도 넣어지게
	/// MariaDB 는 쓴 그대로의 글을 돌려줘 "CREATE TRIGGER db.이름 … ON db.테이블" 처럼 DB 이름이 남는다 → 머리(FOR EACH ROW 앞)에서만 뺀다 (다른 DB 에도 넣어지게)
	func dumpTrigger(_ ddl: String, name: String, schema: String, drop: Bool) -> String {
		var text = stripDefiner(ddl)
		if let body = text.range(of: #"(?i)\bFOR\s+EACH\s+ROW\b"#, options: .regularExpression) {
			let db = NSRegularExpression.escapedPattern(for: schema)
			let head = String(text[..<body.lowerBound])
				.replacingOccurrences(of: "(?<![\\w`$])(`\(db)`|\(db))\\.", with: "", options: .regularExpression)
			text = head + text[body.lowerBound...]
		}
		return (drop ? "DROP TRIGGER IF EXISTS \(quote(name));\n" : "") + "DELIMITER ;;\n" + text + ";;\nDELIMITER ;\n"
	}

	func stripDefiner(_ s: String) -> String {
		s.replacingOccurrences(of: #"DEFINER\s*=\s*(`[^`]*`|'[^']*'|[^@\s]+)@(`[^`]*`|'[^']*'|\S+)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
	}

	/// CREATE … PROCEDURE `이름` 에서 이름 (DB 가 붙어 있어도)
	func definedName(_ s: String, _ k: RoutineKind) -> String? {
		let pattern = #"\b"# + k.sqlWord + #"\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(?:`[^`]+`|\w+)\s*\.\s*)?(`[^`]+`|\w+)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
		var n = String(s[r])
		if n.hasPrefix("`") { n = String(n.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`") }
		return n
	}

	// MARK: DB 이름 바꾸기·복제

	/// 정의 안의 DB 참조를 새 DB 로: `원본`. 과 따옴표 없는 원본. 둘 다 (프로시저 본문은 쓴 그대로 와서 따옴표가 없을 수 있다)
	func retargetSchema(_ ddl: String, from: String, to: String) -> String {
		let q = quote(_:)
		var s = ddl.replacingOccurrences(of: q(from) + ".", with: q(to) + ".")
		let name = NSRegularExpression.escapedPattern(for: from)
		s = s.replacingOccurrences(of: #"(?<![\w`$.])"# + name + #"\.(?=[`\w])"#, with: NSRegularExpression.escapedTemplate(for: q(to) + "."), options: .regularExpression)
		return s
	}

	/// SHOW CREATE VIEW 를 새 DB 용으로: DEFINER·ALGORITHM 을 빼고(권한 오류 방지), `옛`. 참조를 `새`. 로
	/// DB 를 붙여 읽으면 "VIEW `db`.`v` AS …", 안 붙이면 "VIEW `v` AS …" 로 온다 → 둘 다 " AS " 뒤 본문만 쓴다
	func rewriteViewDefinition(_ ddl: String, name: String, from: String, to: String) -> String {
		let q = quote(_:)
		guard let v = ddl.range(of: " VIEW "), let asAt = ddl.range(of: " AS ", range: v.upperBound..<ddl.endIndex) else { return ddl }
		let body = ddl[asAt.lowerBound...].replacingOccurrences(of: q(from) + ".", with: q(to) + ".")
		return createViewHead("\(q(to)).\(q(name))") + body
	}
}
