import Foundation

/// MySQL 구조 바꾸기 SQL (1.x 의 TableInspector·StructureEditor·새 테이블 시트 등에서 모았다)
extension MySQLDialect {
	// MARK: DB

	func createDatabase(_ name: String, charset: String, collation: String) -> String {
		var s = "CREATE DATABASE " + quote(name)
		if !charset.isEmpty { s += " CHARACTER SET \(charset)" }
		if !collation.isEmpty { s += " COLLATE \(collation)" }
		return s
	}
	func dropDatabase(_ name: String) -> String { "DROP DATABASE " + quote(name) }

	// MARK: 테이블·뷰

	/// CREATE TABLE `db`.`이름` ( 컬럼…, PRIMARY KEY (…) ) ENGINE=… DEFAULT CHARSET=… COLLATE=… COMMENT='…'
	func createTable(schema: String, name: String, columns: [String], primaryKey: [String],
	                 engine: String, charset: String, collation: String, comment: String) -> String {
		var lines = columns.map { "  " + $0 }
		if !primaryKey.isEmpty { lines.append("  PRIMARY KEY (\(primaryKey.joined(separator: ", ")))") }
		var tail = ")"
		if !engine.isEmpty { tail += " ENGINE=\(engine)" }
		if !charset.isEmpty { tail += " DEFAULT CHARSET=\(charset)" }
		if !collation.isEmpty { tail += " COLLATE=\(collation)" }
		if !comment.isEmpty { tail += " COMMENT=" + literal(.text(comment)) }
		return "CREATE TABLE \(quote(schema)).\(quote(name)) (\n" + lines.joined(separator: ",\n") + "\n" + tail
	}
	func createTable(schema: String, name: String, definitions: [String]) -> String {
		"CREATE TABLE \(quote(schema)).\(quote(name)) (\n  " + definitions.joined(separator: ",\n  ") + "\n)"
	}
	func autoIncrementKeyColumn(_ name: String) -> String { "\(quote(name)) BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY" }
	func createTableLike(_ target: String, like source: String) -> String { "CREATE TABLE \(target) LIKE \(source)" }
	func createViewHead(_ target: String) -> String { "CREATE VIEW \(target)" }
	func drop(_ targets: [String], views: Bool) -> String { (views ? "DROP VIEW " : "DROP TABLE ") + targets.joined(separator: ", ") }
	func dropIfExists(_ target: String, view: Bool) -> String { (view ? "DROP VIEW IF EXISTS " : "DROP TABLE IF EXISTS ") + target }
	func truncate(_ target: String) -> String { "TRUNCATE TABLE " + target }
	func renameTables(_ pairs: [(from: String, to: String)]) -> String {
		"RENAME TABLE " + pairs.map { "\($0.from) TO \($0.to)" }.joined(separator: ", ")
	}
	func retargetCreateTable(_ ddl: String, name: String, to target: String) -> String? {
		let head = "CREATE TABLE \(quote(name))"
		guard ddl.hasPrefix(head) else { return nil }
		return "CREATE TABLE \(target)" + ddl.dropFirst(head.count)
	}

	// MARK: 루틴

	func dropRoutine(_ kind: RoutineKind, _ target: String) -> String { "DROP \(kind.sqlWord) \(target)" }
	func setEventEnabled(_ target: String, _ on: Bool) -> String { "ALTER EVENT \(target) \(on ? "ENABLE" : "DISABLE")" }

	// MARK: 컬럼

	/// 이름 뒤에 오는 정의: int unsigned NOT NULL DEFAULT … AUTO_INCREMENT COMMENT '…'
	func columnDefinition(_ c: StructColumn) -> String {
		var s = c.type
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, c.takesLength { s += "(\(len))" }
		if c.isNumeric && c.unsigned { s += " UNSIGNED" }
		if c.isNumeric && c.zerofill { s += " ZEROFILL" }
		if StructColumn.textTypes.contains(c.type), let co = c.collation, !co.isEmpty {
			if let cs = c.charset, !cs.isEmpty { s += " CHARACTER SET \(cs)" }
			s += " COLLATE \(co)"
		}
		if let g = c.generated { s += " GENERATED ALWAYS AS (\(c.generationExpr)) \(g)" }
		s += c.nullable ? " NULL" : " NOT NULL"
		if let d = c.defaultValue, !c.autoIncrement, c.generated == nil { s += " DEFAULT " + defaultValueSQL(d, expr: c.defaultExpr, numeric: c.isNumeric) }
		if !c.onUpdate.isEmpty { s += " " + c.onUpdate }
		if c.autoIncrement { s += " AUTO_INCREMENT" }
		if !c.comment.isEmpty { s += " COMMENT " + literal(.text(c.comment)) }
		return s
	}

	/// `name` INT(11) UNSIGNED NOT NULL DEFAULT … AUTO_INCREMENT COMMENT '…'
	func columnDefinition(_ c: NewColumn) -> String {
		var s = quote(c.name) + " " + c.type
		let len = c.length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, NewColumn.takesLength.contains(c.type) { s += "(\(len))" }
		if c.unsigned && c.isNumeric { s += " UNSIGNED" }
		s += c.nullable && !c.primary ? " NULL" : " NOT NULL"
		if let d = newColumnDefault(c) { s += " DEFAULT " + d }
		if c.autoIncrement { s += " AUTO_INCREMENT" }
		if !c.comment.isEmpty { s += " COMMENT " + literal(.text(c.comment)) }
		return s
	}

	/// 새 테이블 시트의 기본값: NULL·CURRENT_TIMESTAMP·NOW() 는 대문자 그대로, 숫자 종류의 숫자, 이미 따옴표면 그대로, 나머지는 따옴표
	private func newColumnDefault(_ c: NewColumn) -> String? {
		let d = c.defaultValue.trimmingCharacters(in: .whitespaces)
		if d.isEmpty || c.autoIncrement { return nil }
		let up = d.uppercased()
		if up == "NULL" || up.hasPrefix("CURRENT_TIMESTAMP") || up == "NOW()" { return up }
		if c.isNumeric, Double(d) != nil { return d }
		// 이미 따옴표로 감쌌으면 그대로
		if d.count >= 2, d.hasPrefix("'"), d.hasSuffix("'") { return d }
		return literal(.text(c.defaultValue))
	}

	/// 기본값 SQL: NULL·CURRENT_TIMESTAMP·NOW() 는 그대로, 숫자 종류의 숫자도 그대로, 이미 '…' 로 감쌌으면 그대로, 나머지는 따옴표.
	/// 서버가 식이라고 알려 준 기본값은 (식) 으로
	func defaultValueSQL(_ d: String, expr: Bool, numeric: Bool) -> String {
		let t = d.trimmingCharacters(in: .whitespaces)
		let up = t.uppercased()
		if up == "NULL" { return "NULL" }
		if up.hasPrefix("CURRENT_TIMESTAMP") || up.hasPrefix("NOW(") || up.hasPrefix("LOCALTIME") { return t }
		if expr { return t.hasPrefix("(") ? t : "(\(t))" }
		if numeric, Double(t) != nil { return t }
		if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return t }
		return literal(.text(d))
	}

	// MARK: ALTER TABLE

	func alterTable(_ target: String, _ clauses: [String], multiline: Bool) -> String {
		multiline ? "ALTER TABLE \(target)\n  " + clauses.joined(separator: ",\n  ")
			: "ALTER TABLE \(target) " + clauses.joined(separator: ", ")
	}
	private func position(_ p: ColumnPosition?) -> String {
		switch p {
		case .first: " FIRST"
		case .after(let n): " AFTER \(quote(n))"
		case nil: ""
		}
	}
	func dropColumn(_ name: String) -> String { "DROP COLUMN \(quote(name))" }
	func addColumn(_ name: String, definition: String, position p: ColumnPosition?) -> String {
		"ADD COLUMN \(quote(name)) \(definition)\(position(p))"
	}
	func changeColumn(_ old: String, to name: String, definition: String, position p: ColumnPosition?) -> String {
		"CHANGE COLUMN \(quote(old)) \(quote(name)) \(definition)\(position(p))"
	}
	func engineClause(_ engine: String) -> String { "ENGINE=\(engine)" }
	func charsetClause(_ charset: String, collation: String, convert: Bool) -> String {
		convert ? "CONVERT TO CHARACTER SET \(charset) COLLATE \(collation)" : "DEFAULT CHARACTER SET \(charset) COLLATE \(collation)"
	}
	func tableCommentClause(_ comment: String) -> String { "COMMENT=\(literal(.text(comment)))" }
	func autoIncrementClause(_ n: Int64) -> String { "AUTO_INCREMENT = \(n)" }

	// MARK: 인덱스·외래 키

	func indexPart(_ s: String) -> String {
		if s.hasPrefix("(") { return s }
		if let m = s.firstMatch(of: /^(.+)\((\d+)\)$/) { return quote(String(m.1)) + "(\(m.2))" }
		return quote(s)
	}
	func dropIndexClause(_ index: IndexInfo) -> String {
		index.kind == .primary ? "DROP PRIMARY KEY" : "DROP INDEX \(quote(index.name))"
	}
	func addIndexClause(kind: IndexInfo.Kind, name: String, columns: [String], parser: String?) -> String {
		let cols = columns.map(indexPart).joined(separator: ", ")
		let n = name.trimmingCharacters(in: .whitespaces)
		let named = n.isEmpty ? "" : " " + quote(n)
		switch kind {
		case .primary: return "ADD PRIMARY KEY (\(cols))"
		case .unique: return "ADD UNIQUE INDEX\(named) (\(cols))"
		case .fulltext: return "ADD FULLTEXT INDEX\(named) (\(cols))" + (parser.map { " WITH PARSER \(quote($0))" } ?? "")
		case .spatial: return "ADD SPATIAL INDEX\(named) (\(cols))"
		case .index: return "ADD INDEX\(named) (\(cols))"
		}
	}
	func addForeignKeyClause(_ fk: ForeignKeyInfo, schema: String) -> String {
		let named = fk.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "CONSTRAINT \(quote(fk.name)) "
		let ref = (fk.refSchema == schema ? "" : quote(fk.refSchema) + ".") + quote(fk.refTable)
		return "ADD \(named)FOREIGN KEY (\(fk.columns.map { quote($0) }.joined(separator: ", "))) REFERENCES \(ref) (\(fk.refColumns.map { quote($0) }.joined(separator: ", "))) ON DELETE \(fk.onDelete) ON UPDATE \(fk.onUpdate)"
	}
	func dropForeignKeyClause(_ name: String) -> String { "DROP FOREIGN KEY \(quote(name))" }
}
