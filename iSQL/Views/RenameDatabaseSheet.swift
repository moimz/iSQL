import SwiftUI

/// 데이터베이스 이름 바꾸기 요청 (사이드바 DB 오른쪽 클릭 → 창이 제목바 시트로)
struct RenameDatabaseRequest: Identifiable {
	let id = UUID()
	let schema: String
}

/// 데이터베이스 이름 바꾸기 시트: 새 이름, 옮길 것 개수와 주의, 진행
struct RenameDatabaseSheet: View {
	let session: Session
	@State private var job: DatabaseRenameJob
	@State private var name: String
	@Environment(\.dismiss) private var dismiss

	init(request: RenameDatabaseRequest, session: Session) {
		self.session = session
		_job = State(initialValue: DatabaseRenameJob(source: request.schema, session: session))
		_name = State(initialValue: request.schema)
	}

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	private var exists: Bool { session.databases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }
	private var canRun: Bool { job.loaded && job.triggers == 0 && !trimmed.isEmpty && !exists && !job.running && !job.finished }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(job.source) 이름 바꾸기").font(.headline)
			HStack {
				Text("새 이름:")
				TextField("", text: $name)
					.textFieldStyle(.roundedBorder)
					.disabled(job.running || job.finished)
			}
			if exists && trimmed != job.source && !job.finished {
				Label("이미 있는 데이터베이스입니다. 다른 이름을 쓰세요.", systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange).font(.callout)
			}
			if !job.loaded {
				ProgressView().controlSize(.small)
			} else if !job.finished {
				info
			}
			HStack(spacing: 10) {
				status
				Spacer(minLength: 0)
				if job.finished {
					Button("닫기") { dismiss() }
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
				} else {
					Button("취소", role: .cancel) { dismiss() }
						.keyboardShortcut(.cancelAction)
						.disabled(job.running)
					Button("이름 바꾸기") { Task { await job.run(to: trimmed) } }
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
						.disabled(!canRun)
				}
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 480)
		.interactiveDismissDisabled(job.running)
		.task { await job.load() }
	}

	/// 옮길 것과 주의
	@ViewBuilder private var info: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("옮길 것: 테이블 \(job.tables.count)개" + (job.views.isEmpty ? "" : " · 뷰 \(job.views.count)개") + " · 문자셋 \(job.charset) · \(job.collation)")
				.foregroundStyle(.secondary)
			if job.triggers > 0 {
				Label("트리거 \(job.triggers)개가 있어 이름을 바꿀 수 없습니다 (MySQL 이 트리거가 있는 테이블을 다른 데이터베이스로 옮기지 않습니다)", systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red)
			} else {
				Text("데이터를 복사하지 않고 옮겨서 크기와 상관없이 빠릅니다. 다만 옮기는 동안 쓰고 있는 테이블이 있으면 그 쿼리가 끝날 때까지 기다리고, 그동안 새 쿼리도 잠깐 멈춥니다. 운영 서버는 한가할 때 하세요.")
					.foregroundStyle(.secondary)
				if job.routines + job.events > 0 {
					Label("프로시저·함수 \(job.routines)개, 이벤트 \(job.events)개는 옮기지 않고 \(job.source) 에 남깁니다 (옛 데이터베이스도 삭제하지 않음)", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
				}
				Text("이 데이터베이스 이름으로 준 사용자 권한(GRANT)은 따라오지 않습니다.")
					.foregroundStyle(.secondary)
			}
		}
		.font(.callout)
		.fixedSize(horizontal: false, vertical: true)
	}

	@ViewBuilder private var status: some View {
		if job.running {
			HStack(spacing: 6) {
				ProgressView().controlSize(.small)
				Text(job.step).font(.callout).foregroundStyle(.secondary).lineLimit(1)
			}
		} else if let m = job.message {
			Label(m, systemImage: job.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
				.foregroundStyle(job.isError ? Color.red : .green)
				.font(.callout)
				.lineLimit(4)
				.textSelection(.enabled)
		}
	}
}
