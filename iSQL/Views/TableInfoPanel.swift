import SwiftUI

/// 하단바 유리 알약: 아이콘 버튼 여러 개를 구분선 없이 한 알약에 (ControlGroup 은 칸마다 구분선이 들어간다)
struct PillIcon: View {
	let systemName: String
	var body: some View {
		Image(systemName: systemName).frame(width: 30, height: 28).contentShape(Rectangle())
	}
}

extension View {
	/// 하단바 유리 알약 모양 (안의 버튼은 테두리 없이).
	/// interactive: 누르면 알약이 밝아지는 유리. 입력칸이 든 알약(쪽 번호)은 끈다 — 입력칸을 눌러도 알약 전체가 밝아져
	/// 꺼진 화살표가 더 투명해 보였다 (사용자)
	@ViewBuilder func pill(interactive: Bool = true) -> some View {
		if interactive {
			buttonStyle(.borderless).padding(.horizontal, 4).glassEffect(.regular.interactive(), in: Capsule())
		} else {
			buttonStyle(.borderless).padding(.horizontal, 4).glassEffect(.regular, in: Capsule())
		}
	}
}

/// [+ (−)] 알약 하나. 저장 바에서는 이것만 (저장 안 한 변경이 있을 때 내보내기는 숨긴다)
struct AddRemovePill: View {
	let addHelp: String
	var add: (() -> Void)?
	var showsRemove = true
	var removeHelp = ""
	var remove: (() -> Void)?

	var body: some View {
		HStack(spacing: 0) {
			Button { add?() } label: { PillIcon(systemName: "plus") }
				.help(addHelp)
				.disabled(add == nil)
			if showsRemove {
				Button { remove?() } label: { PillIcon(systemName: "minus") }
					.help(removeHelp)
					.disabled(remove == nil)
			}
		}
		.pill()
		.fixedSize()
	}
}

/// 하단바 맨 앞의 [+ (−)] 알약 + [내보내기] 알약 (DB 개요: + = 테이블 만들기, 구조 보기: + = 컬럼 추가, − = 고른 컬럼 지우기)
struct AddExportGroup: View {
	let addHelp: String
	/// nil 이면 + 는 흐리게 (아직 기능 없음)
	var add: (() -> Void)?
	/// − 버튼을 둘지 (구조 보기)
	var showsRemove = false
	var removeHelp = ""
	/// nil 이면 − 는 흐리게 (고른 것이 없음)
	var remove: (() -> Void)?
	let exportHelp: String
	var makeView: (() -> Void)? = nil
	let export: () -> Void

	var body: some View {
		// [+ −] 알약 하나(사이 구분선 없이) + 내보내기 따로. ControlGroup 은 칸마다 구분선이 생겨 + | − | 내보내기 가 복잡했다 (사용자)
		HStack(spacing: 8) {
			AddRemovePill(addHelp: addHelp, add: add, showsRemove: showsRemove, removeHelp: removeHelp, remove: remove)
			ExportButton(help: exportHelp, makeView: makeView, action: export)
		}
		.fixedSize()
	}
}

/// 구조 보기 오른쪽 "테이블 정보" 패널: 설정(엔진·문자셋·콜레이션·코멘트 → 적용), 통계, 인덱스(+ −)
struct TableInfoPanel: View {
	let session: Session
	let inspector: TableInspector
	let columns: [ColumnInfo]

	/// 실행 전에 확인받을 ALTER
	@State private var pending: (title: String, sql: String)?
	@State private var failure: String?
	@State private var selectedIndex: String?
	@State private var addingIndex = false
	/// 고치는 인덱스 (두 번 누르기·오른쪽 클릭 "수정…")
	@State private var editingIndex: IndexInfo?
	/// AUTO_INCREMENT 바꾸기 창
	@State private var editingAuto = false
	@State private var autoText = ""

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				settings
				stats
				indexList
				createStatement
			}
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.overlay {
			if inspector.loading && inspector.engine.isEmpty { ProgressView() }
		}
		.task(id: inspector.table.id) {
			if inspector.engine.isEmpty { await inspector.load() }
		}
		.confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
			Button("실행", role: .destructive) {
				guard let p = pending else { return }
				pending = nil
				Task { failure = await inspector.run(p.sql) }
			}
		} message: {
			Text(pending?.sql ?? "")
		}
		.alert("실행하지 못했습니다", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("확인") { failure = nil }
		} message: {
			Text(failure ?? "")
		}
		.sheet(isPresented: $addingIndex) {
			AddIndexSheet(table: inspector.table, columns: columns, hasPrimary: inspector.indexes.contains { $0.kind == .primary },
			              parsers: inspector.catalog.fulltextParsers, ngramTokenSize: inspector.catalog.ngramTokenSize) { sql in
				Task { failure = await inspector.run(sql) }
			}
		}
		.alert("AUTO_INCREMENT 바꾸기", isPresented: $editingAuto) {
			TextField("다음 번호", text: $autoText)
			Button("바꾸기") {
				guard let n = Int64(autoText.trimmingCharacters(in: .whitespaces)), n > 0 else { NSSound.beep(); return }
				Task { failure = await inspector.run(inspector.autoIncrementSQL(n)) }
			}
			Button("취소", role: .cancel) {}
		} message: {
			Text("다음에 들어갈 행의 번호입니다. 지금 가장 큰 값보다 작게 넣으면 InnoDB 는 가장 큰 값 + 1 로 맞춥니다.")
		}
		.sheet(item: $editingIndex) { ix in
			AddIndexSheet(table: inspector.table, columns: columns,
			              hasPrimary: ix.kind != .primary && inspector.indexes.contains { $0.kind == .primary },
			              parsers: inspector.catalog.fulltextParsers, ngramTokenSize: inspector.catalog.ngramTokenSize,
			              editing: ix, inspector: inspector) { sql in
				Task { failure = await inspector.run(sql) }
			}
		}
	}

	// MARK: 설정

	private var settings: some View {
		VStack(alignment: .leading, spacing: 10) {
			header("테이블 설정")
			if let e = inspector.error {
				Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
			}
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					label("엔진")
					PopUp(selection: Bindable(inspector).editEngine, options: options(inspector.catalog.engines, current: inspector.engine))
				}
				GridRow {
					label("문자셋")
					PopUp(selection: Binding(get: { inspector.editCharset }, set: { inspector.pickCharset($0) }),
					      options: options(inspector.catalog.charsets.map(\.name), current: inspector.editCharset))
				}
				GridRow {
					label("콜레이션")
					PopUp(selection: Bindable(inspector).editCollation,
					      options: options(inspector.catalog.collations(for: inspector.editCharset), current: inspector.editCollation))
				}
				GridRow(alignment: .top) {
					label("코멘트").padding(.top, 4)
					TextField("", text: Bindable(inspector).editComment, axis: .vertical)
						.lineLimit(2...6)
						.textFieldStyle(.roundedBorder)
				}
			}
			if inspector.editCollation != inspector.collation {
				Toggle("기존 컬럼도 변환 (CONVERT TO)", isOn: Bindable(inspector).convertColumns)
					.toggleStyle(.checkbox)
					.help("끄면 앞으로 만들 컬럼의 기본값만 바뀝니다. 켜면 모든 문자 컬럼의 데이터를 변환합니다 (큰 테이블은 오래 걸립니다)")
			}
			HStack {
				Spacer()
				if inspector.hasEdits {
					Button("되돌리기") { inspector.resetEdits() }
				}
				Button {
					if let sql = inspector.alterSQL { pending = ("테이블 설정을 바꿀까요?", sql) }
				} label: {
					if inspector.applying { ProgressView().controlSize(.small) } else { Text("적용") }
				}
				.buttonStyle(.borderedProminent)
				.disabled(!inspector.hasEdits || inspector.applying)
			}
		}
	}

	/// 목록에 지금 값이 없으면(목록을 아직 못 읽음) 앞에 넣는다
	private func options(_ list: [String], current: String) -> [(title: String, value: String?)] {
		var l = list
		if !current.isEmpty, !l.contains(current) { l.insert(current, at: 0) }
		return l.map { ($0, $0) }
	}

	// MARK: 통계

	private var stats: some View {
		VStack(alignment: .leading, spacing: 10) {
			header("통계")
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
				GridRow {
					label("행")
					HStack(spacing: 6) {
						if let n = inspector.exactRows {
							Text(n.formatted()).monospacedDigit()
						} else if inspector.counting {
							ProgressView().controlSize(.mini)
							Text("세는 중…").foregroundStyle(.secondary)
						} else {
							Text("—").foregroundStyle(.secondary)
						}
						Spacer(minLength: 0)
						Button { Task { await inspector.countRows() } } label: { Image(systemName: "arrow.clockwise") }
							.buttonStyle(.borderless)
							.help("SELECT COUNT(*) 로 다시 세기")
							.disabled(inspector.counting)
					}
				}
				stat("어림 행", inspector.approxRows.map { "~" + $0.formatted() })
				stat("데이터", DatabaseOverview.size(inspector.dataLength))
				stat("인덱스", DatabaseOverview.size(inspector.indexLength))
				stat("전체", DatabaseOverview.size(inspector.dataLength + inspector.indexLength))
				stat("여유 공간", DatabaseOverview.size(inspector.dataFree))
				stat("평균 행 길이", inspector.avgRowLength > 0 ? ByteCountFormatter.string(fromByteCount: inspector.avgRowLength, countStyle: .memory) : nil)
				GridRow {
					label("AUTO_INCREMENT")
					HStack(spacing: 6) {
						Text(inspector.autoIncrement.map { String($0) } ?? "—")
							.foregroundStyle(inspector.autoIncrement == nil ? .secondary : .primary).monospacedDigit()
						Spacer(minLength: 0)
						if inspector.autoIncrement != nil && !inspector.table.isView {
							Button("바꾸기…") {
								autoText = inspector.autoIncrement.map { String($0) } ?? ""
								editingAuto = true
							}
							.buttonStyle(.borderless)
							.disabled(inspector.applying)
						}
					}
				}
				stat("행 형식", inspector.rowFormat)
				stat("만든 시각", inspector.created)
				stat("고친 시각", inspector.updated)
			}
		}
	}

	private func stat(_ title: String, _ value: String?) -> some View {
		GridRow {
			label(title)
			Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
				.foregroundStyle(value?.isEmpty == false ? .primary : .secondary)
				.monospacedDigit()
				.textSelection(.enabled)
		}
	}

	// MARK: 인덱스

	private var indexList: some View {
		VStack(alignment: .leading, spacing: 10) {
			header("인덱스")
			VStack(spacing: 0) {
				if inspector.indexes.isEmpty {
					Text(inspector.loading ? "읽는 중…" : "인덱스 없음")
						.foregroundStyle(.secondary).font(.callout)
						.frame(maxWidth: .infinity, minHeight: 44)
				}
				ForEach(inspector.indexes) { ix in
					indexRow(ix)
						.contentShape(Rectangle())
						.onTapGesture(count: 2) {
							selectedIndex = ix.name
							if !inspector.table.isView && !inspector.applying { editingIndex = ix }
						}
						.onTapGesture { selectedIndex = ix.name }
						.contextMenu {
							Button("수정…") { selectedIndex = ix.name; editingIndex = ix }
							Divider()
							Button("삭제…") {
								selectedIndex = ix.name
								pending = ("인덱스 \(ix.name) 을(를) 지울까요?", inspector.dropIndexSQL(ix))
							}
						}
						.disabled(inspector.table.isView)
				}
				Divider()
				// 맥 목록 아래 [+][−] 처럼
				HStack(spacing: 0) {
					Button { addingIndex = true } label: { Image(systemName: "plus").frame(width: 24, height: 16) }
						.help("인덱스 추가")
					// 맥 목록 아래 [+ | −] 는 구분선이 표준
					Divider().frame(height: 14)
					Button {
						if let ix = inspector.indexes.first(where: { $0.name == selectedIndex }) {
							pending = ("인덱스 \(ix.name) 을(를) 지울까요?", inspector.dropIndexSQL(ix))
						}
					} label: { Image(systemName: "minus").frame(width: 24, height: 16) }
						.help("고른 인덱스 삭제")
						.disabled(selectedIndex == nil || inspector.applying)
					Spacer()
				}
				.buttonStyle(.borderless)
				.padding(4)
				.disabled(inspector.table.isView)
			}
			.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
		}
		.onChange(of: inspector.indexes) { if !inspector.indexes.contains(where: { $0.name == selectedIndex }) { selectedIndex = nil } }
	}

	private func indexRow(_ ix: IndexInfo) -> some View {
		let selected = selectedIndex == ix.name
		return HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(ix.kind == .primary ? "PK" : ix.kind.rawValue)
				.font(.caption.weight(.semibold))
				.foregroundStyle(selected ? Color.white : kindColor(ix.kind))
				.padding(.horizontal, 5).padding(.vertical, 1)
				.background(RoundedRectangle(cornerRadius: 4).fill((selected ? Color.white : kindColor(ix.kind)).opacity(0.18)))
				.frame(width: 64, alignment: .leading)
			// 한 줄: 컬럼은 왼쪽, 인덱스 이름은 오른쪽 끝에 흐리게 (좁으면 이름부터 줄인다)
			Text(ix.columns.joined(separator: ", ")).lineLimit(1).truncationMode(.tail)
				.layoutPriority(1)
			if let p = ix.parser {
				Text(p).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
			}
			Spacer(minLength: 8)
			if ix.kind != .primary {
				Text(ix.name).font(.callout).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
					.lineLimit(1).truncationMode(.middle)
			}
		}
		.padding(.horizontal, 8)
		.frame(height: 26)
		.foregroundStyle(selected ? Color.white : Color.primary)
		.background(selected ? Color.accentColor : Color.clear)
		// 잘려도 툴팁으로 전부 보인다
		.help("\(ix.name): \(ix.columns.joined(separator: ", "))\n" + (ix.cardinality.map { "\(ix.method) · 카디널리티 \($0.formatted())" } ?? ix.method)
		      + (ix.parser.map { " · WITH PARSER \($0)" } ?? ""))
	}

	// MARK: CREATE 문

	private var createStatement: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				header(inspector.table.isView ? "CREATE VIEW 문" : "CREATE 문")
				Spacer()
				Button("복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(inspector.createSQL + ";", forType: .string)
				}
				.buttonStyle(.borderless)
				.disabled(inspector.createSQL.isEmpty)
			}
			Text(inspector.createSQL.isEmpty ? AttributedString("—") : SQLHighlight.attributed(inspector.createSQL + ";"))
				.font(.system(size: 11, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(8)
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
		}
	}

	private func kindColor(_ k: IndexInfo.Kind) -> Color {
		switch k {
		case .primary: .orange
		case .unique: .purple
		case .fulltext, .spatial: .teal
		case .index: .blue
		}
	}

	private func header(_ t: String) -> some View {
		Text(t).font(.headline)
	}

	private func label(_ t: String) -> some View {
		Text(t).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
	}
}

/// 인덱스 추가 시트: 종류, 이름, 컬럼(누른 순서대로), 실행할 SQL
struct AddIndexSheet: View {
	let table: TableInfo
	let columns: [ColumnInfo]
	let hasPrimary: Bool
	/// 서버의 전문 검색 파서 (ngram 이 있으면 FULLTEXT 에 n-gram 선택)
	var parsers: [String] = []
	var ngramTokenSize: Int?
	/// 고치는 인덱스 (nil 이면 새로 추가)
	var editing: IndexInfo? = nil
	var inspector: TableInspector? = nil
	let add: (String) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var kind: IndexInfo.Kind = .index
	@State private var name = ""
	@State private var nameEdited = false
	@State private var picked: [String] = []
	@State private var ngram = false
	@State private var prepared = false

	/// 고칠 때: 처음 값으로 채운다
	private func prepare() {
		guard !prepared else { return }
		prepared = true
		guard let ix = editing else { return }
		kind = ix.kind
		picked = ix.columns
		ngram = ix.parser == "ngram"
		if ix.kind != .primary { name = ix.name; nameEdited = true }
	}

	private var unchanged: Bool {
		guard let ix = editing else { return false }
		return ix.kind == kind && ix.columns == picked && (ix.kind == .primary || ix.name == name)
			&& (ix.parser == "ngram") == (canNgram && ngram)
	}
	private var canNgram: Bool { kind == .fulltext && parsers.contains("ngram") }

	private var autoName: String {
		guard !picked.isEmpty, kind != .primary else { return "" }
		return (kind == .unique ? "uk_" : kind == .fulltext ? "ft_" : "idx_") + picked.joined(separator: "_")
	}

	private var sql: String {
		let n = nameEdited ? name : autoName, parser = canNgram && ngram ? "ngram" : nil
		if let ix = editing, let inspector { return inspector.editIndexSQL(ix, kind: kind, name: n, columns: picked, parser: parser) }
		return TableInspector.addIndexSQL(table: table, kind: kind, name: n, columns: picked, parser: parser)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(editing.map { "\(table.name) 의 인덱스 \($0.kind == .primary ? "PRIMARY" : $0.name) 수정" } ?? "\(table.name) 에 인덱스 추가").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
				GridRow {
					Text("종류").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
					PopUp(selection: $kind, options: [("INDEX", .index), ("UNIQUE", .unique), ("FULLTEXT", .fulltext), ("SPATIAL", .spatial)]
					      + (hasPrimary ? [] : [("PRIMARY KEY", IndexInfo.Kind.primary)]))
						.frame(width: 180)
				}
				GridRow {
					Text("이름").foregroundStyle(.secondary)
					TextField(kind == .primary ? "PRIMARY" : "자동", text: Binding(get: { nameEdited ? name : autoName },
					                                                             set: { name = $0; nameEdited = !$0.isEmpty }))
						.textFieldStyle(.roundedBorder)
						.disabled(kind == .primary)
				}
			}
			if canNgram {
				VStack(alignment: .leading, spacing: 3) {
					Toggle("n-gram 파서 (WITH PARSER ngram)", isOn: $ngram).toggleStyle(.checkbox)
					Text("한글·중국어·일본어처럼 띄어쓰기로 낱말이 안 나뉘는 글을 \(ngramTokenSize ?? 2)글자 조각으로 찾습니다")
						.font(.callout).foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.leading, 20)
				}
			}
			VStack(alignment: .leading, spacing: 6) {
				Text("컬럼 (누른 순서대로)").foregroundStyle(.secondary)
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(columns) { c in
							// 접두 길이가 붙은 칸("name(10)")도 그 컬럼으로 본다
							let order = picked.firstIndex { TableInspector.indexColumnName($0) == c.name }
							Button {
								if let order { picked.remove(at: order) } else { picked.append(c.name) }
							} label: {
								HStack(spacing: 8) {
									ZStack {
										Circle().fill(order != nil ? Color.accentColor : Color.clear)
										Circle().strokeBorder(order != nil ? Color.accentColor : Color.secondary.opacity(0.6))
										if let order { Text("\(order + 1)").font(.caption2.bold()).foregroundStyle(.white) }
									}
									.frame(width: 18, height: 18)
									Text(c.name)
									Text(c.type).foregroundStyle(.secondary)
									Spacer()
								}
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.padding(.horizontal, 8)
							.frame(height: 26)
						}
					}
					.padding(.vertical, 4)
				}
				.frame(height: min(CGFloat(columns.count) * 26 + 8, 260))
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
			}
			if picked.contains(where: { TableInspector.indexColumnName($0) == nil }) {
				Text("식 인덱스 칸 \(picked.filter { TableInspector.indexColumnName($0) == nil }.joined(separator: ", ")) 은(는) 그대로 둡니다")
					.font(.callout).foregroundStyle(.secondary)
			}
			Text(picked.isEmpty ? "컬럼을 고르세요" : sql)
				.font(.callout.monospaced())
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button(editing == nil ? "추가" : "수정") {
					dismiss()
					add(sql)
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(picked.isEmpty || unchanged)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 420)
		.onAppear(perform: prepare)
	}
}
