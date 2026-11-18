import SwiftUI

/// 테이블 이름 바꾸기·복제 요청 (오른쪽 클릭 메뉴 → 창이 제목바 시트로)
struct TableNameRequest: Identifiable {
	enum Kind { case rename, duplicate }
	let id = UUID()
	let kind: Kind
	let schema: String
	let table: TableStat
}

/// 테이블 이름 바꾸기 / 복제 시트: 새 이름(같은 DB 에 있으면 경고), 복제면 구조만 / 구조와 데이터, 진행 막대
struct TableNameSheet: View {
	let request: TableNameRequest
	let session: Session
	private var dialect: any SQLDialect { session.dialect }
	@State private var name: String
	@State private var withData = true
	@State private var job: DatabaseCopyJob
	@State private var renaming = false
	@State private var error: String?
	@FocusState private var focused: Bool
	@Environment(\.dismiss) private var dismiss

	init(request: TableNameRequest, session: Session) {
		self.request = request
		self.session = session
		_job = State(initialValue: DatabaseCopyJob(source: request.schema, session: session))
		let existing = Set(session.tables.filter { $0.schema == request.schema }.map { $0.name.lowercased() })
		var n = request.table.name
		if request.kind == .duplicate {
			n += "_copy"
			var i = 2
			while existing.contains(n.lowercased()) { n = request.table.name + "_copy\(i)"; i += 1 }
		}
		_name = State(initialValue: n)
	}

	private var kindName: String { request.table.isView ? "뷰" : "테이블" }
	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	private var exists: Bool {
		session.tables.contains { $0.schema == request.schema && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
			&& !(request.kind == .rename && trimmed.caseInsensitiveCompare(request.table.name) == .orderedSame && trimmed != request.table.name)
	}
	/// 이 테이블 탭에 저장 안 한 변경이 있으면 이름을 바꾸지 않는다 (사라지므로)
	private var unsaved: Bool { request.kind == .rename && session.isUnsaved(table: request.schema + "." + request.table.name) }
	private var busy: Bool { job.running || renaming }
	private var canRun: Bool {
		!trimmed.isEmpty && trimmed != request.table.name && !exists && !unsaved && !busy && !job.finished
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(request.kind == .rename ? "\(request.table.name) 이름 바꾸기" : "\(request.table.name) 복제").font(.headline)
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text(request.kind == .rename ? "새 이름:" : "복제할 \(kindName) 이름:")
					TextField("", text: $name)
						.textFieldStyle(.roundedBorder)
						.focused($focused)
						.disabled(busy || job.finished)
						.onSubmit { if canRun { run() } }
				}
				if exists && !job.finished {
					Label("\(request.schema) 에 이미 있는 이름입니다.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange).font(.callout)
				} else if unsaved {
					Label("이 테이블 탭에 저장 안 한 변경이 있습니다. 저장하거나 되돌린 뒤 바꾸세요.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange).font(.callout)
				} else {
					Text("데이터베이스 \(request.schema) 안에서")
						.foregroundStyle(.secondary).font(.callout)
				}
			}
			if request.kind == .duplicate && !request.table.isView {
				VStack(alignment: .leading, spacing: 6) {
					Picker("", selection: $withData) {
						Text("구조만").tag(false)
						Text("구조와 데이터").tag(true)
					}
					.pickerStyle(.radioGroup)
					.labelsHidden()
					.disabled(busy || job.finished)
					Text("컬럼·인덱스를 그대로 만듭니다 (CREATE TABLE … LIKE). 외래 키·트리거는 옮기지 않습니다. 데이터는 원본을 잠그지 않고 5,000행씩 옮깁니다.")
						.font(.callout).foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
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
					.disabled(renaming)
					Button(request.kind == .rename ? "이름 바꾸기" : "복제", action: run)
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
						.disabled(!canRun)
				}
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 460)
		.interactiveDismissDisabled(busy)
		.onAppear { focused = true }
	}

	@ViewBuilder private var status: some View {
		if job.running {
			VStack(alignment: .leading, spacing: 4) {
				if job.rowsTotal > 0 {
					ProgressView(value: min(1, Double(job.rowsDone) / Double(max(job.rowsTotal, 1))))
					Text("\(job.rowsDone.formatted()) / ~\(job.rowsTotal.formatted())행")
						.font(.callout).foregroundStyle(.secondary).monospacedDigit()
				} else {
					ProgressView().progressViewStyle(.linear)
				}
			}
		} else if renaming {
			ProgressView().controlSize(.small)
		} else if let e = error {
			Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).lineLimit(3).textSelection(.enabled)
		} else if let m = job.message {
			Label(m, systemImage: job.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
				.foregroundStyle(job.isError ? Color.red : .green).font(.callout).lineLimit(3).textSelection(.enabled)
		}
	}

	private func run() {
		guard canRun else { return }
		let new = trimmed
		switch request.kind {
		case .duplicate:
			Task { await job.duplicateTable(request.table.name, isView: request.table.isView, to: new, data: withData) }
		case .rename:
			renaming = true
			error = nil
			let q = dialect.quote(_:)
			let db = q(request.schema)
			Task { @MainActor in
				do {
					_ = try await session.query("RENAME TABLE \(db).\(q(request.table.name)) TO \(db).\(q(new))")
					await session.tableRenamed(schema: request.schema, from: request.table.name, to: new)
					renaming = false
					dismiss()
				} catch {
					renaming = false
					self.error = error.localizedDescription
				}
			}
		}
	}
}
