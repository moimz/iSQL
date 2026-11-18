import Foundation
import Observation

/// 서버 전체에서 고를 수 있는 엔진·문자셋·콜레이션 (접속마다 한 번 읽는다)
struct ServerCatalog {
	var engines: [String] = []
	/// 문자셋 → 기본 콜레이션
	var charsets: [(name: String, defaultCollation: String)] = []
	/// 콜레이션 → 문자셋
	var collations: [(name: String, charset: String)] = []

	func charset(of collation: String) -> String? { collations.first { $0.name == collation }?.charset }
	func collations(for charset: String) -> [String] { collations.filter { $0.charset == charset }.map(\.name) }
	func defaultCollation(for charset: String) -> String? { charsets.first { $0.name == charset }?.defaultCollation }
	/// 켜져 있는 전문 검색 파서 (MySQL 5.7.6+ 는 ngram 이 기본으로 들어 있다. MariaDB 는 없음)
	var fulltextParsers: [String] = []
	/// @@ngram_token_size (n-gram 한 조각 글자 수)
	var ngramTokenSize: Int?
}

/// 인덱스 하나 (SHOW INDEX 의 여러 줄을 이름으로 묶은 것)
struct IndexInfo: Identifiable, Hashable {
	enum Kind: String, CaseIterable { case primary = "PRIMARY", unique = "UNIQUE", index = "INDEX", fulltext = "FULLTEXT", spatial = "SPATIAL" }
	var name: String
	var kind: Kind
	/// 컬럼 (접두 길이가 있으면 "name(10)")
	var columns: [String]
	var method: String
	/// FULLTEXT 파서 (WITH PARSER ngram). SHOW INDEX 에는 안 나와 SHOW CREATE TABLE 에서 읽는다
	var parser: String? = nil
	var cardinality: Int64?
	var id: String { name }
}

/// 외래 키 하나 (나가는 키: 이 테이블 → 참조 테이블 / 들어오는 키: 다른 테이블 → 이 테이블)
struct ForeignKeyInfo: Identifiable, Hashable {
	var name: String
	/// 키가 있는 테이블 (들어오는 키 목록에서 쓴다)
	var schema: String
	var table: String
	var columns: [String]
	var refSchema: String
	var refTable: String
	var refColumns: [String]
	var onDelete: String
	var onUpdate: String
	var id: String { schema + "." + table + "." + name }
	static let rules = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION", "SET DEFAULT"]
}

/// 구조 보기의 "테이블 정보" 옆 패널: 설정(엔진·문자셋·콜레이션·코멘트), 통계, 인덱스
@Observable
final class TableInspector {
	let table: TableInfo
	@ObservationIgnored private weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }

	private(set) var loading = false
	private(set) var error: String?

	// 지금 서버 값
	private(set) var engine = ""
	private(set) var collation = ""
	private(set) var comment = ""
	var charset: String { session?.catalog.charset(of: collation) ?? "" }

	// 고치는 중인 값 (적용 전)
	var editEngine = ""
	var editCharset = ""
	var editCollation = ""
	var editComment = ""
	/// 문자셋을 바꿀 때 기존 컬럼도 변환 (CONVERT TO). 끄면 기본값만 바꾼다
	var convertColumns = false

	// 통계
	private(set) var approxRows: Int64?
	private(set) var exactRows: Int64?
	private(set) var counting = false
	private(set) var dataLength: Int64 = 0
	private(set) var indexLength: Int64 = 0
	private(set) var dataFree: Int64 = 0
	private(set) var avgRowLength: Int64 = 0
	private(set) var autoIncrement: Int64?
	private(set) var rowFormat = ""
	private(set) var created = ""
	private(set) var updated = ""

	private(set) var indexes: [IndexInfo] = []
	/// SHOW CREATE TABLE (뷰면 CREATE VIEW)
	private(set) var createSQL = ""
	/// 이 테이블의 외래 키 (나가는 키)
	private(set) var foreignKeys: [ForeignKeyInfo] = []
	/// 이 테이블을 참조하는 다른 테이블의 외래 키 (들어오는 키, 보기만)
	private(set) var referencedBy: [ForeignKeyInfo] = []

	/// 실행 중인 ALTER
	private(set) var applying = false

	init(table: TableInfo, session: Session) {
		self.table = table
		self.session = session
	}

	var catalog: ServerCatalog { session?.catalog ?? ServerCatalog() }

	var hasEdits: Bool {
		editEngine != engine || editCollation != collation || editComment != comment
	}

	// MARK: 읽기

	@MainActor
	func load() async {
		guard let session, !loading else { return }
		loading = true
		error = nil
		defer { loading = false }
		do {
			try await session.loadCatalogIfNeeded()
			if let v = try await session.meta.tableStatus(session.query, table) {
				engine = v.engine; collation = v.collation; comment = v.comment
				approxRows = v.approxRows; avgRowLength = v.avgRowLength; dataLength = v.dataLength; indexLength = v.indexLength; dataFree = v.dataFree
				autoIncrement = v.autoIncrement; rowFormat = v.rowFormat; created = v.created; updated = v.updated
			}
			resetEdits()
			createSQL = ((try? await session.meta.createStatement(session.query, .table, schema: table.schema, name: table.name)) ?? nil) ?? ""
			// information_schema 의 AUTO_INCREMENT 는 MySQL 8 에서 하루까지 묵을 수 있다 → CREATE 문의 값을 쓴다
			if let m = createSQL.firstMatch(of: /\)[^)]*\bAUTO_INCREMENT=(\d+)/) { autoIncrement = Int64(m.1) }
			try await loadIndexes()
			try await loadForeignKeys()
		} catch {
			self.error = error.localizedDescription
		}
		Task { await countRows() }
	}

	@MainActor
	private func loadIndexes() async throws {
		guard let session else { return }
		indexes = try await session.meta.indexes(session.query, table, createSQL: createSQL)
	}

	/// 외래 키: information_schema 에서 나가는 키와 들어오는 키
	@MainActor
	private func loadForeignKeys() async throws {
		guard let session, !table.isView else { foreignKeys = []; referencedBy = []; return }
		foreignKeys = try await session.meta.foreignKeys(session.query, schema: table.schema, table: table.name, incoming: false)
		referencedBy = try await session.meta.foreignKeys(session.query, schema: table.schema, table: table.name, incoming: true)
	}

	/// ADD CONSTRAINT … FOREIGN KEY 절 (ALTER TABLE 뒤에 붙인다)
	func addForeignKeyClause(_ fk: ForeignKeyInfo) -> String {
		dialect.addForeignKeyClause(fk, schema: table.schema)
	}
	func addForeignKeySQL(_ fk: ForeignKeyInfo) -> String { dialect.alterTable(dialect.quote(table: table), [addForeignKeyClause(fk)]) }
	func dropForeignKeySQL(_ fk: ForeignKeyInfo) -> String { dialect.alterTable(dialect.quote(table: table), [dialect.dropForeignKeyClause(fk.name)]) }

	/// 외래 키 고치기: MySQL 은 같은 이름을 한 ALTER 에서 지우고 다시 만들 수 없다(1826) → 지우고 만들기를 따로,
	/// 만들기가 실패하면 원래 키를 다시 만들어 되돌린다. 실패 글자 (성공이면 nil)
	@MainActor
	func editForeignKey(_ old: ForeignKeyInfo, to new: ForeignKeyInfo) async -> String? {
		guard let session else { return "접속이 끊겼습니다" }
		applying = true
		defer { applying = false }
		do { _ = try await session.query(dropForeignKeySQL(old)) } catch { return error.localizedDescription }
		do {
			_ = try await session.query(addForeignKeySQL(new))
		} catch {
			let message = error.localizedDescription
			_ = try? await session.query(addForeignKeySQL(old))
			await load()
			return message + "\n(원래 외래 키로 되돌렸습니다)"
		}
		await load()
		return nil
	}

	/// 정확한 행 수 (큰 테이블은 오래 걸릴 수 있어 따로 돈다)
	@MainActor
	func countRows() async {
		guard let session, !counting, !table.isView else { return }
		counting = true
		defer { counting = false }
		if let r = try? await session.query("SELECT COUNT(*) FROM \(dialect.quote(table: table))").last, let v = r.rows.first?.first?.string {
			exactRows = Int64(v)
		}
	}

	func resetEdits() {
		editEngine = engine
		editCollation = collation
		editCharset = session?.catalog.charset(of: collation) ?? ""
		editComment = comment
		convertColumns = false
	}

	/// 문자셋을 고르면 콜레이션은 그 문자셋의 기본값으로
	func pickCharset(_ cs: String) {
		editCharset = cs
		if catalog.charset(of: editCollation) != cs { editCollation = catalog.defaultCollation(for: cs) ?? catalog.collations(for: cs).first ?? "" }
	}

	// MARK: 바꾸기

	/// 설정을 바꾸는 ALTER (바뀐 것만). 없으면 nil
	var alterSQL: String? {
		var parts: [String] = []
		if editEngine != engine, !editEngine.isEmpty { parts.append(dialect.engineClause(editEngine)) }
		if editCollation != collation, !editCollation.isEmpty {
			let cs = catalog.charset(of: editCollation) ?? editCharset
			parts.append(dialect.charsetClause(cs, collation: editCollation, convert: convertColumns))
		}
		if editComment != comment { parts.append(dialect.tableCommentClause(editComment)) }
		return parts.isEmpty ? nil : dialect.alterTable(dialect.quote(table: table), parts)
	}

	func autoIncrementSQL(_ n: Int64) -> String { dialect.alterTable(dialect.quote(table: table), [dialect.autoIncrementClause(n)]) }

	func dropIndexSQL(_ index: IndexInfo) -> String {
		dialect.alterTable(dialect.quote(table: table), [dialect.dropIndexClause(index)])
	}

	/// 인덱스 컬럼 칸의 컬럼 이름 (접두 길이를 뗀다. 식이면 nil)
	static func indexColumnName(_ s: String) -> String? {
		if s.hasPrefix("(") { return nil }
		if let m = s.firstMatch(of: /^(.+)\((\d+)\)$/) { return String(m.1) }
		return s
	}

	/// 인덱스 고치기: MySQL 에는 인덱스를 고치는 명령이 없어 지우기와 만들기를 한 ALTER 로 (중간에 실패해도 인덱스가 사라진 채 남지 않는다)
	func editIndexSQL(_ old: IndexInfo, kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		dialect.alterTable(dialect.quote(table: table), [dialect.dropIndexClause(old),
		                   dialect.addIndexClause(kind: kind, name: name, columns: columns, parser: parser)])
	}

	static func addIndexSQL(table: TableInfo, kind: IndexInfo.Kind, name: String, columns: [String], parser: String? = nil, dialect: any SQLDialect) -> String {
		dialect.alterTable(dialect.quote(table: table), [dialect.addIndexClause(kind: kind, name: name, columns: columns, parser: parser)])
	}

	/// ALTER 하나를 실행하고 다시 읽는다 (사이드바 코멘트·구조의 키도 바뀌므로 스키마도). 실패하면 오류 글자
	@MainActor
	func run(_ sql: String) async -> String? {
		guard let session else { return "접속이 끊겼습니다" }
		applying = true
		defer { applying = false }
		do {
			_ = try await session.query(sql)
		} catch {
			return error.localizedDescription
		}
		exactRows = nil
		await load()
		try? await session.loadSchema()
		return nil
	}
}
