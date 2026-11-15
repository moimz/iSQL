import SwiftUI

/// 데이터베이스 복제 요청 (사이드바 DB 오른쪽 클릭 → 창이 제목바 시트로 띄운다)
struct DuplicateRequest: Identifiable {
	let id = UUID()
	let schema: String
}

/// 데이터베이스 복제 시트: 새 이름, 구조·데이터, 아래 줄 왼쪽에 진행 막대 (복제 버튼은 오른쪽)
struct DuplicateDatabaseSheet: View {
	let session: Session
	@State private var job: DatabaseCopyJob
	@State private var name: String
	@State private var structure = true
	@State private var data = true
	@Environment(\.dismiss) private var dismiss

	init(request: DuplicateRequest, session: Session) {
		self.session = session
		_job = State(initialValue: DatabaseCopyJob(source: request.schema, session: session))
		_name = State(initialValue: Self.suggestName(request.schema, existing: session.databases))
	}

	/// "원본_copy", 있으면 "원본_copy2" …
	private static func suggestName(_ s: String, existing: [String]) -> String {
		let taken = Set(existing.map { $0.lowercased() })
		var n = s + "_copy", i = 2
		while taken.contains(n.lowercased()) { n = s + "_copy\(i)"; i += 1 }
		return n
	}

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	private var exists: Bool { session.databases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }
	private var canRun: Bool { !trimmed.isEmpty && !exists && !job.running && !job.finished }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("\(job.source) 복제").font(.headline)
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("복제할 데이터베이스 이름:")
					TextField("", text: $name)
						.textFieldStyle(.roundedBorder)
						.disabled(job.running || job.finished)
				}
				if exists && !job.finished {
					Label("이미 있는 데이터베이스입니다. 다른 이름을 쓰세요.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange).font(.callout)
				} else if !job.collation.isEmpty {
					Text("문자셋 \(job.charset) · 콜레이션 \(job.collation) 을 그대로 씁니다")
						.foregroundStyle(.secondary).font(.callout)
				}
			}
			VStack(alignment: .leading, spacing: 8) {
				Toggle("테이블 구조 복제", isOn: $structure)
				Toggle("데이터 복제", isOn: $data)
					.disabled(!structure)
					.padding(.leading, 20)
			}
			.toggleStyle(.checkbox)
			.disabled(job.running || job.finished)
			HStack(alignment: .center, spacing: 10) {
				status
				Spacer(minLength: 0)
				if job.finished {
					Button("닫기") { dismiss() }
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
				} else {
					Button(job.running ? "그만두기" : "취소", role: .cancel) {
						if job.running { job.cancel() } else { dismiss() }
					}
					.keyboardShortcut(.cancelAction)
					Button("복제") {
						Task { await job.run(to: trimmed, structure: structure, data: structure && data) }
					}
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled(!canRun)
				}
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 460)
		.interactiveDismissDisabled(job.running)
		.task { await job.loadSettings() }
	}

	/// "테이블 (1/50 테이블) · 15,000 / ~120,000행"
	private var progressText: String {
		if job.current.isEmpty { return "데이터베이스 만드는 중…" }
		var t = "\(job.current) (\(min(job.done + 1, job.total))/\(job.total) 테이블)"
		if job.rowsTotal > 0 { t += " · \(job.rowsDone.formatted()) / ~\(job.rowsTotal.formatted())행" }
		return t
	}

	/// 복제 버튼 왼쪽: 진행 막대와 "테이블 (1/50 테이블)", 끝나면 결과
	@ViewBuilder private var status: some View {
		if job.running {
			VStack(alignment: .leading, spacing: 4) {
				if job.total > 0 {
					ProgressView(value: job.fraction)
				} else {
					ProgressView().progressViewStyle(.linear)
				}
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
