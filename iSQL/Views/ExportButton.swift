import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 하단바 "내보내기" 버튼: 누르면 세션에 요청 → 창이 제목바 시트(ExportSheet)를 띄운다
struct ExportButton: View {
	let action: () -> Void
	var body: some View {
		Button(action: action) {
			HStack(spacing: 5) {
				Image(systemName: "square.and.arrow.up")
				Text("내보내기")
			}
		}
		.help("내보내기")
	}
}

/// 내보내기 시트 (창 제목바에 붙는다). 어디서 불러도 이 하나를 쓴다: 하단바 버튼, 사이드바 테이블·DB 오른쪽 클릭, DB 개요
struct ExportSheet: View {
	let request: ExportRequest
	let session: Session
	@Environment(\.dismiss) private var dismiss
	@State private var sql = SQLExportOptions()
	@State private var db = DatabaseExportOptions()
	@State private var tabsReady = false
	/// 고르기 목록에서 체크한 테이블 이름
	@State private var picked: Set<String> = []

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(title).font(.headline)
			if let list = pickerTables { tablePicker(list) }
			TabView {
				sqlTab.tabItem { Text("SQL") }
			}
			// 시트 창은 처음에 크기 0 으로 만들어져 NSTabView 가 그때 탭 너비를 재고 다시 안 잰다(탭 이름이 "S…" 로 잘림).
			// → 시트가 뜬 뒤 한 번 다시 만든다 (tabsReady). 크기는 옵션 줄 수만큼 직접 준다
			.frame(width: 400, height: tabHeight)
			.id(tabsReady)
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("내보내기…", action: chooseFile)
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled(isDatabase && (picked.isEmpty || (!db.includeStructure && !db.includeData)))
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 440)
		.onAppear {
			switch request.target {
			case .data(let src): sql.tableName = src.exportTableName ?? "query_result"
			case .database(_, _, let p, _): picked = p
			}
			DispatchQueue.main.async { tabsReady = true }
		}
	}

	/// 탭 상자 높이: 옵션 세 줄, 테이블 이름 칸이 있으면 한 줄 더
	private var tabHeight: CGFloat {
		if case .data(let src) = request.target, src.exportTableName == nil { return 200 }
		return 162
	}

	private var isDatabase: Bool { if case .database = request.target { return true }; return false }

	/// 고르기 목록을 보일 때 그 후보들
	private var pickerTables: [TableStat]? {
		if case .database(_, let tables, _, true) = request.target { return tables }
		return nil
	}

	/// 실제로 내보낼 테이블 (후보 순서 그대로)
	private var chosenTables: [TableStat] {
		guard case .database(_, let tables, _, _) = request.target else { return [] }
		return tables.filter { picked.contains($0.name) }
	}

	private var title: String {
		switch request.target {
		case .data(let src): return "\(src.exportFileBase) 내보내기"
		case .database(let schema, let tables, _, let showPicker):
			if !showPicker, tables.count == 1 { return "\(schema).\(tables[0].name) 내보내기" }
			return "\(schema) 내보내기"
		}
	}

	/// 테이블 고르기: 위에 "n / 전체 개" 와 모두 선택·해제, 아래 체크 목록
	@ViewBuilder private func tablePicker(_ list: [TableStat]) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("테이블 \(picked.count) / \(list.count)개").foregroundStyle(.secondary).monospacedDigit()
				Spacer()
				Button("모두 선택") { picked = Set(list.map(\.name)) }
					.disabled(picked.count == list.count)
				Button("모두 해제") { picked = [] }
					.disabled(picked.isEmpty)
			}
			.buttonStyle(.link)
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(list, id: \.name) { t in
						Toggle(isOn: Binding(get: { picked.contains(t.name) },
						                     set: { if $0 { picked.insert(t.name) } else { picked.remove(t.name) } })) {
							HStack(spacing: 6) {
								Image(systemName: t.isView ? "eye" : "tablecells").foregroundStyle(.secondary).frame(width: 16)
								Text(t.name).lineLimit(1)
								if !t.comment.isEmpty {
									Text(t.comment).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
								}
							}
						}
						.toggleStyle(.checkbox)
						.padding(.horizontal, 8)
						.frame(height: 24)
						.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
				.padding(.vertical, 4)
			}
			.frame(height: min(CGFloat(list.count) * 24 + 8, 240))
			.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
		}
		.frame(width: 400)
	}

	@ViewBuilder private var sqlTab: some View {
		VStack(alignment: .leading, spacing: 10) {
			switch request.target {
			case .data(let src):
				if src.exportTableName == nil {
					// 쿼리 결과가 여러 테이블에서 왔으면 INSERT 에 쓸 이름
					HStack {
						Text("테이블 이름:").foregroundStyle(.secondary)
						TextField("", text: $sql.tableName).textFieldStyle(.roundedBorder)
					}
				}
				Toggle("테이블 구조 넣기 (CREATE TABLE)", isOn: $sql.includeStructure)
					.disabled(!src.canExportStructure)
					.help(src.canExportStructure ? "" : "여러 테이블에서 온 결과라 구조를 넣을 수 없습니다")
				Toggle("DROP TABLE IF EXISTS 넣기", isOn: $sql.includeDrop)
					.disabled(!src.canExportStructure || !sql.includeStructure)
					.padding(.leading, 20)
				Toggle("화면에 보이는 데이터만 (끄면 전체)", isOn: $sql.visibleOnly)
					.help("끄면 지금 조건·정렬 그대로 전체를 1,000행씩 받아 씁니다")
			case .database:
				Toggle("테이블 구조 넣기 (CREATE TABLE)", isOn: $db.includeStructure)
				Toggle("DROP TABLE IF EXISTS 넣기", isOn: $db.includeDrop)
					.disabled(!db.includeStructure)
					.padding(.leading, 20)
				Toggle("데이터 넣기 (INSERT)", isOn: $db.includeData)
					.help("테이블마다 전체를 1,000행씩 받아 씁니다")
			}
		}
		.toggleStyle(.checkbox)
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func chooseFile() {
		let panel = NSSavePanel()
		switch request.target {
		case .data(let src): panel.nameFieldStringValue = "\(src.exportFileBase).sql"
		case .database(let schema, _, _, _):
			let c = chosenTables
			panel.nameFieldStringValue = c.count == 1 ? "\(c[0].name).sql" : "\(schema).sql"
		}
		if let t = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [t] }
		panel.canCreateDirectories = true
		let target = request.target, session = session, chosen = chosenTables
		var sqlOptions = sql
		let dbOptions = db
		if case .data(let src) = target {
			if !src.canExportStructure { sqlOptions.includeStructure = false }
			if sqlOptions.tableName.trimmingCharacters(in: .whitespaces).isEmpty { sqlOptions.tableName = src.exportTableName ?? "query_result" }
		}
		dismiss()
		panel.begin { resp in
			guard resp == .OK, let url = panel.url else { return }
			let job = ExportJob()
			// 파인더 복사처럼 진행 창 (진행 막대·취소)
			ExportProgressWindow.show(job: job)
			Task { @MainActor in
				switch target {
				case .data(let src): await job.exportSQL(src, options: sqlOptions, to: url)
				case .database(let schema, _, _, _): await job.exportDatabase(session: session, schema: schema, tables: chosen, options: dbOptions, to: url)
				}
			}
		}
	}
}

/// 내보내기 진행 창 (파인더 파일 복사 창처럼): 파일 이름, 진행 막대, 행 수, 취소. 끝나면 잠깐 "완료" 후 닫힌다
@MainActor
enum ExportProgressWindow {
	private static var open: [NSWindow] = []

	static func show(job: ExportJob) {
		let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 110),
		                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
		panel.title = "내보내기"
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		panel.level = .floating
		let close = { [weak panel] in
			guard let panel else { return }
			panel.close()
			open.removeAll { $0 === panel }
		}
		panel.contentView = NSHostingView(rootView: ExportProgressView(job: job, close: close))
		// 창을 닫으면 그만둔다
		let delegate = PanelDelegate { job.cancel(); close() }
		objc_setAssociatedObject(panel, &PanelDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
		panel.delegate = delegate
		panel.center()
		panel.makeKeyAndOrderFront(nil)
		open.append(panel)
	}

	private final class PanelDelegate: NSObject, NSWindowDelegate {
		nonisolated(unsafe) static var key = 0
		let onClose: () -> Void
		init(_ f: @escaping () -> Void) { onClose = f }
		func windowShouldClose(_ sender: NSWindow) -> Bool { onClose(); return false }
	}
}

struct ExportProgressView: View {
	let job: ExportJob
	let close: () -> Void

	var body: some View {
		HStack(alignment: .center, spacing: 14) {
			Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: "sql") ?? .plainText))
				.resizable().frame(width: 40, height: 40)
			VStack(alignment: .leading, spacing: 6) {
				Text(title).lineLimit(1).truncationMode(.middle)
				if let t = job.total, t > 0 {
					ProgressView(value: min(Double(job.written), Double(t)), total: Double(t))
				} else {
					ProgressView().progressViewStyle(.linear)
				}
				Text(detail).font(.callout).foregroundStyle(job.isError ? Color.red : .secondary).monospacedDigit()
					.lineLimit(2).textSelection(.enabled)
			}
			if job.finished {
				Button("닫기", action: close)
			} else {
				// 파인더 복사 창처럼 오른쪽 ⓧ 로 취소
				Button { job.cancel() } label: {
					Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.help("그만두기")
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 16)
		.frame(width: 440)
		.onChange(of: job.finished) { _, done in
			// 잘 끝났으면 잠깐 보여 주고 닫는다 (오류·그만둠은 남겨 둔다)
			if done && !job.isError && job.message?.hasPrefix("그만둠") != true {
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() }
			}
		}
	}

	private var title: String {
		if job.finished { return job.isError ? "\(job.fileName) 내보내기 실패" : "\(job.fileName) 완료" }
		return "\(job.fileName) 내보내는 중"
	}

	private var detail: String {
		if let m = job.message, job.finished { return m }
		if let t = job.total, t > 0 {
			return "\(job.written.formatted()) / \(job.totalApprox ? "약 " : "")\(t.formatted())행"
		}
		return "\(job.written.formatted())행"
	}
}
