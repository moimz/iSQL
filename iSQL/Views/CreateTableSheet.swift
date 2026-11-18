import SwiftUI

/// 새 테이블 만들기 요청 (사이드바 DB 오른쪽 클릭·DB 개요 + → 창이 제목바 시트로 띄운다)
struct CreateTableRequest: Identifiable {
	let id = UUID()
	let schema: String
}

/// 만들 컬럼 한 줄
struct NewColumn: Identifiable, Hashable {
	let id = UUID()
	var name = ""
	var type = "VARCHAR"
	/// 길이·값: VARCHAR 255, DECIMAL 10,2, ENUM 'a','b'
	var length = "255"
	var unsigned = false
	var nullable = false
	/// 비우면 기본값 없음. NULL·CURRENT_TIMESTAMP·숫자는 그대로, 나머지는 따옴표
	var defaultValue = ""
	var autoIncrement = false
	var primary = false
	var comment = ""

	static let numericTypes: Set<String> = ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "DECIMAL", "FLOAT", "DOUBLE"]
	/// 종류 고르기 목록 (nil = 구분선)
	static let typeOptions: [String?] = [
		"INT", "BIGINT", "TINYINT", "SMALLINT", "MEDIUMINT", "DECIMAL", "FLOAT", "DOUBLE", nil,
		"VARCHAR", "CHAR", "TEXT", "MEDIUMTEXT", "LONGTEXT", nil,
		"DATETIME", "DATE", "TIMESTAMP", "TIME", "YEAR", nil,
		"JSON", "ENUM", "SET", nil,
		"BLOB", "MEDIUMBLOB", "LONGBLOB", "VARBINARY", "BINARY",
	]
	/// 종류를 고르면 채우는 길이 (없으면 비움)
	static func defaultLength(_ type: String) -> String {
		switch type {
		case "VARCHAR", "VARBINARY": "255"
		case "CHAR", "BINARY": "1"
		case "DECIMAL": "10,2"
		default: ""
		}
	}
	/// 길이·값이 꼭 있어야 하는 종류
	static let needsLength: Set<String> = ["VARCHAR", "VARBINARY", "ENUM", "SET"]
	/// 길이·값을 받는 종류 (나머지는 칸을 끈다)
	static let takesLength: Set<String> = ["VARCHAR", "CHAR", "VARBINARY", "BINARY", "DECIMAL", "FLOAT", "DOUBLE",
	                                       "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "ENUM", "SET",
	                                       "DATETIME", "TIMESTAMP", "TIME"]

	var isNumeric: Bool { Self.numericTypes.contains(type) }

	/// `name` INT(11) UNSIGNED NOT NULL DEFAULT … AUTO_INCREMENT COMMENT '…'
	func definition(_ dialect: any SQLDialect) -> String {
		var s = dialect.quote(name) + " " + type
		let len = length.trimmingCharacters(in: .whitespaces)
		if !len.isEmpty, Self.takesLength.contains(type) { s += "(\(len))" }
		if unsigned && isNumeric { s += " UNSIGNED" }
		s += nullable && !primary ? " NULL" : " NOT NULL"
		if let d = defaultSQL(dialect) { s += " DEFAULT " + d }
		if autoIncrement { s += " AUTO_INCREMENT" }
		if !comment.isEmpty { s += " COMMENT " + dialect.literal(.text(comment)) }
		return s
	}

	private func defaultSQL(_ dialect: any SQLDialect) -> String? {
		let d = defaultValue.trimmingCharacters(in: .whitespaces)
		if d.isEmpty || autoIncrement { return nil }
		let up = d.uppercased()
		if up == "NULL" || up.hasPrefix("CURRENT_TIMESTAMP") || up == "NOW()" { return up }
		if isNumeric, Double(d) != nil { return d }
		// 이미 따옴표로 감쌌으면 그대로
		if d.count >= 2, d.hasPrefix("'"), d.hasSuffix("'") { return d }
		return dialect.literal(.text(defaultValue))
	}
}

/// 새 테이블 만들기 시트: 이름·코멘트·엔진·문자셋·콜레이션, 컬럼 목록(+ − ↑ ↓), SQL 미리보기 → 만들기
struct CreateTableSheet: View {
	let schema: String
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	@Environment(\.dismiss) private var dismiss

	@State private var name = ""
	@State private var comment = ""
	@State private var engine = ""
	@State private var charset = ""
	@State private var collation = ""
	@State private var columns: [NewColumn] = [
		NewColumn(name: "id", type: "INT", length: "", unsigned: true, autoIncrement: true, primary: true),
	]
	@State private var selected: UUID?
	@State private var running = false
	@State private var failure: String?
	@FocusState private var focus: Field?

	private enum Field: Hashable { case table, name(UUID), length(UUID), value(UUID), comment(UUID) }

	init(request: CreateTableRequest, session: Session) {
		schema = request.schema
		self.session = session
	}

	// MARK: SQL

	private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

	private var sql: String {
		Self.createSQL(schema: schema, name: trimmedName, columns: columns, engine: engine,
		               charset: charset, collation: collation, comment: comment, dialect: dialect)
	}

	/// CREATE TABLE `db`.`이름` ( 컬럼…, PRIMARY KEY (…) ) ENGINE=… DEFAULT CHARSET=… COLLATE=… COMMENT='…'
	static func createSQL(schema: String, name: String, columns: [NewColumn], engine: String,
	                      charset: String, collation: String, comment: String, dialect: any SQLDialect) -> String {
		var lines = columns.map { "  " + $0.definition(dialect) }
		let keys = columns.filter(\.primary).map { dialect.quote($0.name) }
		if !keys.isEmpty { lines.append("  PRIMARY KEY (\(keys.joined(separator: ", ")))") }
		var tail = ")"
		if !engine.isEmpty { tail += " ENGINE=\(engine)" }
		if !charset.isEmpty { tail += " DEFAULT CHARSET=\(charset)" }
		if !collation.isEmpty { tail += " COLLATE=\(collation)" }
		if !comment.isEmpty { tail += " COMMENT=" + dialect.literal(.text(comment)) }
		return "CREATE TABLE \(dialect.quote(schema)).\(dialect.quote(name)) (\n" + lines.joined(separator: ",\n") + "\n" + tail
	}

	/// 만들기 전에 막는 문제 (첫 번째만 보여 준다)
	private var problem: String? {
		if trimmedName.isEmpty { return nil }
		if session.tables.contains(where: { $0.schema == schema && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
			return "\(schema) 에 이미 \(trimmedName) 테이블이 있습니다"
		}
		if columns.isEmpty { return "컬럼을 하나 이상 넣으세요" }
		if columns.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "이름이 없는 컬럼이 있습니다" }
		var seen = Set<String>()
		for c in columns where !seen.insert(c.name.lowercased()).inserted { return "컬럼 이름 \(c.name) 이(가) 겹칩니다" }
		if let c = columns.first(where: { NewColumn.needsLength.contains($0.type) && $0.length.trimmingCharacters(in: .whitespaces).isEmpty }) {
			return "\(c.name) (\(c.type)) 은(는) 길이·값이 필요합니다"
		}
		let ai = columns.filter(\.autoIncrement)
		if ai.count > 1 { return "AUTO_INCREMENT 컬럼은 하나만 둘 수 있습니다" }
		if let c = ai.first, !c.primary { return "AUTO_INCREMENT 컬럼(\(c.name))은 기본 키여야 합니다" }
		return nil
	}

	private var canCreate: Bool { !trimmedName.isEmpty && problem == nil && !running }

	// MARK: 화면

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(schema) 에 새 테이블").font(.headline)
			settings
			columnList
			columnButtons
			sqlPreview
			footer
		}
		.padding(20)
		.frame(width: 900)
		.interactiveDismissDisabled(running)
		.task { await loadDefaults() }
		.onAppear { focus = .table }
		.onChange(of: focus) { _, f in
			switch f {
			case .name(let id), .length(let id), .value(let id), .comment(let id): selected = id
			default: break
			}
		}
	}

	private var settings: some View {
		Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
			GridRow {
				label("이름")
				TextField("테이블 이름", text: $name)
					.textFieldStyle(.roundedBorder)
					.focused($focus, equals: .table)
				label("코멘트")
				TextField("", text: $comment)
					.textFieldStyle(.roundedBorder)
			}
			GridRow {
				label("엔진")
				PopUp(selection: $engine, options: options(session.catalog.engines, current: engine))
				label("문자셋")
				HStack(spacing: 10) {
					PopUp(selection: Binding(get: { charset }, set: pickCharset),
					      options: options(session.catalog.charsets.map(\.name), current: charset))
						.frame(width: 150)
					Text("콜레이션").foregroundStyle(.secondary)
					PopUp(selection: $collation, options: options(session.catalog.collations(for: charset), current: collation))
				}
			}
		}
	}

	// 컬럼 칸 너비 (머리와 줄이 같이 쓴다)
	private enum W {
		static let name: CGFloat = 150, type: CGFloat = 120, length: CGFloat = 90, check: CGFloat = 36, unsigned: CGFloat = 70, value: CGFloat = 120
	}

	private var columnList: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Text("이름").frame(width: W.name, alignment: .leading)
				Text("종류").frame(width: W.type, alignment: .leading)
				Text("길이·값").frame(width: W.length, alignment: .leading)
				Text("UNSIGNED").frame(width: W.unsigned)
				Text("NULL").frame(width: W.check)
				Text("기본값").frame(width: W.value, alignment: .leading)
				Text("AI").frame(width: W.check).help("AUTO_INCREMENT")
				Text("PK").frame(width: W.check).help("기본 키 (PRIMARY KEY)")
				Text("코멘트").frame(maxWidth: .infinity, alignment: .leading)
			}
			.font(.callout).foregroundStyle(.secondary)
			.padding(.horizontal, 8)
			.frame(height: 26)
			Divider()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach($columns) { $c in
							row($c).id(c.id)
						}
					}
					.padding(.vertical, 4)
				}
				.onChange(of: selected) { _, id in
					if let id { withAnimation { proxy.scrollTo(id) } }
				}
			}
			.frame(height: 260)
		}
		.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
		.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
	}

	private func row(_ c: Binding<NewColumn>) -> some View {
		let col = c.wrappedValue
		return HStack(spacing: 8) {
			TextField("컬럼 이름", text: c.name)
				.focused($focus, equals: .name(col.id))
				.frame(width: W.name)
			PopUp(selection: Binding(get: { col.type }, set: { t in
				c.wrappedValue.type = t
				c.wrappedValue.length = NewColumn.defaultLength(t)
				if !NewColumn.numericTypes.contains(t) { c.wrappedValue.unsigned = false; c.wrappedValue.autoIncrement = false }
			}), options: NewColumn.typeOptions.map { t in (t ?? "", t) })
				.frame(width: W.type)
			TextField(col.type == "ENUM" || col.type == "SET" ? "'a','b'" : "", text: c.length)
				.focused($focus, equals: .length(col.id))
				.frame(width: W.length)
				.disabled(!NewColumn.takesLength.contains(col.type))
			check(c.unsigned).frame(width: W.unsigned).disabled(!col.isNumeric)
			check(c.nullable).frame(width: W.check).disabled(col.primary)
			TextField(col.autoIncrement ? "" : "없음", text: c.defaultValue)
				.focused($focus, equals: .value(col.id))
				.frame(width: W.value)
				.disabled(col.autoIncrement)
			check(c.autoIncrement).frame(width: W.check).disabled(!col.isNumeric)
			check(Binding(get: { col.primary }, set: { on in
				c.wrappedValue.primary = on
				if on { c.wrappedValue.nullable = false }
			})).frame(width: W.check)
			TextField("", text: c.comment)
				.focused($focus, equals: .comment(col.id))
				.frame(maxWidth: .infinity)
		}
		.textFieldStyle(.roundedBorder)
		.padding(.horizontal, 8)
		.frame(height: 30)
		.background(selected == col.id ? Color.accentColor.opacity(0.14) : .clear)
		.contentShape(Rectangle())
		.onTapGesture { selected = col.id }
	}

	private func check(_ on: Binding<Bool>) -> some View {
		Toggle("", isOn: on).labelsHidden().toggleStyle(.checkbox)
	}

	private var selectedIndex: Int? { selected.flatMap { id in columns.firstIndex { $0.id == id } } }

	/// 목록 아래: [+ | −] [↑ | ↓]  컬럼 n개
	private var columnButtons: some View {
		HStack(spacing: 10) {
			ControlGroup {
				Button { addColumn() } label: { Image(systemName: "plus") }
					.help("컬럼 추가 (고른 컬럼 다음에)")
				Button { removeColumn() } label: { Image(systemName: "minus") }
					.help("고른 컬럼 지우기")
					.disabled(selectedIndex == nil)
			}
			.fixedSize()
			ControlGroup {
				Button { move(-1) } label: { Image(systemName: "arrow.up") }
					.help("위로")
					.disabled((selectedIndex ?? 0) == 0)
				Button { move(1) } label: { Image(systemName: "arrow.down") }
					.help("아래로")
					.disabled(selectedIndex.map { $0 >= columns.count - 1 } ?? true)
			}
			.fixedSize()
			Spacer()
			Text("컬럼 \(columns.count)개").foregroundStyle(.secondary).monospacedDigit()
		}
	}

	private var sqlPreview: some View {
		ScrollView {
			Text(trimmedName.isEmpty ? "테이블 이름을 넣으세요" : sql)
				.font(.callout.monospaced())
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(8)
		}
		.frame(height: 120)
		.background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
		.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
	}

	private var footer: some View {
		HStack(alignment: .center, spacing: 10) {
			if let f = failure {
				Label(f, systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red).font(.callout).lineLimit(3).textSelection(.enabled)
			} else if let p = problem {
				Label(p, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange).font(.callout).lineLimit(2)
			}
			Spacer(minLength: 0)
			Button("취소", role: .cancel) { dismiss() }
				.keyboardShortcut(.cancelAction)
				.disabled(running)
			Button {
				Task { await create() }
			} label: {
				if running { ProgressView().controlSize(.small) } else { Text("만들기") }
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.defaultAction)
			.disabled(!canCreate)
		}
		.controlSize(.large)
	}

	private func label(_ s: String) -> some View {
		Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
	}

	/// 목록에 지금 값이 없으면(목록을 아직 못 읽음) 앞에 넣는다
	private func options(_ list: [String], current: String) -> [(title: String, value: String?)] {
		var l = list
		if !current.isEmpty, !l.contains(current) { l.insert(current, at: 0) }
		return l.map { ($0, $0) }
	}

	// MARK: 동작

	private func pickCharset(_ cs: String) {
		charset = cs
		if session.catalog.charset(of: collation) != cs {
			collation = session.catalog.defaultCollation(for: cs) ?? session.catalog.collations(for: cs).first ?? ""
		}
	}

	private func addColumn() {
		let c = NewColumn()
		if let i = selectedIndex { columns.insert(c, at: i + 1) } else { columns.append(c) }
		selected = c.id
		Task { @MainActor in focus = .name(c.id) }
	}

	private func removeColumn() {
		guard let i = selectedIndex else { return }
		columns.remove(at: i)
		selected = columns.isEmpty ? nil : columns[min(i, columns.count - 1)].id
	}

	private func move(_ by: Int) {
		guard let i = selectedIndex, columns.indices.contains(i + by) else { return }
		withAnimation(.easeOut(duration: 0.15)) { columns.swapAt(i, i + by) }
	}

	/// 엔진(서버 기본), DB 의 문자셋·콜레이션을 기본값으로
	@MainActor
	private func loadDefaults() async {
		try? await session.loadCatalogIfNeeded()
		if engine.isEmpty {
			let e = try? await session.query("SELECT @@default_storage_engine").last?.rows.first?.first?.string
			engine = e ?? (session.catalog.engines.contains("InnoDB") ? "InnoDB" : session.catalog.engines.first ?? "")
		}
		if charset.isEmpty, let cs = session.server?.defaultCharset, !cs.isEmpty {
			// 서버 설정에 정해 둔 기본값이 먼저
			charset = cs
			collation = session.server?.defaultCollation.flatMap { $0.isEmpty ? nil : $0 } ?? session.catalog.defaultCollation(for: cs) ?? ""
		}
		if charset.isEmpty {
			let r = try? await session.query("""
				SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(dialect.literal(.text(schema)))
				""").last
			charset = r?.rows.first?[safe: 0]?.string ?? ""
			collation = r?.rows.first?[safe: 1]?.string ?? ""
		}
	}

	@MainActor
	private func create() async {
		guard canCreate else { return }
		running = true
		failure = nil
		defer { running = false }
		do {
			_ = try await session.query(sql)
		} catch {
			failure = error.localizedDescription
			return
		}
		await session.tableCreated(schema: schema, name: trimmedName)
		dismiss()
	}
}
