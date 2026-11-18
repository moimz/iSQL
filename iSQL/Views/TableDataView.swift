import SwiftUI

/// 테이블을 고르면 나오는 화면: 데이터 / 구조
struct TableDetailView: View {
	let session: Session
	let table: TableInfo
	let data: TableData
	/// 지금 보이는 탭인지 (데이터는 처음 보일 때 받아온다. 복원한 탭을 한꺼번에 읽지 않게)
	var isActive = true
	@State private var selection = IndexSet()
	@State private var creatingView = false
	/// 구조 화면은 한 번 열어 본 뒤부터 살려 둔다
	@State private var structureBuilt = false

	/// 이 칸의 표 호스트가 살려 둘 표들 (nil 이면 서버의 왼쪽 탭들). 오른쪽 분할 칸은 그 칸의 탭들을 준다
	var alive: [GridSource]?

	/// 보이는 표의 스크롤 뷰를 알려 준다 (양쪽 스크롤 맞추기)
	var onGridScroll: ((NSScrollView) -> Void)?

	init(session: Session, tab: String, table: TableInfo, isActive: Bool = true, alive: [GridSource]? = nil,
	     onGridScroll: ((NSScrollView) -> Void)? = nil) {
		self.session = session
		self.table = table
		self.isActive = isActive
		self.alive = alive
		self.onGridScroll = onGridScroll
		data = session.data(tab: tab) ?? TableData(table: table, tab: tab, session: session)
	}

	var body: some View {
		// 데이터와 구조를 버리지 않고 보이기만 바꾼다 (바꿀 때마다 표를 새로 만들면 뚝뚝 끊긴다)
		ZStack {
			VStack(spacing: 0) { dataBody }
				.opacity(data.mode == .data ? 1 : 0)
				.allowsHitTesting(data.mode == .data)
			if structureBuilt || data.mode == .structure {
				StructureBody(session: session, table: table, data: data, editor: data.structureEditor())
					.opacity(data.mode == .structure ? 1 : 0)
					.allowsHitTesting(data.mode == .structure)
					.onAppear { structureBuilt = true }
			}
		}
		// 화면을 탭끼리 돌려 쓰므로 테이블이 바뀔 때마다 (처음이면) 읽는다
		.task(id: data.tab) {
			data.prepareFilters()
			if isActive && !data.loaded && !data.loading { await data.load() }
		}
		.onChange(of: data.tab) { selection = [] }
		.sheet(isPresented: Bindable(data).showSQL) { SQLPreview(statements: data.changeSQL(), transaction: data.dialect) }
		// 지금 보는 상태(찾기 조건·정렬)를 뷰로
		.sheet(isPresented: $creatingView) { CreateViewSheet(sql: data.viewSQL, session: session, schema: table.schema, title: "지금 보는 데이터로 뷰 만들기") }
		.sheet(item: Bindable(data).longEdit) { req in
			LongTextSheet(request: req, table: table) { data.set(req.row, req.col, $0) }
		}
	}

	@ViewBuilder private var dataBody: some View {
		// 필터: 조건 줄로 WHERE 절을 만들고, WHERE 칸은 직접 고칠 수도 있다
		if data.showFilter {
			FilterBar(data: data, columns: session.columns[table.id] ?? [])
			Divider()
		}

		ZStack {
			// 탭마다 AppKit 표를 살려 두고 보이는 것만 보인다 (탭 전환이 보이기/숨기기 한 번)
			TableGridHost(active: data,
			              alive: alive ?? session.tabs.compactMap { session.data(tab: $0) },
			              onVisibleScroll: onGridScroll) { selection = $0 }
			if data.loading {
				if data.rows.isEmpty {
					// 처음 읽을 때: 제목은 이미 보이고 가운데에 로딩
					ProgressView()
				} else {
					// 다시 읽는 중: 이전 행 위에 반투명 막 (AppKit 표에는 .opacity 가 안 먹는다) + 위쪽에 표시
					Color(nsColor: .windowBackgroundColor).opacity(0.55)
						.padding(.top, 28)   // 컬럼 제목은 가리지 않는다
						.allowsHitTesting(false)
					VStack {
						HStack(spacing: 8) {
							ProgressView().controlSize(.small)
							Text("불러오는 중…").font(.callout)
						}
						.padding(.horizontal, 14)
						.padding(.vertical, 7)
						.background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
						.overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
						.shadow(color: .black.opacity(0.25), radius: 6, y: 2)
						.padding(.top, 52)
						Spacer()
					}
					.allowsHitTesting(false)
				}
			}
			if let error = data.error {
				VStack(spacing: 8) {
					Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
					Text(error).textSelection(.enabled).multilineTextAlignment(.center)
				}
				.padding()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(.background)
			}
		}
		// 표가 남는 높이를 다 차지한다: 분할을 처음 열 때 가끔 표가 위쪽 일부만 차지하고 하단바 영역이 늘어나 화면이 깨졌다 (사용자)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.layoutPriority(1)

		if data.hasChanges || data.saveError != nil {
			changesBar
		} else {
			// 표와 아래 줄을 구분하는 선 (저장 바는 자기 주황 윗줄이 있다)
			Divider()
			if data.stale {
				// 쿼리 패널에서 이 테이블을 바꿨다
				HStack(spacing: 8) {
					Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
					Text("쿼리로 이 테이블이 바뀌었습니다.")
					Spacer()
					Button("다시 읽기") { Task { await data.load(offset: data.offset) } }
				}
				.padding(.horizontal, 14).padding(.vertical, 6)
				.background(Color.orange.opacity(0.12), ignoresSafeAreaEdges: [])
				Divider()
			}
			footer
		}
	}

	/// 저장하지 않은 변경이 있을 때 아래 바 (눈에 띄게)
	private var changesBar: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let err = data.saveError {
				Label(err, systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 10) {
				// 저장 바에서도 행 추가·지우기 (내보내기는 저장 안 한 변경이 있으니 숨긴다)
				AddRemovePill(addHelp: "행 추가", add: { data.addRow() },
				              removeHelp: "고른 행 지우기 (저장할 때 반영)",
				              remove: selection.isEmpty ? nil : { data.toggleDelete(selection) })
				Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
				// 좁은 칸(분할)에서도 한 줄로: 종류(수정·추가·삭제)는 행 색으로 보이므로 개수만, 나눈 수는 마우스를 올리면
				Text("미반영 변경 \(data.changeCount)건").font(.headline).lineLimit(1).fixedSize()
					.help(changeDetail)
				Spacer()
				Button("SQL 미리보기") { data.showSQL = true }
				Button("되돌리기") { data.discard() }
				Button {
					Task { await data.saveIfNeeded() }
				} label: {
					if data.saving { ProgressView().controlSize(.small) } else { Text("저장  ⌘S") }
				}
				.buttonStyle(.borderedProminent)
				.disabled(data.saving)
			}
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(Color.yellow.opacity(0.18), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1) }
	}

	private var changeDetail: String {
		var parts: [String] = []
		if data.editCount > 0 { parts.append("수정 \(data.editCount)") }
		if !data.deleted.isEmpty { parts.append("삭제 \(data.deleted.count)") }
		if !data.inserted.isEmpty { parts.append("추가 \(data.inserted.count)") }
		return parts.joined(separator: ", ")
	}


	private var footer: some View {
		HStack(spacing: 10) {
			// [+ −] 알약(행 추가·고른 행 지우기) + [내보내기] 알약. 고칠 수 없는 표는 내보내기만
			if data.canEdit {
				AddExportGroup(addHelp: "행 추가", add: { data.addRow() },
				               showsRemove: true, removeHelp: "고른 행 지우기 (저장할 때 반영)",
				               remove: selection.isEmpty ? nil : { data.toggleDelete(selection) },
				               exportHelp: "내보내기", makeView: { creatingView = true }) { session.requestExport(.data(data)) }
			} else {
				ExportButton(makeView: { creatingView = true }) { session.requestExport(.data(data)) }
				if let why = data.readOnlyReason {
					Label(why, systemImage: "lock").foregroundStyle(.secondary)
				}
			}
			Spacer()
			PagerBar(pager: data, reload: {
				// 다시 읽으면 저장 안 한 변경이 사라지므로 그때는 하지 않는다
				if data.hasChanges { NSSound.beep() } else { Task { await data.load(offset: data.offset) } }
			}, reloadHelp: data.hasChanges ? "저장 안 된 변경이 있어 다시 읽지 않습니다" : "데이터 다시 읽기",
			   reloading: data.loading)
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}


	private func reload() {
		Task { await data.load() }
	}

}

/// 저장할 때 실행할 SQL 보기
struct SQLPreview: View {
	let statements: [String]
	var title = "저장하면 한 트랜잭션으로 실행됩니다"
	/// 트랜잭션 시작 … COMMIT 로 감싸 보일 때 그 문법 (nil 이면 감싸지 않는다: ALTER 등)
	var transaction: (any SQLDialect)?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title).font(.headline)
			ScrollView {
				Text((transaction.map { [$0.beginTransaction + ";"] + statements + [$0.commit + ";"] } ?? statements).joined(separator: "\n"))
					.font(.body.monospaced())
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(10)
			}
			.background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
			HStack {
				Button("복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(statements.joined(separator: "\n"), forType: .string)
				}
				Spacer()
				Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 640, height: 420)
	}
}

/// 필터 바: [✓] [컬럼] [연산자] [값] [−][+] 줄들 + WHERE 칸(최근 10개) + AND/OR + 적용
struct FilterBar: View {
	@Bindable var data: TableData
	let columns: [ColumnInfo]
	@FocusState private var whereFocused: Bool
	@FocusState private var focusedRow: UUID?

	var body: some View {
		VStack(spacing: 0) {
			ForEach($data.filters) { $f in
				HStack(spacing: 8) {
					Toggle("", isOn: $f.enabled).labelsHidden().toggleStyle(.checkbox)
					// 너비를 정확히 지키는 AppKit 팝업 (SwiftUI Picker 는 너비가 안 맞는다)
					PopUp(selection: $f.column, options: columns.map { c in
						(c.comment.isEmpty ? c.name : "\(c.name)    \(c.comment)", Optional(c.name))
					})
					.frame(width: 220)
					PopUp(selection: $f.op, options: FilterOp.allCases.flatMap { op -> [(title: String, value: FilterOp?)] in
						op.groupEnd ? [(op.rawValue, op), ("", nil)] : [(op.rawValue, op)]
					})
					.frame(width: 120)
					if f.op.needsValue {
						TextField("", text: $f.value, prompt: Text(f.op.placeholder))
							.textFieldStyle(.roundedBorder)
							.frame(maxWidth: 420)
							.focused($focusedRow, equals: f.id)
							.onSubmit(apply)
					}
					Spacer(minLength: 8)
					// 한 줄뿐이면 빼기 버튼은 자리만 차지하고 안 보인다 (비활성 버튼은 빈 알약처럼 보여서)
					Button { remove(f.id) } label: { Image(systemName: "minus").frame(width: 14, height: 16) }
						.help("이 조건 빼기")
						.opacity(data.filters.count > 1 ? 1 : 0)
						.allowsHitTesting(data.filters.count > 1)
					Button { add(after: f.id) } label: { Image(systemName: "plus").frame(width: 14, height: 16) }
						.help("조건 더하기")
				}
				.opacity(f.enabled ? 1 : 0.55)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				Divider().opacity(0.5)
			}

			HStack(spacing: 8) {
				Text("WHERE").font(.callout.monospaced()).foregroundStyle(.secondary)
				HStack(spacing: 4) {
					TextField("", text: $data.whereClause, prompt: Text("조건 없음 (위에서 고르거나 직접 입력)"))
						.textFieldStyle(.plain)
						.font(.body.monospaced())
						.focused($whereFocused)
						.onSubmit(apply)
					// 최근에 쓴 WHERE 절
					Menu {
						if data.history.isEmpty {
							Text("최근 조건 없음")
						} else {
							Section("최근 조건 (이 테이블)") {
								ForEach(data.history, id: \.self) { h in
									Button(h) {
										data.whereClause = h
										apply()
									}
								}
							}
							Divider()
							Menu("최근 조건 지우기") {
								ForEach(data.history, id: \.self) { h in Button(h) { data.forget(h) } }
							}
						}
					} label: {
						Image(systemName: "clock.arrow.circlepath")
					}
					.menuStyle(.borderlessButton)
					.menuIndicator(.hidden)
					.fixedSize()
					.help("최근 조건")
					if !data.whereClause.isEmpty {
						Button {
							data.whereClause = ""
							apply()
						} label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
						.buttonStyle(.plain)
						.help("조건 없이 보기")
					}
				}
				.padding(.horizontal, 8)
				.frame(height: 28)
				.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: whereFocused ? [] : [4, 3])))

				Picker("", selection: $data.matchAll) {
					Text("모두 만족 (AND)").tag(true)
					Text("하나라도 (OR)").tag(false)
				}
				.labelsHidden()
				.fixedSize()
				Button("적용", action: apply)
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.return, modifiers: .command)
					.help("적용 (⌘↩)")
			}
			.controlSize(.large)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
		// 조건 줄을 바꾸면 WHERE 칸을 다시 만든다 (WHERE 칸을 직접 고친 것은 조건 줄을 다시 바꿀 때까지 그대로)
		.onChange(of: data.filters) { data.whereClause = data.generatedWhere() }
		.onChange(of: data.matchAll) { data.whereClause = data.generatedWhere() }
		// "이 컬럼으로 찾기" 로 고른 줄의 값 칸에 커서
		.onChange(of: data.focusFilterID) { _, id in
			guard let id else { return }
			DispatchQueue.main.async { focusedRow = id; data.focusFilterID = nil }
		}
	}

	private func apply() {
		Task { await data.applyWhere() }
	}

	private func add(after id: UUID) {
		let base = data.filters.first { $0.id == id }
		let row = FilterRow(column: base?.column ?? columns.first?.name ?? "", op: base?.op ?? .eq)
		if let i = data.filters.firstIndex(where: { $0.id == id }) { data.filters.insert(row, at: i + 1) } else { data.filters.append(row) }
	}

	private func remove(_ id: UUID) {
		guard data.filters.count > 1 else { return }
		data.filters.removeAll { $0.id == id }
	}
}

