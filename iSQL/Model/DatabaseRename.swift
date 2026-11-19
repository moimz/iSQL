import Foundation
import Observation

/// 데이터베이스 이름 바꾸기 (사이드바 DB 오른쪽 클릭 → 데이터베이스 이름 바꾸기…).
/// MySQL 에는 DB 이름을 바로 바꾸는 명령이 없다: 같은 문자셋·콜레이션으로 새 DB 를 만들고
/// `RENAME TABLE 옛.t TO 새.t, …` 한 문장으로 테이블을 옮긴다 (데이터를 복사하지 않고 소속·파일 위치만 바꿔 크기와 상관없이 빠르다, 하나라도 실패하면 모두 되돌아간다).
/// 뷰는 다른 DB 로 RENAME 할 수 없어 정의를 읽어 새 DB 에 다시 만들고 옛 것을 지운다.
/// 트리거가 있으면 MySQL 이 옮기기를 거부하므로 시작하지 않는다. 프로시저·함수·이벤트는 옮기지 않고 옛 DB 에 남긴다 (사용자 2026-11-17)
@Observable
final class DatabaseRenameJob {
	let source: String
	@ObservationIgnored private weak var session: Session?
	/// SQL 문법 (세션이 없어졌으면 MySQL — 그때는 어차피 실행하지 않는다)
	private var dialect: any SQLDialect { session?.dialect ?? SQLKind.mysql.dialect }

	private(set) var loaded = false
	private(set) var charset = ""
	private(set) var collation = ""
	private(set) var tables: [String] = []
	private(set) var views: [String] = []
	private(set) var triggers = 0
	/// 프로시저·함수·이벤트 수 (옮기지 않는다)
	private(set) var routines = 0
	private(set) var events = 0

	private(set) var running = false
	private(set) var finished = false
	private(set) var step = ""
	private(set) var message: String?
	private(set) var isError = false

	init(source: String, session: Session) {
		self.source = source
		self.session = session
	}


	@MainActor
	func load() async {
		guard let session else { return }
		let set = (try? await session.meta.schemaDefaults(session.query, schema: source)) ?? nil
		charset = set?.charset ?? ""
		collation = set?.collation ?? ""
		let c = await session.meta.contents(session.query, schema: source)
		tables = c.tables
		views = c.views
		triggers = c.triggers
		routines = c.routines
		events = c.events
		loaded = true
	}

	@MainActor
	func run(to target: String) async {
		guard let session, !running, triggers == 0 else { return }
		running = true
		message = nil
		isError = false
		defer { running = false }
		let q = dialect.quote(_:)
		let src = q(source), dst = q(target)
		do {
			// 뷰 정의는 테이블을 옮기기 전에 읽는다: 옮긴 뒤에는 옛 뷰가 없는 테이블을 가리켜 SHOW CREATE VIEW 가 거부된다(오류 1356)
			var ddls: [String: String] = [:]
			for v in views {
				step = "뷰 \(v) 읽는 중…"
				if let d = try await session.meta.createStatement(session.query, .view, schema: source, name: v) { ddls[v] = dialect.rewriteViewDefinition(d, name: v, from: source, to: target) }
			}
			step = "데이터베이스 만드는 중…"
			_ = try await session.query(dialect.createDatabase(target, charset: charset, collation: collation))
			if !tables.isEmpty {
				step = "테이블 \(tables.count)개 옮기는 중…"
				let pairs = tables.map { (from: "\(src).\(q($0))", to: "\(dst).\(q($0))") }
				do {
					_ = try await session.query(dialect.renameTables(pairs))
				} catch {
					// 한 문장이라 테이블은 모두 제자리 → 만든 빈 DB 만 지운다
					_ = try? await session.query(dialect.dropDatabase(target))
					throw error
				}
			}
			// 뷰: 다른 뷰를 쓰는 뷰가 있어 순서를 모른다 → 되는 것부터 만들고, 더 만들어지지 않을 때까지 되풀이
			var left = views
			var lastError: Error?
			while !left.isEmpty {
				var made: [String] = []
				for v in left {
					guard let ddl = ddls[v] else { continue }
					step = "뷰 \(v) 만드는 중…"
					do { _ = try await session.query(ddl); made.append(v) } catch { lastError = error }
				}
				if made.isEmpty { break }
				left.removeAll { made.contains($0) }
			}
			for v in views where !left.contains(v) { _ = try? await session.query(dialect.drop(["\(src).\(q(v))"], views: true)) }
			// 옛 DB 가 비었으면 지운다 (프로시저·이벤트가 있으면 남긴다)
			let remain = ((try? await session.meta.tableCount(session.query, schema: source)) ?? nil) ?? 1
			var dropped = false
			if remain == 0 && routines == 0 && events == 0 {
				step = "옛 데이터베이스 삭제하는 중…"
				_ = try await session.query(dialect.dropDatabase(source))
				dropped = true
			}
			await session.databaseRenamed(from: source, to: target, droppedOld: dropped)
			if !left.isEmpty {
				isError = true
				message = "테이블은 옮겼지만 뷰 \(left.count)개(\(left.joined(separator: ", ")))를 만들지 못해 \(source) 에 남겼습니다: \(lastError?.localizedDescription ?? "")"
			} else {
				var parts = ["이름을 \(target)(으)로 바꿨습니다 (테이블 \(tables.count)개" + (views.isEmpty ? "" : ", 뷰 \(views.count)개") + ")"]
				if !dropped { parts.append("프로시저·함수·이벤트가 있어 \(source) 는 남겼습니다") }
				message = parts.joined(separator: ". ")
			}
		} catch {
			isError = true
			message = error.localizedDescription
		}
		step = ""
		finished = !isError || message?.hasPrefix("테이블은 옮겼지만") == true
	}
}
