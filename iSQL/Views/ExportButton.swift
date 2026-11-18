import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 하단바 "내보내기" 버튼: 누르면 세션에 요청 → 창이 제목바 시트(ExportSheet)를 띄운다
struct ExportButton: View {
	var help = "내보내기"
	/// 쿼리 결과: 같은 알약 안에 [뷰로 만들기] (눈 모양)
	var makeView: (() -> Void)? = nil
	let action: () -> Void
	var body: some View {
		// 아이콘만, 유리 알약 (하단바 [+ −] 알약과 같은 모양)
		HStack(spacing: 0) {
			Button(action: action) { PillIcon(systemName: "square.and.arrow.up") }
				.help(help)
			if let makeView {
				Button(action: makeView) { PillIcon(systemName: "eye") }
					.help("이 쿼리로 뷰 만들기")
			}
		}
		.pill()
		.fixedSize()
	}
}

/// 내보내기 시트 (창 제목바에 붙는다). 어디서 불러도 이 하나를 쓴다: 하단바 버튼, 사이드바 테이블·DB 오른쪽 클릭, DB 개요
struct ExportSheet: View {
	let request: ExportRequest
	let session: Session
	@Environment(\.dismiss) private var dismiss
	@State private var sql = SQLExportOptions()
	@State private var db = DatabaseExportOptions()
	@State private var excel = ExcelExportOptions()
	@State var imodules = IModulesExportOptions()
	/// 고른 탭 (SQL / Excel)
	/// 고른 탭은 다음에도 (이 맥에만)
	@AppStorage("exportFormat") private var format = Format.sql
	enum Format: String, Hashable { case sql, excel, imodules }
	@State private var tabsReady = false
	/// 고르기 목록에서 체크한 테이블 이름
	@State private var picked: Set<String> = []

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(title).font(.headline)
			if let list = pickerTables { tablePicker(list) }
			TabView(selection: $format) {
				sqlTab.tabItem { Text("SQL") }.tag(Format.sql)
				excelTab.tabItem { Text("Excel") }.tag(Format.excel)
				// iModules 는 MySQL 에서만 (iModules 가 여러 DB 를 지원하면 하나씩 붙인다, 사용자 2026-11-18)
				if session.capabilities.iModulesExport {
					imodulesTab.tabItem { Text("iModules") }.tag(Format.imodules)
				}
			}
			// 시트 창은 처음에 크기 0 으로 만들어져 NSTabView 가 그때 탭 너비를 재고 다시 안 잰다(탭 이름이 "S…" 로 잘림).
			// → 시트가 뜬 뒤 한 번 다시 만든다 (tabsReady). 크기는 옵션 줄 수만큼 직접 준다
			.frame(width: 400, height: tabHeight)
			.id(tabsReady)
			.onAppear { if format == .imodules && !session.capabilities.iModulesExport { format = .sql } }
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("내보내기…", action: chooseFile)
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled((format == .imodules && !isDatabase) || (isDatabase && (picked.isEmpty || (format == .sql && !db.includeStructure && !db.includeData))))
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 440)
		.onAppear {
			switch request.target {
			case .data(let src): sql.tableName = src.exportTableName ?? "query_result"
			case .database(_, let tables, let p, _):
				picked = p
				imodules.prefix = Self.commonPrefix(tables.filter { p.contains($0.name) }.map(\.name))
			}
			DispatchQueue.main.async { tabsReady = true }
		}
	}

	/// 탭 상자 높이: 고른 탭의 옵션 줄 수만큼
	private var tabHeight: CGFloat {
		if format == .imodules { return isDatabase ? 190 : 120 }
		if format == .excel {
			// 첫 행·코멘트 / 형식 유지(설명 두 줄) / 화면에 보이는 것만 또는 여러 테이블 묶기
			var h: CGFloat = 164
			if isDatabase ? chosenTables.count > 1 || pickerTables != nil : true { h += 30 }
			return h
		}
		if case .data(let src) = request.target, src.exportTableName == nil { return 200 }
		return 162
	}

	var isDatabase: Bool { if case .database = request.target { return true }; return false }

	/// 고르기 목록을 보일 때 그 후보들
	private var pickerTables: [TableStat]? {
		if case .database(_, let tables, _, true) = request.target { return tables }
		return nil
	}

	/// 실제로 내보낼 테이블 (후보 순서 그대로)
	var chosenTables: [TableStat] {
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
								Text(t.name).lineLimit(1).layoutPriority(1)
								// 코멘트는 오른쪽 끝에 붙인다 (이름 길이가 달라도 줄이 맞게)
								Spacer(minLength: 12)
								if !t.comment.isEmpty {
									Text(t.comment).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
								}
							}
							.frame(maxWidth: .infinity)
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
				Toggle("테이블 구조 포함 (CREATE TABLE)", isOn: $sql.includeStructure)
					.disabled(!src.canExportStructure)
					.help(src.canExportStructure ? "" : "여러 테이블에서 온 결과라 구조를 넣을 수 없습니다")
				Toggle("기존 테이블이 존재할 경우 삭제 (DROP TABLE IF EXISTS)", isOn: $sql.includeDrop)
					.disabled(!src.canExportStructure || !sql.includeStructure)
					.padding(.leading, 20)
				Toggle("화면에 보이는 데이터만 (끄면 전체)", isOn: $sql.visibleOnly)
					.help("끄면 지금 조건·정렬 그대로 전체를 1,000행씩 받아 씁니다")
			case .database:
				Toggle("테이블 구조 포함 (CREATE TABLE)", isOn: $db.includeStructure)
				Toggle("기존 테이블이 존재할 경우 삭제 (DROP TABLE IF EXISTS)", isOn: $db.includeDrop)
					.disabled(!db.includeStructure)
					.padding(.leading, 20)
				Toggle("데이터 포함 (INSERT)", isOn: $db.includeData)
					.help("테이블마다 전체를 1,000행씩 받아 씁니다")
			}
		}
		.toggleStyle(.checkbox)
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// 엑셀 탭: 첫 행(컬럼 이름 / 코멘트), 형식 유지, 화면에 보이는 것만 또는 여러 테이블을 한 파일에
	@ViewBuilder private var excelTab: some View {
		VStack(alignment: .leading, spacing: 10) {
			Toggle("첫 행에 컬럼 이름 넣기", isOn: $excel.header)
			HStack(spacing: 6) {
				Text("코멘트 형식:").foregroundStyle(excel.header ? .primary : .secondary)
				PopUp(selection: $excel.headerComment, options: HeaderComment.allCases.map { ($0.title, $0) })
					.frame(width: 220)
			}
			.padding(.leading, 20)
			.disabled(!excel.header)
			VStack(alignment: .leading, spacing: 2) {
				Toggle("형식 유지", isOn: $excel.keepTypes)
				Text("컬럼의 데이터(날짜, 숫자, 숫자로만 이루어진 문자)에 따라 엑셀의 셀 형식을 최대한 유지합니다.")
					.font(.callout).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, 20)
			}
			switch request.target {
			case .data:
				Toggle("화면에 보이는 데이터만 (끄면 전체)", isOn: $excel.visibleOnly)
					.help("끄면 지금 조건·정렬 그대로 전체를 1,000행씩 받아 씁니다")
			case .database:
				if chosenTables.count > 1 || pickerTables != nil {
					Toggle("한 파일에 테이블마다 시트 (끄면 테이블마다 파일)", isOn: $excel.oneFile)
						.disabled(chosenTables.count < 2)
				}
			}
		}
		.toggleStyle(.checkbox)
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func chooseFile() {
		if format == .excel { chooseExcel(); return }
		if format == .imodules { chooseIModules(); return }
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

extension ExportSheet {
	/// 엑셀: 파일 하나면 저장 창, 테이블마다 파일이면 폴더 고르기
	private func chooseExcel() {
		let target = request.target, session = session, options = excel
		let chosen = chosenTables
		var specs: [ExcelSheetSpec]
		var baseName: String
		switch target {
		case .data(let src):
			specs = [.data(src, visibleOnly: options.visibleOnly)]
			baseName = src.exportFileBase
		case .database(let schema, _, _, _):
			specs = chosen.map { ExcelSheetSpec.table(session: session, schema: schema, $0) }
			baseName = chosen.count == 1 ? chosen[0].name : schema
		}
		let oneFile = specs.count < 2 || options.oneFile
		dismiss()
		func run(_ url: URL) {
			let job = ExportJob()
			ExportProgressWindow.show(job: job)
			Task { @MainActor in await job.exportExcel(specs, options: options, to: url, oneFile: oneFile) }
		}
		if oneFile {
			let panel = NSSavePanel()
			panel.nameFieldStringValue = baseName + ".xlsx"
			if let t = UTType(filenameExtension: "xlsx") { panel.allowedContentTypes = [t] }
			panel.canCreateDirectories = true
			panel.begin { resp in if resp == .OK, let url = panel.url { run(url) } }
		} else {
			let panel = NSOpenPanel()
			panel.title = "엑셀 파일을 둘 폴더"
			panel.prompt = "여기에 저장"
			panel.canChooseFiles = false
			panel.canChooseDirectories = true
			panel.canCreateDirectories = true
			panel.begin { resp in if resp == .OK, let url = panel.url { run(url) } }
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
			Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (job.fileName as NSString).pathExtension.isEmpty ? "sql" : (job.fileName as NSString).pathExtension) ?? .plainText))
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

extension ExportSheet {
	/// iModules 탭: 접두어 빼기, 데이터(datas) 넣기. 테이블·DB 를 내보낼 때만
	@ViewBuilder var imodulesTab: some View {
		VStack(alignment: .leading, spacing: 10) {
			if isDatabase {
				HStack(spacing: 6) {
					Text("iModules 접두어:")
					TextField("없음", text: $imodules.prefix).textFieldStyle(.roundedBorder).frame(width: 140)
				}
				Toggle("데이터 포함 (datas)", isOn: $imodules.includeData).toggleStyle(.checkbox)
				Text("iModules의 package.json 형식에 맞게 내보냅니다.")
					.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			} else {
				Text("iModules 형식은 테이블이나 데이터베이스를 내보낼 때 씁니다 (사이드바 우클릭 → 내보내기).")
					.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// 고른 테이블들의 공통 접두어 (마지막 _ 까지): im_core_assignments, im_core_files → im_core_
	static func commonPrefix(_ names: [String]) -> String {
		guard var p = names.first else { return "" }
		for n in names.dropFirst() { while !n.hasPrefix(p) { p.removeLast() } }
		if names.count == 1 { p = String(p.dropLast()) }
		guard let i = p.lastIndex(of: "_") else { return "" }
		return String(p[...i])
	}

	func chooseIModules() {
		guard case .database(let schema, _, _, _) = request.target else { return }
		let chosen = chosenTables, session = session, options = imodules
		dismiss()
		let panel = NSSavePanel()
		panel.nameFieldStringValue = (chosen.count == 1 ? chosen[0].name : schema) + ".json"
		panel.allowedContentTypes = [.json]
		panel.canCreateDirectories = true
		panel.begin { resp in
			guard resp == .OK, let url = panel.url else { return }
			let job = ExportJob()
			ExportProgressWindow.show(job: job)
			Task { @MainActor in await job.exportIModules(session: session, schema: schema, tables: chosen, options: options, to: url) }
		}
	}
}
