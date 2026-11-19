import SwiftUI
import AppKit

/// 접속 후 사이드바: 서버의 모든 DB 테이블을 DB별로 묶어 한 목록에 보여 준다.
/// DB 머리는 크게, 스크롤해도 위에 붙어 있다. 처음엔 모두 접혀 있다. 테이블을 누르면 탭으로 연다.
struct TableSidebar: View {
	@Bindable var session: Session
	@State private var searchText = ""
	@FocusState private var searchFocused: Bool
	/// 사이드바 스크롤 위치 (DB 머리가 붙었는지 판단)
	@State private var scrollY: CGFloat = 0
	/// 탭을 바꿀 때 보이는 곳까지만 스크롤하려고: 보이는 영역·위 여백(내용 좌표), 화면에 있는 줄의 자리
	@State private var visible: CGRect = .zero
	@State private var insetTop: CGFloat = 0
	@State private var rowFrames = RowFrames()
	@State private var position = ScrollPosition()

	var body: some View {
		let found = session.search(searchText)
		let bySchema = Dictionary(grouping: found, by: \.schema)
		// 검색 중에는 걸린 테이블이 있는 DB 만 (펼쳐서), 아니면 테이블 없는 DB 도 보여 준다
		let schemas = searchText.isEmpty ? session.databases : session.databases.filter { bySchema[$0] != nil }

		VStack(spacing: 0) {
			SidebarSearchField(text: $searchText, prompt: "테이블, 코멘트, 컬럼 검색", focused: $searchFocused)

			ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
					ForEach(schemas, id: \.self) { schema in
						// 고정한 테이블이 맨 위 (나머지는 원래 순서)
						let all = bySchema[schema] ?? []
						let items = all.filter { session.pinned.contains($0.id) } + all.filter { !session.pinned.contains($0.id) }
						let open = !searchText.isEmpty || session.expanded.contains(schema)
						Section {
							if open {
								if items.isEmpty {
									Text("테이블 없음").font(.callout).foregroundStyle(.tertiary)
										.padding(.leading, 36).frame(height: 26)
								}
								ForEach(items) { t in
									TableRow(table: t, pinned: session.pinned.contains(t.id),
									         matched: session.matchedColumns(t, searchText),
									         selected: session.activeTab.map(Session.tableID(ofTab:)) == t.id,
									         unsaved: session.isUnsaved(table: t.id))
										.onTapGesture {
											// 쿼리 패널이 떠 있으면 숨기고 테이블을 보인다 (사용자 2026-11-17)
											session.queryPanel?.open = false
											session.openTab(t)
										}
										.contextMenu {
											SidebarTableMenu(session: session, table: t)
										}
										.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("sidebarContent")) }) { rowFrames.map[t.id] = $0 }
										.onDisappear { rowFrames.map[t.id] = nil }
										.id(t.id)
								}
								PrivateViewRows(session: session, schema: schema, search: searchText)
								RoutineGroups(session: session, schema: schema, search: searchText)
								Color.clear.frame(height: 6)
							}
						} header: {
							SchemaHeader(name: schema, count: items.count, open: open,
							             unsaved: items.contains { session.isUnsaved(table: $0.id) },
							             selected: session.activeTab == Session.databaseTabID(schema),
							             scrollY: scrollY) {
								if session.expanded.contains(schema) { session.expanded.remove(schema) } else { session.expanded.insert(schema) }
							} openOverview: {
								session.queryPanel?.open = false
								session.openDatabase(schema)
							}
							.contextMenu {
								// 보기 → 만들기 → 내보내기·복제·이름 → 삭제 (되돌릴 수 없는 것은 맨 아래)
								Button("전체 테이블 보기") { session.openDatabase(schema) }
								Divider()
								Button("새 테이블 만들기…") { session.createTableRequest = CreateTableRequest(schema: schema) }
								NewRoutineMenu(session: session, schema: schema)
								Divider()
								Button("데이터베이스 내보내기…") { session.requestExport(schema: schema) }
								Button("SQL 파일 가져오기…") { session.requestImport(schema: schema) }
								Button("엑셀 파일 가져오기…") { session.requestExcelImport(schema: schema) }
								let caps = session.capabilities
								if caps.copyDatabase {
									Button("데이터베이스 복제…") { session.duplicateRequest = DuplicateRequest(schema: schema) }
								}
								if caps.renameDatabase {
									Button("데이터베이스 이름 바꾸기…") { session.renameDatabaseRequest = RenameDatabaseRequest(schema: schema) }
								}
								if caps.multipleDatabases {
									Divider()
									Button("데이터베이스 삭제…", role: .destructive) { session.requestDropDatabase(schema) }
								}
							}
						}
					}
				}
				.coordinateSpace(.named("sidebarContent"))
			}
			.scrollPosition($position)
			.onScrollGeometryChange(for: [CGFloat].self, of: { g in
				[g.contentOffset.y + g.contentInsets.top, g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom, g.contentInsets.top, g.containerSize.width]
			}) { _, v in
				visible = CGRect(x: 0, y: v[0], width: v[3], height: v[1]); insetTop = v[2]
			}
			// DB 머리가 맨 위에 "붙었는지" 알려고 스크롤 위치를 지켜본다 (SwiftUI 에는 CSS :stuck 이 없다)
			.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in scrollY = y }
			.overlay {
				if !searchText.isEmpty && found.isEmpty {
					ContentUnavailableView.search(text: searchText)
				}
			}
			// 탭을 바꾸면 그 테이블의 DB 를 펼치고, 가려져 있으면 보이는 곳까지만 스크롤한다
			.onChange(of: session.activeTab) { _, id in
				guard let id, let t = session.table(id) else { return }
				if searchText.isEmpty && !session.expanded.contains(t.schema) { session.expanded.insert(t.schema) }
				DispatchQueue.main.async { reveal(t, proxy: proxy) }
			}
			}

			Divider()
			// [+ −] 데이터베이스 만들기·지우기 (지우기는 지금 탭의 DB) … [모두 펼치기/접기] [다시 읽기]
			HStack(spacing: 8) {
				// DB 가 하나뿐인 종류(SQLite 등)는 만들기·지우기가 없다
				if session.capabilities.multipleDatabases {
					AddRemovePill(addHelp: "새 데이터베이스", add: { session.creatingDatabase = true },
					              removeHelp: session.currentSchema.map { "데이터베이스 \($0) 삭제…" } ?? "삭제할 데이터베이스의 탭을 고르세요",
					              remove: session.currentSchema.map { s in { session.requestDropDatabase(s) } })
				}
				Spacer(minLength: 0)
				Button {
					session.expanded = session.expanded.isEmpty ? Set(session.databases) : []
				} label: {
					PillIcon(systemName: session.expanded.isEmpty ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
				}
				.pill()
				.help(session.expanded.isEmpty ? "모두 펼치기" : "모두 접기")
				Button {
					Task { try? await session.loadSchema() }
				} label: {
					if session.loadingSchema { ProgressView().controlSize(.small).frame(width: 30, height: 28) } else { PillIcon(systemName: "arrow.clockwise") }
				}
				.pill()
				.help("데이터베이스·테이블 목록 새로고침")
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
		}
		.background {
			// ⌘F 로 검색칸
			Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
		}
	}

	/// DB 머리 높이 (맨 위에 붙어서 그 아래 줄을 가린다)
	private static let headerHeight: CGFloat = 34

	/// 그 테이블 줄이 보이게: 이미 보이면 그대로, 위로 가려졌으면 붙은 DB 머리 바로 아래까지, 아래로 가려졌으면 맨 아래까지만.
	/// proxy.scrollTo 는 붙은 DB 머리를 모르고 줄을 맨 위에 맞춰 머리 밑에 숨겼다 (사용자 2026-11-17)
	private func reveal(_ t: TableInfo, proxy: ScrollViewProxy) {
		guard let f = rowFrames.map[t.id], visible.height > 0 else {
			// 화면 밖이라 아직 안 그린 줄: 가운데로
			withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(t.id, anchor: .center) }
			return
		}
		let top = visible.minY + Self.headerHeight
		var y: CGFloat?
		if f.minY < top { y = f.minY - Self.headerHeight }
		else if f.maxY > visible.maxY { y = f.maxY - visible.height }
		guard let y else { return }
		withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: max(0, y) - insetTop) }
	}
}

/// 사이드바에 그려진 테이블 줄 자리 (바뀌어도 다시 그리지 않게 관찰하지 않는 상자)
final class RowFrames {
	var map: [String: CGRect] = [:]
}

/// 사이드바 맨 위 검색칸 (서버 목록·테이블 목록 공용)
struct SidebarSearchField: View {
	@Binding var text: String
	let prompt: String
	var focused: FocusState<Bool>.Binding

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
			TextField(prompt, text: $text)
				.textFieldStyle(.plain)
				.focused(focused)
			if !text.isEmpty {
				Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
					.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 10)
		.frame(height: 32)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}
}

/// DB 머리 (크게, 위에 붙음)
struct SchemaHeader: View {
	let name: String
	let count: Int
	let open: Bool
	var unsaved = false
	/// DB 개요 탭이 지금 보이는 탭인지
	var selected = false
	/// 사이드바 스크롤 위치. 내 위치가 여기와 같고(맨 위에 붙음) 스크롤이 내려가 있으면 "붙은 상태"
	var scrollY: CGFloat = 0
	/// > 꺾쇠: 펼치기·접기
	let toggle: () -> Void
	/// DB 이름(나머지 자리): DB 개요 탭 열기
	var openOverview: () -> Void = {}
	@State private var hover = false
	@State private var myY: CGFloat = -1

	/// 펼쳐져 있고, 스크롤이 내려가 있고, 내가 맨 위에 붙어 있을 때 (CSS :stuck 대신)
	private var stuck: Bool { open && scrollY > 0.5 && abs(myY - scrollY) < 1 }

	var body: some View {
		HStack(spacing: 8) {
			// 꺾쇠만 따로 눌러 펼치고 접는다
			Image(systemName: "chevron.right")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(.secondary)
				.rotationEffect(.degrees(open ? 90 : 0))
				.frame(width: 22, height: 30)
				.contentShape(Rectangle())
				.onTapGesture { withAnimation(.easeOut(duration: 0.15)) { toggle() } }
				.help(open ? "접기" : "펼치기")
			Image(systemName: "cylinder.split.1x2")
				.font(.system(size: 13))
				.foregroundStyle(Color.accentColor)
			Text(name)
				.font(.system(size: 14, weight: .semibold))
				.lineLimit(1)
			Spacer(minLength: 6)
			if unsaved { Circle().fill(.orange).frame(width: 7, height: 7).help("저장 안 된 변경이 있습니다") }
			Text("\(count)")
				.font(.system(size: 11, weight: .medium))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.padding(.horizontal, 6).padding(.vertical, 1)
				.background(Capsule().fill(Color.secondary.opacity(0.15)))
		}
		.padding(.leading, 7)
		.padding(.trailing, 12)
		.frame(height: 34)
		.background {
			Rectangle().fill(.regularMaterial)
			if selected { Rectangle().fill(Color.accentColor.opacity(0.18)) }
			else if hover { Rectangle().fill(Color.primary.opacity(0.05)) }
		}
		// 펼치자마자 긋지 않고, 맨 위에 붙었을 때만 아래 선
		.overlay(alignment: .bottom) { if stuck { Divider() } }
		.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("sidebarContent")).minY }) { y in myY = y }
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		// 이름(꺾쇠 밖)을 누르면 DB 개요 탭
		.onTapGesture(perform: openOverview)
		.help("눌러서 전체 테이블 보기")
	}
}

/// 테이블 한 줄: 이름 ··· 코멘트 (자리가 모자라면 이름만, 코멘트는 툴팁)
struct TableRow: View {
	let table: TableInfo
	var pinned = false
	let matched: [String]
	var selected = false
	var unsaved = false
	@State private var hover = false

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			HStack(spacing: 6) {
				Image(systemName: table.isView ? "eye" : "tablecells")
					.font(.system(size: 11))
					.foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
				NameAndComment(name: table.name, comment: table.comment, selected: selected)
				if pinned {
					Image(systemName: "pin.fill").font(.system(size: 9)).rotationEffect(.degrees(45))
						.foregroundStyle(selected ? Color.white.opacity(0.85) : .orange)
						.help("맨 위에 고정함")
				}
				if unsaved { Circle().fill(.orange).frame(width: 7, height: 7) }
			}
			if !matched.isEmpty {
				Text("컬럼: " + matched.prefix(4).joined(separator: ", "))
					.font(.caption).lineLimit(1)
					.foregroundStyle(selected ? Color.white.opacity(0.85) : Color.accentColor)
					.padding(.leading, 17)
			}
		}
		.padding(.leading, 30)
		.padding(.trailing, 10)
		.frame(minHeight: 26)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : (hover ? Color.primary.opacity(0.06) : .clear)))
		.padding(.horizontal, 6)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.help(table.comment.isEmpty ? table.id : "\(table.id)\n\(table.comment)")
	}
}

/// 이름은 왼쪽, 코멘트는 오른쪽 끝. 둘 다 들어갈 자리가 없으면 이름만 보인다
struct NameAndComment: View {
	let name: String
	let comment: String
	var selected = false

	var body: some View {
		ViewThatFits(in: .horizontal) {
			HStack(spacing: 0) {
				Text(name).lineLimit(1).fixedSize()
				Spacer(minLength: 14)
				Text(comment).font(.callout).lineLimit(1).fixedSize()
					.foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
			}
			Text(name).lineLimit(1).truncationMode(.middle)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.foregroundStyle(selected ? Color.white : .primary)
	}
}

/// 구조 화면: 컬럼 표(두 번 눌러 고치기, 끌어서 순서 바꾸기, ⌫ 지우기) + 아래 줄.
/// 바꾼 것은 모았다가 저장(⌘S) 때 ALTER TABLE 하나로 반영한다
struct StructureBody: View {
	let session: Session
	let table: TableInfo
	let data: TableData
	let editor: StructureEditor
	@State private var selection = IndexSet()

	var body: some View {
		VStack(spacing: 0) {
			TableGrid(source: editor) { selection = $0 }
			if editor.hasChanges || editor.saveError != nil {
				changesBar
			} else {
				Divider()
				footer
			}
		}
		.task(id: table.id) { if !editor.loaded { await editor.load() } }
		// 다른 곳(쿼리 패널·테이블 정보)에서 구조가 바뀌면 다시 읽는다. 고치던 게 있으면 그대로 둔다
		.onChange(of: session.columns[table.id] ?? []) {
			if !editor.hasChanges && !editor.saving { Task { await editor.load() } }
		}
		.sheet(isPresented: Bindable(editor).showSQL) {
			SQLPreview(statements: [(editor.alterSQL ?? "") + ";"], title: "저장하면 ALTER TABLE 하나로 실행됩니다")
		}
	}

	/// − : 고른 컬럼에 지울 표시 (고른 게 없거나 모두 이미 지울 표시면 꺼짐)
	private var removeAction: (() -> Void)? {
		guard editor.canMarkDeleted(selection) else { return nil }
		let sel = selection
		return { editor.markDeleted(sel) }
	}

	private var footer: some View {
		HStack(spacing: 10) {
			AddExportGroup(addHelp: table.isView ? "뷰에는 컬럼을 추가할 수 없습니다" : "컬럼 추가 (고른 줄 아래에)",
			               add: table.isView ? nil : { editor.addColumn(after: selection.last) },
			               showsRemove: !table.isView, removeHelp: "고른 컬럼 삭제 (저장할 때 반영)", remove: removeAction,
			               exportHelp: "테이블 내보내기") {
				session.requestExport(.table(table.schema, TableStat(table)))
			}
			if !table.isView {
				Text("두 번 눌러 고치기 · 끌어서 순서 바꾸기 · ⌫ 삭제").foregroundStyle(.tertiary).lineLimit(1)
			}
			Spacer()
			Text("컬럼 \(editor.rowCount)개").foregroundStyle(.secondary).monospacedDigit()
			Button {
				// 구조 표 + 오른쪽 테이블 정보(인덱스) + 왼쪽 테이블 목록까지 (다른 곳에서 바뀌었을 수 있다)
				if editor.hasChanges { NSSound.beep() } else {
					Task {
						try? await session.loadSchema()
						await editor.load()
						await session.reloadInspector(table)
					}
				}
			} label: {
				if editor.loading { ProgressView().controlSize(.small).frame(width: 30, height: 28) } else { PillIcon(systemName: "arrow.clockwise") }
			}
			.pill()
			.help("구조·인덱스·테이블 목록 새로고침")
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}

	/// 저장 안 한 구조 변경 (데이터 보기의 저장 바와 같은 모양)
	private var changesBar: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let err = editor.saveError {
				Label(err, systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
			} else if let p = editor.problem {
				Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			}
			HStack(spacing: 10) {
				// 저장 안 한 변경이 있으면 내보내기는 숨긴다 (서버의 구조와 화면이 달라서)
				AddRemovePill(addHelp: "컬럼 추가 (고른 줄 아래에)", add: { editor.addColumn(after: selection.last) },
				              removeHelp: "고른 컬럼 삭제 (저장할 때 반영)", remove: removeAction)
				Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
				Text("저장 안 된 구조 변경 \(editor.changeCount)건").font(.headline)
				Spacer()
				Button("SQL 미리보기") { editor.showSQL = true }
					.disabled(!editor.hasChanges)
				Button("되돌리기") { editor.discard() }
				Button {
					Task { await data.saveStructure() }
				} label: {
					if editor.saving { ProgressView().controlSize(.small) } else { Text("저장  ⌘S") }
				}
				.buttonStyle(.borderedProminent)
				.disabled(editor.saving || !editor.hasChanges || editor.problem != nil)
			}
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(Color.yellow.opacity(0.18), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1) }
	}
}

/// 사이드바 테이블 오른쪽 클릭 메뉴. DB 개요(하나 골랐을 때)와 같은 TableMenu 순서를 쓴다
struct SidebarTableMenu: View {
	let session: Session
	let table: TableInfo

	var body: some View {
		let pinned = session.pinned.contains(table.id)
		let items = TableMenu.items(isView: table.isView, name: table.name, capabilities: session.capabilities,
		                            extra: [
		                            	.action("분할 화면에서 열기") { session.openInSplit?(table) },
		                            	.action(pinned ? "고정 해제" : "맨 위에 고정") {
		                            		if pinned { session.pinned.remove(table.id) } else { session.pinned.insert(table.id) }
		                            	},
		                            ] + (table.isView ? [.action("뷰 정의 고치기") { session.openViewDefinition(table) }] : []),
		                            open: { session.openTab(table) },
		                            export: { session.requestExport(.table(table.schema, TableStat(table))) },
		                            importExcel: { session.requestExcelImport(schema: table.schema, table: table.name) },
		                            duplicate: { session.tableNameRequest = TableNameRequest(kind: .duplicate, schema: table.schema, table: TableStat(table)) },
		                            rename: { session.tableNameRequest = TableNameRequest(kind: .rename, schema: table.schema, table: TableStat(table)) },
		                            truncate: { session.requestTruncate(schema: table.schema, [TableStat(table)]) },
		                            drop: { session.requestDrop(schema: table.schema, [TableStat(table)]) })
		ForEach(items.indices, id: \.self) { i in
			switch items[i] {
			case .action(let title, let run): Button(title, role: title.hasSuffix("삭제…") ? .destructive : nil, action: run)
			case .disabled(let title): Button(title, role: title.hasSuffix("삭제…") ? .destructive : nil) {}.disabled(true)
			case .separator: Divider()
			case .submenu(let title, _): Button(title) {}.disabled(true)
			}
		}
	}
}
