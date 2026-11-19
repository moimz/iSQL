import SwiftUI
import AppKit

/// 사이드바 DB 아래 루틴 묶음: ▸ 프로시저 N · 함수 N · 트리거 N · 이벤트 N (있는 것만). 오른쪽 클릭으로 새로 만들기
struct RoutineGroups: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	let schema: String
	/// 사이드바 찾기 글 (있으면 이름이 걸린 것만, 펼쳐서)
	var search = ""

	var body: some View {
		ForEach(session.capabilities.routineKinds, id: \.self) { kind in
			let all = session.routines(schema, kind)
			let items = search.isEmpty ? all : all.filter { $0.name.lowercased().contains(search.lowercased()) }
			if !items.isEmpty {
				let key = schema + "|" + kind.rawValue
				let open = !search.isEmpty || session.expandedRoutineGroups.contains(key)
				RoutineGroupRow(kind: kind, count: items.count, open: open) {
					if session.expandedRoutineGroups.contains(key) { session.expandedRoutineGroups.remove(key) } else { session.expandedRoutineGroups.insert(key) }
				}
				.contextMenu { if !kind.isReadOnly { Button("새 \(kind.label)…") { session.newRoutine(kind, schema: schema) } } }
				if open {
					ForEach(items) { r in
						RoutineRow(routine: r, selected: session.activeTab == r.id)
							.onTapGesture {
								session.queryPanel?.open = false
								session.openRoutine(r)
							}
							.contextMenu { RoutineMenu(session: session, routine: r) }
					}
				}
			}
		}
	}
}

/// 루틴 묶음이 하나도 없는 DB 의 오른쪽 클릭에 붙는 "새로 만들기" 메뉴
struct NewRoutineMenu: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	let schema: String
	var body: some View {
		// 루틴이 없는 서버 종류면 메뉴째 숨긴다
		let kinds = session.capabilities.routineKinds.filter { !$0.isReadOnly }
		if !kinds.isEmpty {
			Menu("새로 만들기") {
				ForEach(kinds, id: \.self) { k in
					Button("\(k.label)…") { session.newRoutine(k, schema: schema) }
				}
			}
		}
	}
}

private struct RoutineGroupRow: View {
	let kind: RoutineKind
	let count: Int
	let open: Bool
	let toggle: () -> Void
	@State private var hover = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "chevron.right")
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(.secondary)
				.rotationEffect(.degrees(open ? 90 : 0))
				.frame(width: 12)
			Image(systemName: kind.icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
			Text(kind.label).foregroundStyle(.secondary)
			Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
			Spacer(minLength: 0)
		}
		.padding(.leading, 26)
		.padding(.trailing, 10)
		.frame(height: 24)
		.background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.05) : .clear))
		.padding(.horizontal, 6)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.onTapGesture { withAnimation(.easeOut(duration: 0.15)) { toggle() } }
	}
}

private struct RoutineRow: View {
	let routine: RoutineInfo
	let selected: Bool
	@State private var hover = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: routine.kind.icon)
				.font(.system(size: 10))
				.foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
				.frame(width: 14)
			Text(routine.name).lineLimit(1).truncationMode(.middle)
				.foregroundStyle(routine.enabled == false && !selected ? Color.secondary : (selected ? .white : .primary))
			Spacer(minLength: 8)
			if routine.enabled == false {
				Text("꺼짐").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .orange)
			} else if !routine.detail.isEmpty {
				Text(routine.detail).font(.caption).lineLimit(1).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
			}
		}
		.padding(.leading, 46)
		.padding(.trailing, 10)
		.frame(height: 24)
		.background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : (hover ? Color.primary.opacity(0.06) : .clear)))
		.padding(.horizontal, 6)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.help(routine.comment.isEmpty ? "\(routine.schema).\(routine.name)" : "\(routine.schema).\(routine.name)\n\(routine.comment)")
	}
}

/// 루틴 오른쪽 클릭: 열기 · 이름 복사 · (이벤트) 켜기/끄기 · 새로 만들기 · 지우기
struct RoutineMenu: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	let routine: RoutineInfo

	var body: some View {
		Button("열기") { session.openRoutine(routine) }
		Button("이름 복사") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(routine.name, forType: .string)
		}
		if routine.kind == .event, let on = routine.enabled {
			Button(on ? "이벤트 끄기" : "이벤트 켜기") {
				Task {
					_ = try? await session.query(dialect.setEventEnabled(dialect.quote(schema: routine.schema, table: routine.name), !on))
					await session.loadRoutines()
					await session.routineEditor(routine.id)?.load()
				}
			}
		}
		if !routine.kind.isReadOnly {
			Divider()
			Button("새 \(routine.kind.label)…") { session.newRoutine(routine.kind, schema: routine.schema) }
			Divider()
			Button("\(routine.kind.label) 삭제…", role: .destructive) { RoutineDrop.confirm(routine, session: session) }
		}
	}
}

enum RoutineDrop {
	@MainActor
	static func confirm(_ r: RoutineInfo, session: Session) {
		Task {
			guard await Confirm.ask("\(r.kind.label) ‘\(r.name)’ 을 삭제할까요?", "\(r.schema).\(r.name) — 되돌릴 수 없습니다.",
			                        buttons: ["삭제"], destructive: true) == 0 else { return }
			if let e = await session.dropRoutine(r) { await Confirm.inform("삭제하지 못했습니다", e) }
		}
	}
}

/// 루틴 탭: 위 줄(종류·이름·이벤트 켜기·DEFINER·되돌리기·지우기·저장) + SQL 편집기
struct RoutineTabView: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	let tab: String
	@Bindable var editor: RoutineEditor

	private var info: RoutineInfo? {
		guard let n = editor.name else { return nil }
		if editor.kind == .view {
			return session.tables.contains { $0.schema == editor.schema && $0.name == n && $0.isView } ? RoutineInfo(schema: editor.schema, name: n, kind: .view) : nil
		}
		return session.routines.first { $0.kind == editor.kind && $0.schema == editor.schema && $0.name == n }
	}

	@State private var running = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: editor.kind.icon).foregroundStyle(.secondary)
				Text(editor.isNew ? "새 \(editor.kind.label)" : editor.kind.label).foregroundStyle(.secondary)
				Text(editor.schema + "." + (editor.name ?? "")).font(.headline).lineLimit(1)
				if editor.kind == .event, let on = info?.enabled {
					Toggle(on ? "켜짐" : "꺼짐", isOn: Binding(get: { on }, set: { v in Task { await editor.setEnabled(v) } }))
						.toggleStyle(.switch).controlSize(.small)
				}
				Spacer()
				if session.capabilities.routineDefiner {
					Picker("DEFINER", selection: $editor.keepDefiner) {
						Text("원래 DEFINER 유지").tag(true)
						Text("지금 계정으로").tag(false)
					}
					.fixedSize()
					.help("저장할 때 DEFINER=… 를 그대로 둘지, 빼서 지금 접속한 계정으로 만들지")
				}
				if !editor.isNew && (editor.kind == .procedure || editor.kind == .function) {
					Button("실행…") { running = true }.disabled(info == nil)
						.help("인자를 넣어 CALL / SELECT 문을 쿼리 패널에 넣습니다")
				}
				if editor.kind == .view {
					Button("줄바꿈") { editor.text = SQLHighlight.format(editor.text, dialect.syntax) }
						.help("FROM · WHERE · JOIN 앞과 SELECT 목록의 쉼표 뒤에서 줄을 나눕니다 (뜻은 그대로)")
				}
				if editor.kind.isReadOnly {
					Text("보기만").foregroundStyle(.secondary)
				} else {
				if !editor.isNew {
					Button("되돌리기") { editor.revert() }.disabled(!editor.changed)
					Button(role: .destructive) { if let r = info { RoutineDrop.confirm(r, session: session) } } label: { Text("삭제…") }
						.disabled(info == nil)
				}
				Button { Task { await save() } } label: {
					HStack(spacing: 5) {
						if editor.saving { ProgressView().controlSize(.small) }
						Text(editor.isNew ? "만들기" : "저장")
						HStack(spacing: 0) { ShortcutKeys(symbols: ["command"]); Text("S").font(.system(size: 11, weight: .medium)) }.opacity(0.75)
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(!editor.changed || editor.saving)
				}
			}
			.controlSize(.regular)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			if editor.kind == .event && editor.schedulerOff {
				Label("서버의 이벤트 스케줄러가 꺼져 있어 이벤트가 돌지 않습니다 (SET GLOBAL event_scheduler = ON)", systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange).font(.callout)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 12).padding(.bottom, 6)
			}
			Divider()
			if editor.loaded {
				QueryEditor(text: $editor.text, session: session, database: editor.schema, readOnly: editor.kind.isReadOnly)
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			Divider()
			HStack(spacing: 8) {
				if let m = editor.message {
					Label(m, systemImage: editor.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
						.foregroundStyle(editor.isError ? Color.red : .green)
						.lineLimit(2).textSelection(.enabled)
				} else {
					Text(editor.kind.isReadOnly ? "패키지는 명세와 본문을 보기만 합니다 (본문은 볼 권한이 있을 때만)"
					     : editor.isNew ? "CREATE 문을 고친 뒤 만들기 (⌘S). DELIMITER 는 쓰지 않습니다 — BEGIN … END 를 그대로"
					     : editor.kind == .view || session.kind == .oracle ? "고친 뒤 저장(⌘S)하면 CREATE OR REPLACE 로 바꿉니다 (이름을 바꾸면 삭제하고 새로 만듭니다)"
					     : "고친 뒤 저장(⌘S)하면 삭제하고 다시 만듭니다. 만들다 실패하면 원래 것으로 되돌립니다")
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
			.font(.callout)
			.padding(.horizontal, 12)
			.frame(height: 34)
		}
		.task(id: tab) { if !editor.loaded { await editor.load() } }
		.sheet(isPresented: $running) {
			if let n = editor.name { RoutineRunSheet(session: session, kind: editor.kind, schema: editor.schema, name: n) }
		}
	}

	/// 저장 뒤 이름이 바뀌었으면(새로 만듦·이름 바꿈) 탭 id 도 새 이름으로
	@MainActor
	func save() async {
		guard let n = await editor.save() else { return }
		session.retargetRoutineTab(tab, to: RoutineInfo.tabID(editor.kind, editor.schema, n))
	}
}

/// 프로시저·함수 실행: 인자를 받아 CALL / SELECT 문을 쿼리 패널에 넣는다 (바로 실행하지 않는다).
/// 값은 글자로 넣으면 따옴표를 붙이고, 숫자 타입이면 그대로. @변수 나 = 로 시작하면 식 그대로. 비우면 NULL. OUT 인자는 @이름 으로 받고 뒤에 SELECT
struct RoutineRunSheet: View {
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	let kind: RoutineKind
	let schema: String
	let name: String
	@State private var params: [Param] = []
	@State private var values: [String] = []
	@State private var loaded = false
	@Environment(\.dismiss) private var dismiss

	struct Param {
		let mode: String
		let name: String
		let type: String
		var numeric: Bool {
			type.lowercased().range(of: #"^(tinyint|smallint|mediumint|int|integer|bigint|decimal|numeric|float|double|real|bit|bool|boolean)\b"#, options: .regularExpression) != nil
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(name) 실행").font(.headline)
			if !loaded {
				ProgressView().controlSize(.small)
			} else if params.isEmpty {
				Text("인자가 없습니다").foregroundStyle(.secondary)
			} else {
				Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
					ForEach(params.indices, id: \.self) { i in
						GridRow {
							Text(params[i].mode).font(.caption).foregroundStyle(.secondary)
							Text(params[i].name).font(.system(.body, design: .monospaced))
							Text(params[i].type).font(.caption).foregroundStyle(.secondary)
							if params[i].mode == "OUT" {
								Text("@\(params[i].name) 로 받음").foregroundStyle(.secondary)
							} else {
								TextField(params[i].numeric ? "숫자 (비우면 NULL)" : "값 (비우면 NULL)", text: $values[i])
									.textFieldStyle(.roundedBorder).frame(width: 220)
							}
						}
					}
				}
				Text("글자는 따옴표를 붙여 넣습니다. @변수나 = 로 시작하면 식 그대로 (예: =NOW())")
					.font(.callout).foregroundStyle(.secondary)
			}
			Text(sql).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
				.padding(8).frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("쿼리 패널에 넣기") { insert() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 560)
		.task { await load() }
	}

	private func load() async {
		let list = (try? await session.meta.routineParameters(session.query, schema: schema, name: name)) ?? []
		params = list.map { Param(mode: $0.mode, name: $0.name, type: $0.type) }
		values = Array(repeating: "", count: params.count)
		loaded = true
	}

	private func value(_ i: Int) -> String {
		let p = params[i]
		if p.mode == "OUT" { return dialect.outVariable(p.name) }
		let v = values.indices.contains(i) ? values[i].trimmingCharacters(in: .whitespaces) : ""
		if v.isEmpty || v.uppercased() == "NULL" { return "NULL" }
		if v.hasPrefix("@") { return v }
		if v.hasPrefix("=") { return String(v.dropFirst()) }
		if p.numeric, Double(v) != nil { return v }
		return dialect.literal(.text(v))
	}

	private var sql: String {
		dialect.callRoutine(kind, dialect.quote(schema: schema, table: name), args: params.indices.map(value),
		                    outs: params.filter { $0.mode != "IN" }.map(\.name)).map { $0 + ";" }.joined(separator: "\n")
	}

	private func insert() {
		guard let p = session.queryPanel else { dismiss(); return }
		p.text = p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sql : p.text + "\n\n" + sql
		if p.database.isEmpty { p.database = schema }
		p.open = true
		dismiss()
	}
}
