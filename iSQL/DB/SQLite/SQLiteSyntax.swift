import Foundation

extension SQLSyntax {
	/// SQLite: "이름" (`이름`·[이름] 도 받지만 쓸 때는 "), '글자' 는 '' 로 (\ 는 그냥 글자), -- 와 /* */ 주석
	static let sqlite: SQLSyntax = {
		let keywords = """
		SELECT FROM WHERE AND OR NOT IN IS NULL LIKE GLOB BETWEEN EXISTS AS ON JOIN LEFT RIGHT INNER OUTER CROSS NATURAL USING \
		GROUP BY ORDER ASC DESC HAVING LIMIT OFFSET DISTINCT UNION ALL EXCEPT INTERSECT INSERT INTO VALUES UPDATE SET DELETE \
		REPLACE CREATE ALTER DROP TABLE VIEW INDEX TRIGGER IF EXISTS PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE CHECK \
		AUTOINCREMENT CASE WHEN THEN ELSE END WITH RECURSIVE BEGIN COMMIT ROLLBACK TRANSACTION PRAGMA EXPLAIN QUERY PLAN \
		VACUUM ANALYZE ATTACH DETACH DATABASE RETURNING CONFLICT IGNORE ABORT FAIL WITHOUT ROWID STRICT COLLATE
		""".split(separator: " ").map(String.init)
		let functions = """
		COUNT SUM TOTAL AVG MIN MAX GROUP_CONCAT ABS COALESCE IFNULL NULLIF IIF INSTR LENGTH LOWER UPPER LTRIM RTRIM TRIM \
		REPLACE SUBSTR SUBSTRING ROUND RANDOM HEX QUOTE TYPEOF PRINTF FORMAT CHAR UNICODE ZEROBLOB DATE TIME DATETIME \
		JULIANDAY STRFTIME UNIXEPOCH JSON JSON_EXTRACT JSON_ARRAY JSON_OBJECT JSON_TYPE JSON_VALID JSON_EACH JSON_TREE \
		JSON_SET JSON_INSERT JSON_REPLACE JSON_REMOVE JSON_ARRAY_LENGTH JSON_GROUP_ARRAY JSON_GROUP_OBJECT ROW_NUMBER RANK \
		DENSE_RANK LAG LEAD LAST_INSERT_ROWID CHANGES
		""".split(separator: " ").map(String.init)
		let highlight = Set(keywords + ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "VARCHAR", "INT", "DATETIME", "TRUE", "FALSE",
		                                "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "TEMP", "TEMPORARY", "VIRTUAL", "STORED",
		                                "GENERATED", "ALWAYS", "BEFORE", "AFTER", "INSTEAD", "OF", "FOR", "EACH", "ROW", "COUNT", "SUM", "AVG", "MIN", "MAX"])
		let any: [SQLKind: ServerVersion] = [.sqlite: ServerVersion(0)]
		var s = SQLSyntax(identifierQuote: 0x22, stringQuotes: [0x27], backslashEscapes: false, hashComments: false, delimiterCommand: false,
		                  highlightKeywords: highlight, completionKeywords: keywords,
		                  functions: functions.map { SQLFunction(name: $0, since: any) },
		                  reservedWords: Set(keywords.map { $0.uppercased() } + ["KEY", "ORDER", "GROUP", "INDEX", "TABLE", "DESC"]))
		s.sqliteTriggers = true
		return s
	}()
}

/// SQLite 트리거 글 나누기
enum SQLiteScript {
	/// CREATE [TEMP] TRIGGER 로 시작했고 아직 끝나지 않았으면 true (그 안의 ; 는 문장 끝이 아니다).
	/// s 는 지금 ; 앞까지의 글. 트리거는 "; END" 다음 ; 에서 끝난다 (sqlite3_complete 와 같게) —
	/// 그냥 END 로 끝나는지만 보면 본문의 CASE … END; 에서 끊긴다. 주석 · 글자 · 따옴표 이름 안은 보지 않는다
	static func insideTrigger(_ s: String) -> Bool {
		let t = s.replacingOccurrences(of: #"(?s)/\*.*?(\*/|$)|--[^\n]*|'(''|[^'])*('|$)|"(""|[^"])*("|$)|`[^`]*(`|$)|\[[^\]]*(\]|$)"#,
		                               with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.range(of: #"^(?i)CREATE\s+(TEMP\s+|TEMPORARY\s+)?TRIGGER\b"#, options: .regularExpression) != nil else { return false }
		return t.range(of: #"(?i);\s*END$"#, options: .regularExpression) == nil
	}
}
