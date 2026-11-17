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
			let lit = { (s: String) in literal(.text(s)) }
			let r = try await session.query("""
				SELECT ENGINE, TABLE_COLLATION, TABLE_COMMENT, TABLE_ROWS, AVG_ROW_LENGTH, DATA_LENGTH, INDEX_LENGTH, DATA_FREE,
				       AUTO_INCREMENT, ROW_FORMAT, CREATE_TIME, UPDATE_TIME
				  FROM information_schema.TABLES WHERE TABLE_NAME = \(lit(table.name)) AND TABLE_SCHEMA = \(lit(table.schema))
				""").last ?? QueryResult()
			if let v = r.rows.first {
				func s(_ i: Int) -> String { v[safe: i]?.string ?? "" }
				func n(_ i: Int) -> Int64? { v[safe: i]?.string.flatMap { Int64($0) } }
				engine = s(0); collation = s(1); comment = s(2)
				approxRows = n(3); avgRowLength = n(4) ?? 0; dataLength = n(5) ?? 0; indexLength = n(6) ?? 0; dataFree = n(7) ?? 0
				autoIncrement = n(8); rowFormat = s(9); created = s(10); updated = s(11)
			}
			resetEdits()
			createSQL = (try? await session.query("SHOW CREATE TABLE \(table.quoted)").last?.rows.first?[safe: 1]?.string) ?? ""
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
		let r = try await session.query("SHOW INDEX FROM \(table.quoted)").last ?? QueryResult()
		func col(_ name: String) -> Int? { r.columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
		guard let iName = col("Key_name"), let iCol = col("Column_name") else { indexes = []; return }
		let iNonUnique = col("Non_unique"), iSub = col("Sub_part"), iType = col("Index_type"), iCard = col("Cardinality")
		var list: [IndexInfo] = []
		for row in r.rows {
			let name = row[iName].string ?? ""
			var column = row[iCol].string ?? "(식)"
			if let iSub, let sub = row[iSub].string { column += "(\(sub))" }
			if let k = list.firstIndex(where: { $0.name == name }) {
				list[k].columns.append(column)
				continue
			}
			let method = iType.flatMap { row[$0].string } ?? ""
			let kind: IndexInfo.Kind = name == "PRIMARY" ? .primary
				: method == "FULLTEXT" ? .fulltext
				: method == "SPATIAL" ? .spatial
				: (iNonUnique.flatMap { row[$0].string } == "0" ? .unique : .index)
			list.append(IndexInfo(name: name, kind: kind, columns: [column], method: method,
			                      cardinality: iCard.flatMap { row[$0].string }.flatMap { Int64($0) }))
		}
		// FULLTEXT 파서: SHOW CREATE TABLE 의 "FULLTEXT KEY `이름` (…) /*!50100 WITH PARSER `ngram` */"
		if list.contains(where: { $0.kind == .fulltext }), !createSQL.isEmpty {
			let ddl = createSQL
			for line in ddl.split(separator: "\n") where line.contains("WITH PARSER") {
				guard let name = Self.firstQuoted(line.drop { $0 != "`" }),
				      let r = line.range(of: "WITH PARSER "),
				      let parser = Self.firstQuoted(line[r.upperBound...].drop { $0 != "`" }) else { continue }
				if let k = list.firstIndex(where: { $0.name == name }) { list[k].parser = parser }
			}
		}
		// 기본 키가 맨 위
		indexes = list.filter { $0.kind == .primary } + list.filter { $0.kind != .primary }
	}

	/// 외래 키: information_schema 에서 나가는 키와 들어오는 키
	@MainActor
	private func loadForeignKeys() async throws {
		guard let session, !table.isView else { foreignKeys = []; referencedBy = []; return }
		let lit = { (s: String) in literal(.text(s)) }
		func read(_ whereSQL: String) async throws -> [ForeignKeyInfo] {
			let r = try await session.query("""
				SELECT k.CONSTRAINT_NAME, k.TABLE_SCHEMA, k.TABLE_NAME, k.COLUMN_NAME,
				       k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.DELETE_RULE, r.UPDATE_RULE
				  FROM information_schema.KEY_COLUMN_USAGE k
				  JOIN information_schema.REFERENTIAL_CONSTRAINTS r
				    ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
				 WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND \(whereSQL)
				 ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
				""").last ?? QueryResult()
			var list: [ForeignKeyInfo] = []
			for row in r.rows {
				func s(_ i: Int) -> String { row[safe: i]?.string ?? "" }
				if let k = list.indices.last, list[k].name == s(0), list[k].schema == s(1), list[k].table == s(2) {
					list[k].columns.append(s(3)); list[k].refColumns.append(s(6))
				} else {
					list.append(ForeignKeyInfo(name: s(0), schema: s(1), table: s(2), columns: [s(3)], refSchema: s(4), refTable: s(5),
					                           refColumns: [s(6)], onDelete: s(7), onUpdate: s(8)))
				}
			}
			return list
		}
		foreignKeys = try await read("k.TABLE_SCHEMA = \(lit(table.schema)) AND k.TABLE_NAME = \(lit(table.name))")
		referencedBy = try await read("k.REFERENCED_TABLE_SCHEMA = \(lit(table.schema)) AND k.REFERENCED_TABLE_NAME = \(lit(table.name))")
	}

	/// ADD CONSTRAINT … FOREIGN KEY 절 (ALTER TABLE 뒤에 붙인다)
	func addForeignKeyClause(_ fk: ForeignKeyInfo) -> String {
		let named = fk.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "CONSTRAINT \(Self.ident(fk.name)) "
		let ref = (fk.refSchema == table.schema ? "" : Self.ident(fk.refSchema) + ".") + Self.ident(fk.refTable)
		return "ADD \(named)FOREIGN KEY (\(fk.columns.map(Self.ident).joined(separator: ", "))) REFERENCES \(ref) (\(fk.refColumns.map(Self.ident).joined(separator: ", "))) ON DELETE \(fk.onDelete) ON UPDATE \(fk.onUpdate)"
	}
	func addForeignKeySQL(_ fk: ForeignKeyInfo) -> String { "ALTER TABLE \(table.quoted) " + addForeignKeyClause(fk) }
	func dropForeignKeySQL(_ fk: ForeignKeyInfo) -> String { "ALTER TABLE \(table.quoted) DROP FOREIGN KEY \(Self.ident(fk.name))" }

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
		if let r = try? await session.query("SELECT COUNT(*) FROM \(table.quoted)").last, let v = r.rows.first?.first?.string {
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
		if editEngine != engine, !editEngine.isEmpty { parts.append("ENGINE=\(editEngine)") }
		if editCollation != collation, !editCollation.isEmpty {
			let cs = catalog.charset(of: editCollation) ?? editCharset
			parts.append(convertColumns ? "CONVERT TO CHARACTER SET \(cs) COLLATE \(editCollation)"
			                            : "DEFAULT CHARACTER SET \(cs) COLLATE \(editCollation)")
		}
		if editComment != comment { parts.append("COMMENT=\(literal(.text(editComment)))") }
		return parts.isEmpty ? nil : "ALTER TABLE \(table.quoted) " + parts.joined(separator: ", ")
	}

	func autoIncrementSQL(_ n: Int64) -> String { "ALTER TABLE \(table.quoted) AUTO_INCREMENT = \(n)" }

	func dropIndexSQL(_ index: IndexInfo) -> String {
		index.kind == .primary ? "ALTER TABLE \(table.quoted) DROP PRIMARY KEY"
			: "ALTER TABLE \(table.quoted) DROP INDEX \(Self.ident(index.name))"
	}

	/// 인덱스 컬럼 한 칸: 이름, 접두 길이 "name(10)" → `name`(10), 식 "(…)" 은 그대로
	static func indexPart(_ s: String) -> String {
		if s.hasPrefix("(") { return s }
		if let m = s.firstMatch(of: /^(.+)\((\d+)\)$/) { return ident(String(m.1)) + "(\(m.2))" }
		return ident(s)
	}

	/// 인덱스 컬럼 칸의 컬럼 이름 (접두 길이를 뗀다. 식이면 nil)
	static func indexColumnName(_ s: String) -> String? {
		if s.hasPrefix("(") { return nil }
		if let m = s.firstMatch(of: /^(.+)\((\d+)\)$/) { return String(m.1) }
		return s
	}

	/// 인덱스 고치기: MySQL 에는 인덱스를 고치는 명령이 없어 지우기와 만들기를 한 ALTER 로 (중간에 실패해도 인덱스가 사라진 채 남지 않는다)
	func editIndexSQL(_ old: IndexInfo, kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		let drop = old.kind == .primary ? "DROP PRIMARY KEY" : "DROP INDEX \(Self.ident(old.name))"
		let add = Self.addIndexSQL(table: table, kind: kind, name: name, columns: columns, parser: parser)
		let prefix = "ALTER TABLE \(table.quoted) "
		return prefix + drop + ", " + (add.hasPrefix(prefix) ? String(add.dropFirst(prefix.count)) : add)
	}

	static func addIndexSQL(table: TableInfo, kind: IndexInfo.Kind, name: String, columns: [String], parser: String? = nil) -> String {
		let cols = columns.map(indexPart).joined(separator: ", ")
		let n = name.trimmingCharacters(in: .whitespaces)
		let named = n.isEmpty ? "" : " " + ident(n)
		switch kind {
		case .primary: return "ALTER TABLE \(table.quoted) ADD PRIMARY KEY (\(cols))"
		case .unique: return "ALTER TABLE \(table.quoted) ADD UNIQUE INDEX\(named) (\(cols))"
		case .fulltext: return "ALTER TABLE \(table.quoted) ADD FULLTEXT INDEX\(named) (\(cols))" + (parser.map { " WITH PARSER \(ident($0))" } ?? "")
		case .spatial: return "ALTER TABLE \(table.quoted) ADD SPATIAL INDEX\(named) (\(cols))"
		case .index: return "ALTER TABLE \(table.quoted) ADD INDEX\(named) (\(cols))"
		}
	}

	/// "`a``b` …" → a`b (맨 앞 백틱 이름)
	static func firstQuoted(_ s: Substring) -> String? {
		guard s.first == "`" else { return nil }
		var out = ""
		var i = s.index(after: s.startIndex)
		while i < s.endIndex {
			if s[i] == "`" {
				let n = s.index(after: i)
				if n < s.endIndex, s[n] == "`" { out.append("`"); i = s.index(after: n); continue }
				return out
			}
			out.append(s[i])
			i = s.index(after: i)
		}
		return nil
	}

	static func ident(_ s: String) -> String { "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }

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
