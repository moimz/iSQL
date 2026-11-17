import SwiftUI

/// 쿼리 결과·지금 보는 데이터로 뷰 만들기: 이름·DB 를 고르면 CREATE VIEW db.이름 AS (SELECT).
/// "나만 보기" 면 서버에 만들지 않고 iCloud 에 이름 붙인 SELECT 로 둔다 (사이드바에 자물쇠 눈, 내 맥끼리 같이 씀)
struct CreateViewSheet: View {
	let sql: String
	let session: Session
	var title = "쿼리 결과로 뷰 만들기"
	@State private var name = ""
	@State private var schema: String
	@AppStorage("createViewPrivate") private var privateOnly = false
	@State private var running = false
	@State private var error: String?
	@FocusState private var focused: Bool
	@Environment(\.dismiss) private var dismiss

	init(sql: String, session: Session, schema: String? = nil, title: String = "쿼리 결과로 뷰 만들기") {
		self.sql = sql
		self.session = session
		self.title = title
		let dbs = session.databases.filter { !Session.systemSchemas.contains($0) }
		let want = schema ?? session.currentDB
		_schema = State(initialValue: dbs.contains(want) ? want : (dbs.first ?? want))
	}

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
	/// 끝의 ; 와 공백은 뺀다 (CREATE VIEW … AS 뒤에 붙인다)
	private var body_: String {
		var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
		while s.hasSuffix(";") { s.removeLast(); s = s.trimmingCharacters(in: .whitespacesAndNewlines) }
		return s
	}
	private var exists: Bool {
		privateOnly
			? session.privateViews.contains { $0.schema == schema && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
			: session.tables.contains { $0.schema == schema && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
	}
	private var statement: String {
		let q = TableInspector.ident
		return "CREATE VIEW \(q(schema)).\(q(trimmed)) AS\n\(body_)"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(title).font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				GridRow {
					Text("뷰 이름:").gridColumnAlignment(.trailing)
					TextField("", text: $name).textFieldStyle(.roundedBorder).focused($focused)
						.onSubmit { if canRun { run() } }
				}
				GridRow {
					Text("데이터베이스:")
					HStack(spacing: 12) {
						PopUp(selection: $schema, options: session.databases.filter { !Session.systemSchemas.contains($0) }.map { ($0, $0) })
							.frame(width: 240)
							.disabled(privateOnly)
						Toggle("나만 보기", isOn: $privateOnly)
							.toggleStyle(.checkbox)
							.help("서버에 뷰를 만들지 않고 이 SELECT 에 이름을 붙여 iCloud 에 둡니다. 내 맥끼리만 보이고 다른 사람·다른 프로그램에는 안 보입니다")
					}
				}
			}
			.disabled(running)
			if exists {
				Label("\(schema) 에 이미 있는 이름입니다.", systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange).font(.callout)
			}
			if privateOnly {
				Label("서버에는 만들지 않습니다. \(schema) 아래에 자물쇠가 붙은 뷰로 보이고, iCloud 로 내 다른 맥에도 보입니다.", systemImage: "lock.fill")
					.font(.callout).foregroundStyle(.secondary)
			}
			Text(privateOnly ? body_ : statement)
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
		if privateOnly {
			let v = session.addPrivateView(name: trimmed, schema: db, sql: body_)
			session.openPrivateView(v)
			running = false
			dismiss()
			return
		}
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
