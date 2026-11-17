import SwiftUI
import AppKit

/// 사이드바 DB 아래 루틴 묶음: ▸ 프로시저 N · 함수 N · 트리거 N · 이벤트 N (있는 것만). 오른쪽 클릭으로 새로 만들기
struct RoutineGroups: View {
	let session: Session
	let schema: String
	/// 사이드바 찾기 글 (있으면 이름이 걸린 것만, 펼쳐서)
	var search = ""

	var body: some View {
		ForEach(RoutineKind.allCases, id: \.self) { kind in
			let all = session.routines(schema, kind)
			let items = search.isEmpty ? all : all.filter { $0.name.lowercased().contains(search.lowercased()) }
			if !items.isEmpty {
				let key = schema + "|" + kind.rawValue
				let open = !search.isEmpty || session.expandedRoutineGroups.contains(key)
				RoutineGroupRow(kind: kind, count: items.count, open: open) {
					if session.expandedRoutineGroups.contains(key) { session.expandedRoutineGroups.remove(key) } else { session.expandedRoutineGroups.insert(key) }
				}
				.contextMenu { Button("새 \(kind.label)…") { session.newRoutine(kind, schema: schema) } }
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
	let schema: String
	var body: some View {
		Menu("새로 만들기") {
			ForEach(RoutineKind.allCases, id: \.self) { k in
				Button("\(k.label)…") { session.newRoutine(k, schema: schema) }
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
					_ = try? await session.query("ALTER EVENT \(TableInspector.ident(routine.schema)).\(TableInspector.ident(routine.name)) \(on ? "DISABLE" : "ENABLE")")
					await session.loadRoutines()
					await session.routineEditor(routine.id)?.load()
				}
			}
		}
		Divider()
		Button("새 \(routine.kind.label)…") { session.newRoutine(routine.kind, schema: routine.schema) }
		Divider()
		Button("\(routine.kind.label) 삭제…", role: .destructive) { RoutineDrop.confirm(routine, session: session) }
	}
}

enum RoutineDrop {
	@MainActor
	static func confirm(_ r: RoutineInfo, session: Session) {
		let a = NSAlert()
		a.messageText = "\(r.kind.label) ‘\(r.name)’ 을 지울까요?"
		a.informativeText = "\(r.schema).\(r.name) — 되돌릴 수 없습니다."
		a.addButton(withTitle: "지우기")
		a.addButton(withTitle: "취소")
		a.buttons[0].hasDestructiveAction = true
		guard a.runModal() == .alertFirstButtonReturn else { return }
		Task {
			if let e = await session.dropRoutine(r) {
				let f = NSAlert()
				f.messageText = "지우지 못했습니다"
				f.informativeText = e
				f.runModal()
			}
		}
	}
}

/// 루틴 탭: 위 줄(종류·이름·이벤트 켜기·DEFINER·되돌리기·지우기·저장) + SQL 편집기
struct RoutineTabView: View {
	let session: Session
	let tab: String
	@Bindable var editor: RoutineEditor

	private var info: RoutineInfo? {
		editor.name.flatMap { n in session.routines.first { $0.kind == editor.kind && $0.schema == editor.schema && $0.name == n } }
	}

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
				Picker("DEFINER", selection: $editor.keepDefiner) {
					Text("원래 DEFINER 유지").tag(true)
					Text("지금 계정으로").tag(false)
				}
				.fixedSize()
				.help("저장할 때 DEFINER=… 를 그대로 둘지, 빼서 지금 접속한 계정으로 만들지")
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
				QueryEditor(text: $editor.text, session: session, database: editor.schema)
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
					Text(editor.isNew ? "CREATE 문을 고친 뒤 만들기 (⌘S). DELIMITER 는 쓰지 않습니다 — BEGIN … END 를 그대로"
					                  : "고친 뒤 저장(⌘S)하면 지우고 다시 만듭니다. 만들다 실패하면 원래 것으로 되돌립니다")
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
			.font(.callout)
			.padding(.horizontal, 12)
			.frame(height: 34)
		}
		.task(id: tab) { if !editor.loaded { await editor.load() } }
	}

	/// 저장 뒤 이름이 바뀌었으면(새로 만듦·이름 바꿈) 탭 id 도 새 이름으로
	@MainActor
	func save() async {
		guard let n = await editor.save() else { return }
		session.retargetRoutineTab(tab, to: RoutineInfo.tabID(editor.kind, editor.schema, n))
	}
}
