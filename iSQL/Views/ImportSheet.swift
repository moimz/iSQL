import SwiftUI
import AppKit

/// SQL 파일 가져오기 시트: 파일, 넣을 데이터베이스, 외래 키 검사, 아래 줄 왼쪽에 진행 막대 (가져오기 버튼은 오른쪽).
/// 오류가 나면 그 문장에서 멈추고 줄 번호·오류·문장을 보여 준다 → 그만두기 / 건너뛰고 계속
struct ImportSheet: View {
	let session: Session
	let job: SQLImportJob
	/// "" = 파일에 적힌 대로 (USE 하지 않음)
	@State private var schema: String
	@State private var disableForeignKeys = true
	@Environment(\.dismiss) private var dismiss

	init(request: ImportRequest, session: Session) {
		self.session = session
		job = request.job
		_schema = State(initialValue: request.schema ?? "")
	}

	private var locked: Bool { job.running || job.finished || job.failure != nil }

	private var schemaOptions: [(title: String, value: String?)] {
		let user = session.databases.filter { !session.systemSchemas.contains($0.lowercased()) }
		return [("파일에 적힌 대로 (USE 안 함)", ""), ("", nil)] + user.map { ($0, $0) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("SQL 파일 가져오기").font(.headline)
			// 파일
			HStack(spacing: 10) {
				Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
					.resizable().frame(width: 32, height: 32)
				VStack(alignment: .leading, spacing: 2) {
					Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
					Text(ByteCountFormatter.string(fromByteCount: job.fileSize, countStyle: .file))
						.font(.callout).foregroundStyle(.secondary).monospacedDigit()
				}
				Spacer(minLength: 8)
				Button("다른 파일…") {
					if let u = Session.pickSQLFile() { job.change(to: u) }
				}
				.disabled(locked)
			}
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				GridRow {
					Text("넣을 데이터베이스:").gridColumnAlignment(.trailing)
					PopUp(selection: $schema, options: schemaOptions)
						.disabled(locked)
				}
				GridRow {
					Color.clear.frame(width: 1, height: 1)
					VStack(alignment: .leading, spacing: 4) {
						if session.capabilities.foreignKeyChecksToggle {
							Toggle("외래 키 검사 끄기 (FOREIGN_KEY_CHECKS = 0)", isOn: $disableForeignKeys)
								.toggleStyle(.checkbox)
								.disabled(locked)
						}
						Text("가져오기 전용 연결로 실행해서 파일의 USE·SET 이 앱의 다른 작업에 남지 않습니다. 오류가 나면 그 문장에서 멈춥니다.")
							.font(.callout).foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			if let f = job.failure { failureBox(f) }
			HStack(alignment: .center, spacing: 10) {
				status
				Spacer(minLength: 0)
				buttons
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 520)
		.interactiveDismissDisabled(job.running || job.failure != nil)
	}

	/// 멈춘 문장: 줄 번호와 오류, 문장 앞부분
	private func failureBox(_ f: SQLImportJob.Failure) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Label("\(f.line.formatted())번째 줄 문장에서 멈췄습니다", systemImage: "xmark.octagon.fill")
				.foregroundStyle(.red).font(.callout.weight(.semibold))
			Text(f.message).font(.callout).textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			// 문장 앞부분 (ScrollView 는 시트 안에서 높이 0 으로 접혀 안 보였다)
			Text(f.preview)
				.font(.callout.monospaced()).foregroundStyle(.secondary)
				.lineLimit(4).truncationMode(.tail)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(10)
		.background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
	}

	@ViewBuilder private var buttons: some View {
		if job.finished {
			Button("닫기") { dismiss() }
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
		} else if job.failure != nil {
			Button("그만두기", role: .cancel) { job.cancel() }
				.keyboardShortcut(.cancelAction)
			Button("건너뛰고 계속") { Task { await job.skipAndContinue() } }
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
		} else {
			Button(job.running ? "그만두기" : "취소", role: .cancel) {
				if job.running { job.cancel() } else { dismiss() }
			}
			.keyboardShortcut(.cancelAction)
			Button("가져오기") {
				Task { await job.start(schema: schema.isEmpty ? nil : schema, disableForeignKeys: disableForeignKeys && session.capabilities.foreignKeyChecksToggle) }
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.defaultAction)
			.disabled(job.running)
		}
	}

	/// "12.3 MB / 45.6 MB · 문장 1,234개 · 5,678번째 줄"
	private var progressText: String {
		let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
		var t = "\(f(job.bytesDone)) / \(f(job.fileSize)) · 문장 \(job.statements.formatted())개"
		if job.line > 0 { t += " · \(job.line.formatted())번째 줄" }
		return t
	}

	@ViewBuilder private var status: some View {
		if job.running || job.failure != nil {
			VStack(alignment: .leading, spacing: 4) {
				ProgressView(value: job.fraction)
				Text(progressText)
					.font(.callout).foregroundStyle(.secondary).monospacedDigit()
					.lineLimit(1).truncationMode(.middle)
			}
		} else if let m = job.message {
			Label(m, systemImage: job.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
				.foregroundStyle(job.isError ? Color.red : .green)
				.font(.callout)
				.lineLimit(3)
				.textSelection(.enabled)
		}
	}
}
