import SwiftUI

/// SQL 글자에 색: 키워드·문자열·숫자·주석 (보기 전용, 테이블 정보 패널의 CREATE 문 등)
enum SQLHighlight {
	private static let keywords: Set<String> = Set("""
		CREATE TABLE VIEW KEY PRIMARY UNIQUE FULLTEXT SPATIAL INDEX CONSTRAINT FOREIGN REFERENCES ON DELETE UPDATE CASCADE RESTRICT
		SET NULL NOT DEFAULT AUTO_INCREMENT COMMENT CHARACTER COLLATE ENGINE CHARSET ROW_FORMAT UNSIGNED ZEROFILL GENERATED ALWAYS
		AS VIRTUAL STORED USING BTREE HASH WITH PARSER ALGORITHM DEFINER SQL SECURITY INVOKER SELECT FROM WHERE JOIN LEFT RIGHT INNER
		OUTER AND OR IN IS LIKE CURRENT_TIMESTAMP CHECK OPTION CASCADED LOCAL PARTITION BY RANGE LIST VALUES LESS THAN MAXVALUE
		INT TINYINT SMALLINT MEDIUMINT BIGINT DECIMAL NUMERIC FLOAT DOUBLE BIT BOOL BOOLEAN DATE DATETIME TIMESTAMP TIME YEAR CHAR
		VARCHAR BINARY VARBINARY TINYBLOB BLOB MEDIUMBLOB LONGBLOB TINYTEXT TEXT MEDIUMTEXT LONGTEXT ENUM JSON GEOMETRY POINT
		""".split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))

	static func attributed(_ sql: String) -> AttributedString {
		var out = AttributedString()
		let chars = Array(sql)
		var i = 0
		func add(_ s: String, _ color: Color?) {
			var a = AttributedString(s)
			if let color { a.foregroundColor = color }
			out += a
		}
		while i < chars.count {
			let c = chars[i]
			if c == "'" || c == "\"" {
				// 문자열 (\' 와 '' 를 건너뜀)
				var j = i + 1
				while j < chars.count {
					if chars[j] == "\\" { j += 2; continue }
					if chars[j] == c { if j + 1 < chars.count, chars[j + 1] == c { j += 2; continue }; break }
					j += 1
				}
				let end = min(j + 1, chars.count)
				add(String(chars[i..<end]), Color(nsColor: .systemRed)); i = end
			} else if c == "`" {
				var j = i + 1
				while j < chars.count, chars[j] != "`" { j += 1 }
				let end = min(j + 1, chars.count)
				add(String(chars[i..<end]), nil); i = end
			} else if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
				var j = i + 2
				while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
				let end = min(j + 2, chars.count)
				add(String(chars[i..<end]), .secondary); i = end
			} else if c.isLetter || c == "_" {
				var j = i
				while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
				let w = String(chars[i..<j])
				add(w, keywords.contains(w.uppercased()) ? Color(nsColor: .systemBlue) : nil); i = j
			} else if c.isNumber {
				var j = i
				while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
				add(String(chars[i..<j]), Color(nsColor: .systemOrange)); i = j
			} else {
				add(String(c), nil); i += 1
			}
		}
		return out
	}
}
