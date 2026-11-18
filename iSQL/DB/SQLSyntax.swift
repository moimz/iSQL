import Foundation

/// SQL 글자를 읽는 규칙 (문장 나누기·색칠·자동 완성·위험 문장 판단이 쓴다). DB 종류마다 dialect.syntax 로 준다
struct SQLSyntax: Sendable {
	/// 이름을 감싸는 글자 (UTF-16)
	var identifierQuote: unichar
	/// 문자열 따옴표 (UTF-16)
	var stringQuotes: Set<unichar>
	/// 따옴표 안의 \ 가 다음 글자를 살린다
	var backslashEscapes: Bool
	/// # 로 시작하는 줄 주석
	var hashComments: Bool
	/// SQL 파일의 "DELIMITER x" 줄로 문장 구분자를 바꾼다 (mysql 클라이언트·mysqldump 방식)
	var delimiterCommand: Bool
	/// 색칠할 키워드 (대문자)
	var highlightKeywords: Set<String>
	/// 자동 완성 키워드·함수
	var completionKeywords: [String]
	var completionFunctions: [String]
	/// 자동 완성에서 그대로 쓰면 안 되는 이름 (키워드 + 이것들, 대문자)
	var reservedWords: Set<String>

	/// 이름을 감싸는 글자
	var identifierQuoteString: String { String(utf16CodeUnits: [identifierQuote], count: 1) }
	var identifierQuoteCharacter: Character { Character(identifierQuoteString) }
	/// 문자열이나 이름을 여는 글자인지
	func opensQuote(_ c: unichar) -> Bool { c == identifierQuote || stringQuotes.contains(c) }
}
