import SwiftUI

/// 쿼리 결과로 뷰 만들기: 이름·DB 를 고르면 CREATE VIEW db.이름 AS (실행한 SELECT)
struct CreateViewSheet: View {
	let sql: String
	let session: Session
	@State private var name = ""
	@State private var schema: String
	@State private var running = false
	@State private var error: String?
	@FocusState private var focused: Bool
	@Environment(\.dismiss) private var dismiss

	init(sql: String, session: Session) {
		self.sql = sql
		self.session = session
		let dbs = session.databases.filter { !Session.systemSchemas.contains($0) }
		_schema = State(initialValue: dbs.contains(session.currentDB) ? session.currentDB : (dbs.first ?? session.currentDB))
	}

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	/// 끝의 ; 와 공백은 뺀다 (CREATE VIEW … AS 뒤에 붙인다)
	private var body_: String {
		var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
		while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespacesAndNewlines) }
		return s
	}
	private var exists: Bool {
		session.tables.contains { $0.schema == schema && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
	}
	private var statement: String {
		let q = TableInspector.ident
		return "CREATE VIEW \(q(schema)).\(q(trimmed)) AS\n\(body_)"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("쿼리 결과로 뷰 만들기").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				GridRow {
					Text("뷰 이름:").gridColumnAlignment(.trailing)
					TextField("", text: $name).textFieldStyle(.roundedBorder).focused($focused)
						.onSubmit { if canRun { run() } }
				}
				GridRow {
					Text("데이터베이스:")
					PopUp(selection: $schema, options: session.databases.filter { !Session.systemSchemas.contains($0) }.map { ($0, $0) })
						.frame(width: 240)
				}
			}
			.disabled(running)
			if exists {
				Label("\(schema) 에 이미 있는 이름입니다.", systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange).font(.callout)
			}
			Text(statement)
				.font(.callout.monospaced()).foregroundStyle(.secondary)
				.lineLimit(8).truncationMode(.tail)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(8)
				.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
			HStack(spacing: 10) {
				if running { ProgressView().controlSize(.small) }
				if let error {
					Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
						.lineLimit(3).textSelection(.enabled)
				}
				Spacer(minLength: 0)
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
				Button("만들기", action: run).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canRun)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 520)
		.onAppear { focused = true }
	}

	private var canRun: Bool { !trimmed.isEmpty && !schema.isEmpty && !exists && !running }

	private func run() {
		guard canRun else { return }
		running = true
		error = nil
		let stmt = statement, db = schema
		Task { @MainActor in
			do {
				// 쿼리 패널과 같은 연결: 쿼리 안의 DB 를 안 붙인 테이블은 지금 기본 DB 로 풀린다 (결과와 같은 테이블)
				_ = try await session.query(stmt)
				await session.dataImported(schema: db)
				running = false
				dismiss()
			} catch {
				running = false
				self.error = error.localizedDescription
			}
		}
	}
}
