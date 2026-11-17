import SwiftUI
import AppKit

/// 접속한 서버의 본문: [쿼리 패널 (열렸을 때)] + [탭 영역]. SELECT 결과는 탭 영역의 왼쪽 칸을 덮는다
struct ConnectedArea: View {
	let session: Session
	let model: WindowModel

	var body: some View {
		VStack(spacing: 0) {
			// 애니메이션은 패널·결과의 등장/퇴장(transition)에만 붙인다.
			// 바깥에 .animation 을 걸면 그 아래 모든 뷰의 위치가 프레임마다 다시 배치돼 메인 스레드가 100% 바빴다 (Time Profiler 로 확인, Ai/iSQL.md)
			if let q = session.queryPanel, q.open {
				QueryPanelView(session: session, panel: q)
					.transition(.move(edge: .top).animation(.easeOut(duration: 0.2)))
				Divider()
			}
			// SELECT 결과는 탭 영역의 왼쪽 칸만 덮는다 (오른쪽 분할은 그대로 보여 결과와 나란히 비교). TabArea 안에서 그린다
			TabArea(session: session, model: model)
		}
		// ⌘K 빠른 열기: 위 가운데, 바깥을 누르면 닫힘
		.overlay(alignment: .top) {
			if model.showQuickOpen {
				ZStack(alignment: .top) {
					Color.black.opacity(0.12)
						.contentShape(Rectangle())
						.onTapGesture { model.showQuickOpen = false }
					QuickOpenView(session: session) { model.showQuickOpen = false }
						.padding(.top, 60)
				}
			}
		}
	}
}

/// 쿼리 입력창 + 실행 줄
struct QueryPanelView: View {
	let session: Session
	@Bindable var panel: QueryPanel
	@State private var dangers: [String] = []
	@State private var pending: [String] = []
	@State private var dragStart: CGFloat?

	var body: some View {
		VStack(spacing: 0) {
			QueryEditor(text: $panel.text, panel: panel)
				.frame(height: panel.height)
			Divider()
			actionBar
		}
		// 높이 조절: 패널 맨 아래 경계(실행 줄 바로 아래)를 잡고 끈다
		.overlay(alignment: .bottom) {
			Color.clear
				.frame(height: 8)
				.contentShape(Rectangle())
				.offset(y: 4)
				.onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
				.gesture(DragGesture(minimumDistance: 1)
					.onChanged { v in
						if dragStart == nil { dragStart = panel.height }
						panel.height = min(600, max(80, (dragStart ?? panel.height) + v.translation.height))
					}
					.onEnded { _ in dragStart = nil })
		}
		.background(Color(nsColor: .textBackgroundColor).opacity(0.35), ignoresSafeAreaEdges: [])
		.onAppear {
			// 기본 DB: 지금 보고 있는 탭의 DB, 없으면 연결의 기본 DB
			if panel.database.isEmpty {
				panel.database = session.activeTab.flatMap { session.table($0)?.schema } ?? session.currentDB
			}
		}
		.confirmationDialog("위험한 쿼리입니다", isPresented: Binding(get: { !dangers.isEmpty }, set: { if !$0 { dangers = [] } })) {
			Button("그래도 실행", role: .destructive) {
				let run = pending
				dangers = []
				Task { await panel.run(run) }
			}
		} message: {
			Text(dangers.joined(separator: "\n"))
		}
	}

	private var actionBar: some View {
		HStack(spacing: 8) {
			PopUp(selection: $panel.database, options: [("DB 고르지 않음", Optional(""))] + session.databases.map { ($0, Optional($0)) })
				.frame(width: 170)
				.help("쿼리를 돌릴 기본 DB (USE)")
			Button { run(all: false) } label: {
				HStack(spacing: 5) {
					if panel.running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
					Text("실행")
					ShortcutKeys(symbols: ["command", "return"]).opacity(0.75)
				}
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.return, modifiers: .command)
			.disabled(panel.running)
			.help("선택한 부분, 없으면 커서가 있는 문장 (⌘↩)")
			Button { run(all: true) } label: {
				HStack(spacing: 5) {
					Text("전체 실행")
					ShortcutKeys(symbols: ["command", "shift", "return"]).foregroundStyle(.secondary)
				}
			}
				.keyboardShortcut(.return, modifiers: [.command, .shift])
				.disabled(panel.running)
				.help("모든 문장 (⌘⇧↩)")
			// 실행계획: 실행하지 않고 EXPLAIN 만 (고른 부분, 없으면 커서가 있는 문장)
			Button {
				let st = panel.statementsToRun(all: false)
				if st.isEmpty { NSSound.beep() } else { Task { await panel.explain(st) } }
			} label: {
				HStack(spacing: 5) {
					Text("실행계획")
					ShortcutKeys(symbols: ["option", "command", "return"]).foregroundStyle(.secondary)
				}
			}
				.keyboardShortcut(.return, modifiers: [.command, .option])
				.disabled(panel.running)
				.help("EXPLAIN: 쿼리를 실행하지 않고 어떻게 읽을지 봅니다 (⌥⌘↩)")
			if let m = panel.message {
				Text(m)
					.foregroundStyle(panel.isError ? Color.red : .secondary)
					.lineLimit(2)
					.textSelection(.enabled)
					.help(m)
			}
			Spacer(minLength: 8)
			// 패널 닫기는 제목바 쿼리 버튼·⌘J. 여기는 결과 보기/숨기기 하나만 맨 오른쪽에
			if !panel.outputs.isEmpty {
				Button { panel.showResults.toggle() } label: {
					HStack(spacing: 5) {
						Text(panel.showResults ? "결과 숨기기" : "결과 보기")
						Image(systemName: panel.showResults ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
					}
				}
				.help(panel.showResults ? "결과를 걷고 탭을 봅니다" : "마지막 결과를 다시 봅니다")
			}
		}
		.controlSize(.large)
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private func run(all: Bool) {
		let statements = panel.statementsToRun(all: all)
		guard !statements.isEmpty else { NSSound.beep(); return }
		// 위험한 쿼리는 확인한다 (서버 설정 > 일반 에서 끌 수 있다, 기본 켬)
		let warn = panel.session?.server?.warnsDangerousSQL ?? true
		let found = warn ? statements.compactMap { st in SQLSplitter.danger(st).map { "• \($0)\n  \(st.prefix(120))" } } : []
		if found.isEmpty {
			Task { await panel.run(statements) }
		} else {
			pending = statements
			dangers = found
		}
	}

}

/// SELECT 결과: 탭 영역을 덮는다. 위는 테이블 탭과 같은 모양의 결과 탭(닫기 없음), 아래는 쪽 줄
struct QueryResultsOverlay: View {
	@Bindable var panel: QueryPanel

	var body: some View {
		VStack(spacing: 0) {
			// 결과 탭바 (테이블 탭바와 같은 모양)
			TabStrip(selected: panel.selectedOutput) {
				ForEach(Array(panel.outputs.enumerated()), id: \.element.id) { i, o in
					ResultTabItem(title: o.plan != nil ? "실행계획 \(i + 1)" : "결과 \(i + 1)",
					              detail: o.plan.map { $0.warnings.isEmpty ? "경고 없음" : "경고 \($0.warnings.count)" } ?? o.totalText, sql: o.sql,
					              active: i == panel.selectedOutput, loading: o.loading) {
						panel.selectedOutput = i
					}
					.id(i)
				}
			}
			.frame(height: 36)
			.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
			Divider()
			if panel.outputs.indices.contains(panel.selectedOutput) {
				let o = panel.outputs[panel.selectedOutput]
				ResultBody(output: o, source: o.source)
					.id(ObjectIdentifier(o.source))
			}
		}
		.background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
	}
}

/// 결과 하나: 표 + 아래 줄. 고칠 수 있는 결과면 [+ −] 와 저장 바 (데이터 탭과 같음)
struct ResultBody: View {
	let output: QueryOutput
	@Bindable var source: QueryResultSource
	@State private var selection = IndexSet()
	@State private var creatingView = false

	/// SELECT 결과만 뷰로 만들 수 있다 (SHOW·EXPLAIN 등은 안 됨)
	private var viewable: Bool {
		let head = output.sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8).lowercased()
		return head.hasPrefix("select") || head.hasPrefix("with") || head.hasPrefix("(")
	}

	var body: some View {
		if let plan = output.plan { ExplainHeader(plan: plan) }
		ZStack {
			TableGrid(source: source) { selection = $0 }
			if output.loading {
				Color(nsColor: .windowBackgroundColor).opacity(0.55).padding(.top, 28).allowsHitTesting(false)
				ProgressView()
			}
		}
		.sheet(isPresented: $source.showSQL) { SQLPreview(statements: source.changeSQL()) }
		.sheet(isPresented: $creatingView) { if let s = output.session { CreateViewSheet(sql: output.sql, session: s) } }
		Divider()
		// ⌘S 는 TabArea 하나가 받는다: 결과가 탭을 덮고 있으면 결과를 저장
		if source.hasChanges { changesBar } else { footer }
	}

	/// 아래 줄: [+ −][내보내기] 또는 [내보내기] + 보기만 까닭, 실행한 SQL, 쪽 줄
	private var footer: some View {
		HStack(spacing: 10) {
			if source.canEdit {
				AddExportGroup(addHelp: "행 추가", add: { source.addRow() },
				               showsRemove: true, removeHelp: "고른 행 지우기 (저장할 때 반영)",
				               remove: selection.isEmpty ? nil : { source.toggleDelete(selection) },
				               exportHelp: "내보내기", makeView: viewable ? { creatingView = true } : nil) { output.session?.requestExport(.data(output)) }
			} else {
				ExportButton(makeView: viewable ? { creatingView = true } : nil) { output.session?.requestExport(.data(output)) }
				if let why = source.readOnlyReason {
					Image(systemName: "lock").foregroundStyle(.secondary).help(why)
				}
			}
			Text(output.sql).font(.callout.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
				.help(output.sql)
			Spacer(minLength: 12)
			PagerBar(pager: output)
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}

	/// 저장 안 한 변경이 있을 때 (데이터 탭 저장 바와 같은 모양)
	private var changesBar: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let err = source.saveError {
				Label(err, systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 10) {
				AddRemovePill(addHelp: "행 추가", add: { source.addRow() },
				              removeHelp: "고른 행 지우기 (저장할 때 반영)",
				              remove: selection.isEmpty ? nil : { source.toggleDelete(selection) })
				Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
				// 좁은 칸(분할)에서도 한 줄로: 종류(수정·추가·삭제)는 행 색으로 보이므로 개수만, 나눈 수는 마우스를 올리면
				Text("미반영 변경 \(source.changeCount)건").font(.headline).lineLimit(1).fixedSize()
					.help(detail)
				Spacer()
				Button("SQL 미리보기") { source.showSQL = true }
				Button("되돌리기") { source.discard() }
				Button {
					Task { await source.save() }
				} label: {
					if source.saving { ProgressView().controlSize(.small) } else { Text("저장  ⌘S") }
				}
				.buttonStyle(.borderedProminent)
				.disabled(source.saving)
			}
		}
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(Color.yellow.opacity(0.18), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { Rectangle().fill(Color.orange.opacity(0.5)).frame(height: 1) }
	}

	private var detail: String {
		var parts: [String] = []
		if source.editCount > 0 { parts.append("수정 \(source.editCount)") }
		if !source.deleted.isEmpty { parts.append("삭제 \(source.deleted.count)") }
		if !source.inserted.isEmpty { parts.append("추가 \(source.inserted.count)") }
		return parts.joined(separator: ", ")
	}
}

/// 결과 탭 하나 (테이블 탭과 같은 모양, 닫기 없음)
struct ResultTabItem: View {
	let title: String
	let detail: String
	let sql: String
	let active: Bool
	var loading = false
	let select: () -> Void
	@State private var hover = false

	var body: some View {
		HStack(spacing: 6) {
			Group {
				if loading { ProgressView().controlSize(.mini) }
				else {
					Image(systemName: "tablecells").font(.system(size: 11))
						.foregroundStyle(active ? Color.accentColor : .secondary)
				}
			}
			.frame(width: 14, height: 14)
			TabTitle(text: title, active: active)
			Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
		}
		.padding(.horizontal, 12)
		.frame(height: 36)
		.frame(minWidth: 110, maxWidth: 260, alignment: .leading)
		.background(active ? Color(nsColor: .windowBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
		.overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.onMouseDown(perform: select)
		.help(sql)
	}
}

/// 쿼리 입력창 (NSTextView): 고정폭, 똑똑한 따옴표·자동 고침 끔
struct QueryEditor: NSViewRepresentable {
	@Binding var text: String
	let panel: QueryPanel

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSScrollView()
		let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
		tv.minSize = NSSize(width: 0, height: 0)
		tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		tv.isRichText = false
		tv.allowsUndo = true
		tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
		tv.textColor = .labelColor
		tv.backgroundColor = .clear
		tv.drawsBackground = false
		tv.isAutomaticQuoteSubstitutionEnabled = false
		tv.isAutomaticDashSubstitutionEnabled = false
		tv.isAutomaticTextReplacementEnabled = false
		tv.isAutomaticSpellingCorrectionEnabled = false
		tv.isContinuousSpellCheckingEnabled = false
		tv.isGrammarCheckingEnabled = false
		tv.textContainerInset = NSSize(width: 8, height: 8)
		tv.isVerticallyResizable = true
		tv.isHorizontallyResizable = false
		tv.autoresizingMask = [.width]
		tv.textContainer?.widthTracksTextView = true
		tv.string = text
		tv.delegate = context.coordinator
		scroll.documentView = tv
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		context.coordinator.textView = tv
		// 패널이 열리면 바로 입력할 수 있게
		DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		context.coordinator.parent = self
		guard let tv = context.coordinator.textView else { return }
		if tv.string != text { tv.string = text }
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: QueryEditor
		weak var textView: NSTextView?
		/// 자동완성 목록 (낱말을 치거나 . 뒤, ⌥Esc 로 직접)
		private lazy var popup: CompletionPopup = {
			let p = CompletionPopup()
			p.onPick = { [weak self] in self?.accept($0) }
			return p
		}()
		/// 바꿀 범위 (커서 앞 낱말)
		private var replaceRange = NSRange(location: 0, length: 0)
		/// 글자를 쳐서 바뀐 것인지 (선택만 옮긴 것과 구분)
		private var typing = false
		init(_ p: QueryEditor) { parent = p }

		func textDidChange(_ notification: Notification) {
			guard let tv = textView else { return }
			parent.text = tv.string
			if typing { typing = false; refresh(force: false) } else { popup.hide() }
		}

		func textViewDidChangeSelection(_ notification: Notification) {
			guard let tv = textView else { return }
			parent.panel.selection = tv.selectedRange()
			// 커서를 낱말 밖으로 옮기면 닫는다
			if popup.isVisible {
				let r = tv.selectedRange()
				if r.length > 0 || r.location < replaceRange.location || r.location > NSMaxRange(replaceRange) + 1 { popup.hide() }
			}
		}

		func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
			// 한 글자를 치거나 지울 때만 목록을 띄우거나 고친다 (붙여넣기·실행 취소는 아님)
			if let t = text, t.count == 1, let ch = t.first, ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "`" || ch == "$" {
				typing = true
			} else if text == "", range.length == 1, popup.isVisible {
				typing = true
			} else {
				typing = false
			}
			return true
		}

		func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
			if sel == #selector(NSResponder.complete(_:)) {   // ⌥Esc
				refresh(force: true)
				return true
			}
			guard popup.isVisible else { return false }
			switch sel {
			case #selector(NSResponder.moveUp(_:)): popup.move(-1)
			case #selector(NSResponder.moveDown(_:)): popup.move(1)
			case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): popup.move(-9)
			case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): popup.move(9)
			case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
				if let s = popup.selected { accept(s) } else { popup.hide() }
			case #selector(NSResponder.cancelOperation(_:)): popup.hide()
			case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)): popup.hide(); return false
			default: return false
			}
			return true
		}

		func textDidEndEditing(_ notification: Notification) { popup.hide() }

		private func refresh(force: Bool) {
			guard let tv = textView, let session = parent.panel.session, let window = tv.window else { popup.hide(); return }
			let caret = tv.selectedRange()
			guard caret.length == 0,
			      let r = SQLCompleter.complete(text: tv.string, caret: caret.location, session: session,
			                                    defaultDB: parent.panel.database.isEmpty ? session.currentDB : parent.panel.database, force: force)
			else { popup.hide(); return }
			replaceRange = r.range
			// 커서 위치(화면 좌표)
			let rect = tv.firstRect(forCharacterRange: NSRange(location: r.range.location, length: 0), actualRange: nil)
			popup.show(r.items, below: rect, parent: window)
		}

		private func accept(_ item: CompletionItem) {
			guard let tv = textView else { return }
			popup.hide()
			let r = replaceRange
			guard NSMaxRange(r) <= (tv.string as NSString).length else { return }
			// 입력처럼 넣어야 실행 취소(⌘Z)가 고르기 하나만 되돌린다 (textStorage 를 직접 바꾸면 치던 글자와 섞였다)
			tv.breakUndoCoalescing()
			tv.insertText(item.insert, replacementRange: r)
			tv.breakUndoCoalescing()
		}
	}
}

/// Esc 는 선택만 푼다 (패널은 닫지 않는다: 선택을 취소하려고 누르는 키라서)
final class EditorTextView: NSTextView {
	override func cancelOperation(_ sender: Any?) {
		let r = selectedRange()
		if r.length > 0 { setSelectedRange(NSRange(location: NSMaxRange(r), length: 0)) }
	}
}

/// 맥 메뉴와 같은 단축키 표시 (⌘ ⇧ ↩ 를 글자로 쓰면 한글 글꼴로 그려져 모양이 달라진다 → 시스템 기호 이미지)
struct ShortcutKeys: View {
	let symbols: [String]
	var body: some View {
		HStack(spacing: 1) {
			ForEach(symbols, id: \.self) { Image(systemName: $0) }
		}
		.font(.system(size: 11, weight: .medium))
	}
}

/// 실행계획 결과 위쪽: 경고 목록 + 나무(FORMAT=TREE). 아래는 전통 EXPLAIN 표 (문제 칸 색칠)
struct ExplainHeader: View {
	let plan: ExplainPlan

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				if plan.warnings.isEmpty {
					Label("눈에 띄는 문제 없음", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
				}
				ForEach(plan.warnings, id: \.self) { w in
					Label(w.text, systemImage: w.severe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
						.foregroundStyle(w.severe ? Color.red : Color.orange)
				}
			}
			.font(.callout)
			.textSelection(.enabled)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			if let tree = plan.tree, !tree.isEmpty {
				Divider()
				ScrollView([.vertical, .horizontal]) {
					Text(tree)
						.font(.system(size: 12, design: .monospaced))
						.textSelection(.enabled)
						.fixedSize()
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(12)
				}
				.frame(height: min(240, CGFloat(tree.split(separator: "\n").count) * 17 + 26))
				.background(Color(nsColor: .textBackgroundColor).opacity(0.5))
			}
			Divider()
		}
	}
}
