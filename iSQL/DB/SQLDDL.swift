import Foundation

/// 컬럼 위치 (ADD·CHANGE COLUMN 뒤)
enum ColumnPosition {
	case first
	/// 이 컬럼 뒤 (감싸지 않은 이름)
	case after(String)
}

/// 구조를 바꾸는 SQL 만들기 (SQLDialect 의 한 부분). 모두 ; 없이 돌려준다.
/// 이름 인자는 따로 적지 않으면 감싸지 않은 이름, "target" 은 이미 감싼 이름(스키마.이름)
protocol SQLDDL {
	// MARK: DB
	func createDatabase(_ name: String, charset: String, collation: String) -> String
	func dropDatabase(_ name: String) -> String

	// MARK: 테이블·뷰
	/// columns 는 컬럼 정의 줄(columnDefinition(NewColumn)), primaryKey 는 감싼 컬럼 이름
	func createTable(schema: String, name: String, columns: [String], primaryKey: [String],
	                 engine: String, charset: String, collation: String, comment: String) -> String
	/// 엑셀 가져오기의 새 테이블 (정의 줄 그대로, 기본 키·옵션 없음)
	func createTable(schema: String, name: String, definitions: [String]) -> String
	/// 자동 증가 기본 키 컬럼 정의 줄 (엑셀 가져오기 "id 넣기")
	func autoIncrementKeyColumn(_ name: String) -> String
	func createTableLike(_ target: String, like source: String) -> String
	/// "CREATE VIEW 대상" (뒤에 " AS …" 를 붙인다)
	func createViewHead(_ target: String) -> String
	/// 여러 테이블(또는 뷰)을 한 문장으로 지우기
	func drop(_ targets: [String], views: Bool) -> String
	/// 내보내기 파일의 "있으면 지우기"
	func dropIfExists(_ target: String, view: Bool) -> String
	func truncate(_ target: String) -> String
	/// 여러 테이블 이름 바꾸기 (한 문장: 하나라도 실패하면 모두 제자리)
	func renameTables(_ pairs: [(from: String, to: String)]) -> String
	/// SHOW CREATE TABLE 의 "CREATE TABLE `이름`" 을 다른 대상으로 (머리가 다르면 nil)
	func retargetCreateTable(_ ddl: String, name: String, to target: String) -> String?

	// MARK: 루틴
	func dropRoutine(_ kind: RoutineKind, _ target: String) -> String
	func setEventEnabled(_ target: String, _ on: Bool) -> String

	// MARK: 컬럼
	/// 구조 편집기: 이름 뒤에 오는 정의 (int unsigned NOT NULL DEFAULT … COMMENT '…')
	func columnDefinition(_ c: StructColumn) -> String
	/// 새 테이블 시트: 이름까지 넣은 정의 줄
	func columnDefinition(_ c: NewColumn) -> String
	/// 구조 편집기의 기본값 칸 → SQL (식이면 (식))
	func defaultValueSQL(_ d: String, expr: Bool, numeric: Bool) -> String

	// MARK: ALTER TABLE
	/// multiline: 절마다 줄을 바꿔 (구조 편집기 미리 보기)
	func alterTable(_ target: String, _ clauses: [String], multiline: Bool) -> String
	func dropColumn(_ name: String) -> String
	func addColumn(_ name: String, definition: String, position: ColumnPosition?) -> String
	func changeColumn(_ old: String, to name: String, definition: String, position: ColumnPosition?) -> String
	func engineClause(_ engine: String) -> String
	/// convert: 컬럼까지 바꾸기, 아니면 기본값만
	func charsetClause(_ charset: String, collation: String, convert: Bool) -> String
	func tableCommentClause(_ comment: String) -> String
	func autoIncrementClause(_ n: Int64) -> String

	// MARK: 인덱스·외래 키
	/// 인덱스 컬럼 칸 하나: "name(10)" → `name`(10), 식 "(…)" 은 그대로
	func indexPart(_ s: String) -> String
	func dropIndexClause(_ index: IndexInfo) -> String
	/// columns 는 인덱스 컬럼 칸 그대로 (indexPart 로 감싼다)
	func addIndexClause(kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String
	/// schema: 키가 있는 테이블의 스키마 (같으면 참조 테이블에 스키마를 붙이지 않는다)
	func addForeignKeyClause(_ fk: ForeignKeyInfo, schema: String) -> String
	func dropForeignKeyClause(_ name: String) -> String
}

extension SQLDDL {
	func alterTable(_ target: String, _ clauses: [String]) -> String { alterTable(target, clauses, multiline: false) }
}
