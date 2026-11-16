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
						let items = bySchema[schema] ?? []
						let open = !searchText.isEmpty || session.expanded.contains(schema)
						Section {
							if open {
								if items.isEmpty {
									Text("테이블 없음").font(.callout).foregroundStyle(.tertiary)
										.padding(.leading, 36).frame(height: 26)
								}
								ForEach(items) { t in
									TableRow(table: t,
									         matched: session.matchedColumns(t, searchText),
									         selected: session.activeTab.map(Session.tableID(ofTab:)) == t.id,
									         unsaved: session.isUnsaved(table: t.id))
										.onTapGesture { session.openTab(t) }
										.contextMenu {
											SidebarTableMenu(session: session, table: t)
										}
										.id(t.id)
								}
								Color.clear.frame(height: 6)
							}
						} header: {
							SchemaHeader(name: schema, count: items.count, open: open,
							             unsaved: items.contains { session.isUnsaved(table: $0.id) },
							             selected: session.activeTab == Session.databaseTabID(schema),
							             scrollY: scrollY) {
								if session.expanded.contains(schema) { session.expanded.remove(schema) } else { session.expanded.insert(schema) }
							} openOverview: {
								session.openDatabase(schema)
							}
							.contextMenu {
								// 보기 → 만들기 → 내보내기·복제·이름 → 삭제 (되돌릴 수 없는 것은 맨 아래)
								Button("테이블 목록·용량 보기") { session.openDatabase(schema) }
								Divider()
								Button("새 테이블 만들기…") { session.createTableRequest = CreateTableRequest(schema: schema) }
								Divider()
								Button("데이터베이스 내보내기…") { session.requestExport(schema: schema) }
								Button("데이터베이스 복제…") { session.duplicateRequest = DuplicateRequest(schema: schema) }
								Button("데이터베이스 이름 바꾸기…") {}.disabled(true)
								Divider()
								Button("데이터베이스 삭제…", role: .destructive) {}.disabled(true)
							}
						}
					}
				}
				.coordinateSpace(.named("sidebarContent"))
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
				DispatchQueue.main.async {
					withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(t.id) }
				}
			}
			}

			Divider()
			HStack {
				Text("DB \(session.databases.count)개 · 테이블 \(session.tables.count)개")
				Button {
					Task { try? await session.loadSchema() }
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.plain)
				.help("테이블 목록 다시 읽기")
				Spacer()
				Button(session.expanded.isEmpty ? "모두 펼치기" : "모두 접기") {
					session.expanded = session.expanded.isEmpty ? Set(session.databases) : []
				}
				.buttonStyle(.link)
			}
			.font(.caption).foregroundStyle(.secondary)
			.padding(8)
		}
		.background {
			// ⌘F 로 검색칸
			Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
		}
	}
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
		.help("눌러서 테이블 목록·용량 보기")
	}
}

/// 테이블 한 줄: 이름 ··· 코멘트 (자리가 모자라면 이름만, 코멘트는 툴팁)
struct TableRow: View {
	let table: TableInfo
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

/// 테이블 구조: 컬럼, 코멘트, 타입, NULL, 기본값, 기타. 데이터와 같은 공용 표(TableGrid)에 구조 공급자를 끼운다
struct TableStructureView: View {
	let table: TableInfo
	let columns: [ColumnInfo]
	@State private var source: StructureSource

	init(table: TableInfo, columns: [ColumnInfo]) {
		self.table = table
		self.columns = columns
		// 처음부터 목록을 넣는다 (뜬 뒤에 넣으면 표가 다시 안 그려졌다)
		_source = State(initialValue: StructureSource(columns))
	}

	var body: some View {
		TableGrid(source: source)
			.onChange(of: columns) { source.update(columns) }
	}
}

/// 구조 공급자: 읽기 전용, 정렬은 앱 안에서. gridVersion 이 바뀌면 표가 다시 그려지게 관찰 가능
@Observable
final class StructureSource: GridSource {
	init(_ columns: [ColumnInfo]) {
		all = columns
		resort()
	}

	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private var all: [ColumnInfo] = []
	@ObservationIgnored private var rows: [ColumnInfo] = []
	@ObservationIgnored private var sortState: (key: String, ascending: Bool)?
	private(set) var gridVersion = 0

	func update(_ columns: [ColumnInfo]) {
		guard columns != all else { return }
		all = columns
		resort()
	}

	var gridID: String { "structure" }

	@ObservationIgnored let gridColumns: [GridColumn] = [
		GridColumn(key: "name", title: "컬럼", mono: true, width: 200),
		GridColumn(key: "comment", title: "코멘트", width: 240),
		GridColumn(key: "type", title: "타입", mono: true, width: 160),
		GridColumn(key: "null", title: "NULL", center: true, width: 50),
		GridColumn(key: "default", title: "기본값", width: 120),
		GridColumn(key: "extra", title: "기타", width: 160),
	]

	var rowCount: Int { rows.count }

	private static let keyIcons: [String: NSImage] = {
		func icon(_ name: String, _ color: NSColor) -> NSImage? {
			NSImage(systemSymbolName: name, accessibilityDescription: nil)?
				.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color])))
		}
		var d: [String: NSImage] = [:]
		d["PRI"] = icon("key.fill", .systemYellow)
		d["UNI"] = icon("key", .secondaryLabelColor)
		d["MUL"] = icon("line.3.horizontal.decrease", .secondaryLabelColor)
		return d
	}()

	func cell(_ row: Int, _ col: Int) -> GridCell {
		let c = rows[row]
		switch gridColumns[col].key {
		case "name": return GridCell(text: c.name, icon: Self.keyIcons[c.key])
		case "comment": return GridCell(text: c.comment)
		case "type": return GridCell(text: c.type, dim: true)
		case "null": return GridCell(text: c.nullable ? "예" : "")
		case "default": return GridCell(text: c.defaultValue ?? (c.nullable ? "NULL" : ""), dim: c.defaultValue == nil)
		default: return GridCell(text: c.extra, dim: true)
		}
	}

	var currentSort: (key: String, ascending: Bool)? { sortState }

	func sort(by key: String?, ascending: Bool) -> Bool {
		sortState = key.map { ($0, ascending) }
		resort()
		return true
	}

	private func resort() {
		rows = all
		if let s = sortState {
			func v(_ c: ColumnInfo) -> String {
				switch s.key {
				case "comment": c.comment
				case "type": c.type
				case "null": c.nullable ? "1" : "0"
				case "default": c.defaultValue ?? ""
				case "extra": c.extra
				default: c.name
				}
			}
			rows.sort { a, b in
				let r = v(a).localizedStandardCompare(v(b))
				return s.ascending ? r == .orderedAscending : r == .orderedDescending
			}
		}
		gridVersion += 1
	}
}

/// 사이드바 테이블 오른쪽 클릭 메뉴. DB 개요(하나 골랐을 때)와 같은 TableMenu 순서를 쓴다
struct SidebarTableMenu: View {
	let session: Session
	let table: TableInfo

	var body: some View {
		let items = TableMenu.items(isView: table.isView,
		                            open: { session.openTab(table) },
		                            export: { session.requestExport(.table(table.schema, TableStat(table))) })
		ForEach(items.indices, id: \.self) { i in
			switch items[i] {
			case .action(let title, let run): Button(title, action: run)
			case .disabled(let title): Button(title, role: title.hasSuffix("삭제…") ? .destructive : nil) {}.disabled(true)
			case .separator: Divider()
			}
		}
	}
}
