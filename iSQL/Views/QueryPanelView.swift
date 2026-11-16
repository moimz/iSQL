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
		// 위험한 쿼리는 서버와 상관없이 늘 확인한다
		let found = statements.compactMap { st in SQLSplitter.danger(st).map { "• \($0)\n  \(st.prefix(120))" } }
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
					ResultTabItem(title: "결과 \(i + 1)", detail: o.totalText, sql: o.sql,
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
				ZStack {
					TableGrid(source: o.source).id(ObjectIdentifier(o.source))
					if o.loading {
						Color(nsColor: .windowBackgroundColor).opacity(0.55).padding(.top, 28).allowsHitTesting(false)
						ProgressView()
					}
				}
				Divider()
				// 아래 줄: 왼쪽은 내보내기와 실행한 SQL, 오른쪽은 쪽 줄
				HStack(spacing: 10) {
					ExportButton { o.session?.requestExport(.data(o)) }
					Text(o.sql).font(.callout.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
						.help(o.sql)
					Spacer(minLength: 12)
					PagerBar(pager: o)
				}
				.controlSize(.large)
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
			}
		}
		.background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
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
		.onTapGesture(perform: select)
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

	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: QueryEditor
		weak var textView: NSTextView?
		init(_ p: QueryEditor) { parent = p }

		func textDidChange(_ notification: Notification) {
			guard let tv = textView else { return }
			parent.text = tv.string
		}

		func textViewDidChangeSelection(_ notification: Notification) {
			guard let tv = textView else { return }
			parent.panel.selection = tv.selectedRange()
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
