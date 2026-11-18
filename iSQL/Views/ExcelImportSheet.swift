import SwiftUI
import AppKit

/// 엑셀 가져오기 시트: 파일·시트, 넣을 곳(새 테이블 / 기존 테이블), 옵션, 미리보기(앞 8행), 진행
struct ExcelImportSheet: View {
	let request: ExcelImportRequest
	@Bindable var job: ExcelImportJob
	@State private var preview: ExcelPreviewSource
	@State private var showSQL = false
	@Environment(\.dismiss) private var dismiss

	init(request: ExcelImportRequest) {
		self.request = request
		job = request.job
		_preview = State(initialValue: ExcelPreviewSource(job: request.job))
	}

	private var locked: Bool { job.running || job.finished }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("엑셀 파일 가져오기").font(.headline)
			fileRow
			if let e = job.loadError {
				Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
			}
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				if job.sheets.count > 1 {
					GridRow {
						Text("시트:").gridColumnAlignment(.trailing)
						PopUp(selection: $job.sheetIndex, options: job.sheets.indices.map { (job.sheets[$0].name, $0) })
							.frame(width: 240).disabled(locked)
					}
				}
				GridRow {
					Text("테이블 선택:").gridColumnAlignment(.trailing)
					targetPicker
				}
				GridRow(alignment: .top) {
					Text("옵션:")
					VStack(alignment: .leading, spacing: 6) {
						Toggle("첫 행을 컬럼 이름으로 사용 (체크 해제 시 엑셀 컬럼명을 사용합니다.)", isOn: $job.header)
						Toggle("컬럼별 데이터 형식 고려", isOn: $job.typed)
							.help("숫자는 INT·DECIMAL, 날짜는 DATE·DATETIME 으로. 끄면 모두 글자(VARCHAR·TEXT). 글자로 저장된 숫자(앞자리 0)는 글자 그대로")
						if job.target == .newTable {
							Toggle("자동 증가 id 컬럼 추가 (기본 키 — iSQL 에서 고치려면 필요)", isOn: $job.addID)
								.disabled(job.names.contains { $0.lowercased() == "id" })
						}
					}
					.toggleStyle(.checkbox)
					.disabled(locked)
				}
			}
			previewBox
			HStack(alignment: .center, spacing: 10) {
				status
				Spacer(minLength: 0)
				if job.finished {
					Button("닫기") { dismiss() }
						.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
				} else {
					if job.target == .newTable && !job.running {
						Button("SQL 보기") { showSQL = true }.disabled(job.columnCount == 0)
					}
					Button(job.running ? "그만두기" : "취소", role: .cancel) {
						if job.running { job.cancel() } else { dismiss() }
					}
					.keyboardShortcut(.cancelAction)
					Button("가져오기") { Task { await job.run() } }
						.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
						.disabled(!job.canRun)
				}
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 640)
		.interactiveDismissDisabled(job.running)
		.sheet(isPresented: $showSQL) { SQLPreview(statements: [job.createSQL + ";"], title: "새 테이블을 이렇게 만듭니다") }
		.onChange(of: job.header) { preview.bump() }
		.onChange(of: job.typed) { preview.bump() }
		.onChange(of: job.sheetIndex) { preview.bump() }
		.onChange(of: job.target) { preview.bump() }
		.onChange(of: job.existingName) { preview.bump() }
		.onChange(of: job.url) { preview.bump() }
		.onChange(of: job.loading) { preview.bump() }
	}

	private var fileRow: some View {
		HStack(spacing: 10) {
			Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path)).resizable().frame(width: 32, height: 32)
			VStack(alignment: .leading, spacing: 2) {
				Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
				Text("\(ByteCountFormatter.string(fromByteCount: job.fileSize, countStyle: .file)) · \(job.dataRows.count.formatted())행 · \(job.columnCount)열")
					.font(.callout).foregroundStyle(.secondary).monospacedDigit()
			}
			Spacer(minLength: 8)
			if job.loading { ProgressView().controlSize(.small) }
			Button("엑셀 파일 선택…") { if let u = Session.pickExcelFile() { job.change(to: u) } }
				.disabled(locked)
		}
	}

	private var targetPicker: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Picker("", selection: $job.target) {
					Text("새 테이블").tag(ExcelImportJob.Target.newTable)
					Text("기존 테이블").tag(ExcelImportJob.Target.existing)
				}
				.pickerStyle(.segmented).labelsHidden().fixedSize()
				if job.target == .newTable {
					TextField("테이블 이름", text: $job.newName).textFieldStyle(.roundedBorder)
				} else {
					PopUp(selection: $job.existingName, options: job.existingTables.map { ($0, $0) })
				}
			}
			.disabled(locked)
			Group {
				if job.target == .newTable && job.nameTaken && !job.finished {
					Label("\(job.schema) 에 이미 있는 이름입니다", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
				} else if job.target == .existing {
					EmptyView()   // 넣을 열 안내는 미리보기 아래 (mappingNote)
				} else {
					Text("데이터베이스 \(job.schema) 안에").foregroundStyle(.secondary)
				}
			}
			.font(.callout)
		}
	}

	/// 미리보기: 제목 = 이름 + (새 테이블) 형식 / (기존) → 넣을 컬럼
	private var previewBox: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("미리보기 (앞 8행)").font(.callout).foregroundStyle(.secondary)
			TableGrid(source: preview)
				.frame(height: 210)
				.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
			mappingNote.font(.callout)
		}
	}

	/// 기존 테이블에 넣을 때: 몇 개 열이 어디로 가는지 (미리보기 제목의 "→ 컬럼" 과 바로 맞춰 보게 표 아래, 사용자 2026-11-18)
	@ViewBuilder private var mappingNote: some View {
		if job.target == .existing {
			let m = job.mapping
			let hit = m.compactMap { $0 }.count
			if hit == 0 {
				Label(job.header ? "첫 행 이름과 맞는 컬럼이 없습니다" : "컬럼이 없습니다", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			} else {
				Text("\(job.schema).\(job.existingName) 에 \(hit)개 열을 넣습니다" + (hit < m.count ? " (나머지 \(m.count - hit)개는 건너뜀)" : "") + (job.header ? " — 이름으로 맞춤" : " — 순서대로"))
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder private var status: some View {
		if job.running {
			VStack(alignment: .leading, spacing: 4) {
				ProgressView(value: Double(job.done), total: Double(max(job.dataRows.count, 1)))
				Text("\(job.done.formatted()) / \(job.dataRows.count.formatted())행")
					.font(.callout).foregroundStyle(.secondary).monospacedDigit()
			}
		} else if let m = job.message {
			Label(m, systemImage: job.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
				.foregroundStyle(job.isError ? Color.red : .green).font(.callout).lineLimit(4).textSelection(.enabled)
		}
	}
}

/// 미리보기 표 (읽기 전용)
@Observable
final class ExcelPreviewSource: GridSource {
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private let job: ExcelImportJob
	private(set) var gridVersion = 0
	@ObservationIgnored private var signature = 0

	init(job: ExcelImportJob) { self.job = job }

	@MainActor func bump() { gridVersion += 1; signature += 1 }

	var gridID: String { "excel-preview-\(signature)" }

	var gridColumns: [GridColumn] {
		MainActor.assumeIsolated {
			let names = job.names, kinds = job.kinds
			let mapping = job.target == .existing ? job.mapping : []
			return names.indices.map { i in
				let detail: String
				if job.target == .existing { detail = i < mapping.count ? (mapping[i].map { "→ \($0)" } ?? "건너뜀") : "" }
				else { detail = i < kinds.count ? ExcelImportJob.sqlType(kinds[i]) : "" }
				let numeric: Bool = i < kinds.count && { switch kinds[i] { case .int, .bigint, .decimal, .double: true; default: false } }()
				return GridColumn(key: String(i), title: names[i], comment: detail, isKey: false, numeric: numeric, long: false)
			}
		}
	}

	var rowCount: Int { MainActor.assumeIsolated { min(job.dataRows.count, 8) } }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		MainActor.assumeIsolated {
			let r = job.dataRows[row]
			return GridCell(text: col < r.count ? ExcelImportJob.text(r[col]) : nil)
		}
	}

	var sortable: Bool { false }
}
