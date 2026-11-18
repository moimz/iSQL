import Foundation

// MARK: - 결과 타입 (모든 연결이 같이 쓴다. Column 의 type·charset·flags 는 아직 MySQL 프로토콜 값 그대로)

enum Value: Hashable {
	case null
	case text(String)
	case bytes(Data)

	var string: String? {
		switch self {
		case .null: nil
		case .text(let s): s
		case .bytes(let d): String(data: d, encoding: .utf8) ?? "(\(d.count) 바이트)"
		}
	}
}

struct Column: Hashable {
	var name: String
	var orgName: String
	var table: String
	var orgTable: String
	var schema: String
	var charset: UInt16
	var length: UInt32
	var type: UInt8
	var flags: UInt16
	var decimals: UInt8

	/// 문자셋 63(binary) 이고 BLOB·BINARY 계열이면 바이트로 받는다
	var isBinary: Bool { charset == 63 && [249, 250, 251, 252, 253, 254, 255].contains(type) }
	var isPrimaryKey: Bool { flags & 0x2 != 0 }
	/// JSON 컬럼 (MYSQL_TYPE_JSON 245)
	var isJSON: Bool { type == 245 }
	/// 여러 줄 글자 컬럼: TEXT 계열(바이너리 아닌 BLOB 형)·JSON → 칸 안이 아니라 편집 시트로 고친다
	var isLongText: Bool { isJSON || ([249, 250, 251, 252].contains(type) && !isBinary) }
	var isNumeric: Bool { [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(type) }
}

struct QueryResult {
	var columns: [Column] = []
	var rows: [[Value]] = []
	var affectedRows: UInt64 = 0
	var lastInsertID: UInt64 = 0
	var info = ""

	var isResultSet: Bool { !columns.isEmpty }

	/// 이름으로 값 꺼내기 (작은 결과에서만)
	func string(_ row: Int, _ name: String) -> String? {
		guard let i = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
		return rows[row][i].string
	}
}

