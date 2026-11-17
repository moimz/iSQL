import Foundation
import AppKit
import Observation

/// 프로시저·함수·트리거·이벤트 (사이드바 DB 아래 묶음, 탭으로 열어 SQL 로 고친다)
enum RoutineKind: String, CaseIterable {
	case procedure, function, trigger, event, view

	/// 사이드바 묶음·새로 만들기에 나오는 것 (뷰는 테이블 목록에 있고 정의 고치기만 탭으로)
	static let routineKinds: [RoutineKind] = [.procedure, .function, .trigger, .event]

	var label: String {
		switch self { case .procedure: "프로시저"; case .function: "함수"; case .trigger: "트리거"; case .event: "이벤트"; case .view: "뷰" }
	}
	var sqlWord: String { rawValue.uppercased() }
	var icon: String {
		switch self { case .procedure: "gearshape.2"; case .function: "function"; case .trigger: "bolt"; case .event: "clock"; case .view: "eye" }
	}
	/// SHOW CREATE 결과에서 정의가 든 컬럼
	var createColumn: String {
		switch self { case .procedure: "Create Procedure"; case .function: "Create Function"; case .trigger: "SQL Original Statement"; case .event: "Create Event"; case .view: "Create View" }
	}

	/// 새로 만들 때 기본 틀
	func template(table: String?) -> String {
		let t = table.map { "`" + $0 + "`" } ?? "`테이블`"
		switch self {
		case .procedure: return "CREATE PROCEDURE `new_procedure`(IN p_id INT)\nBEGIN\n\tSELECT p_id;\nEND"
		case .function: return "CREATE FUNCTION `new_function`(p INT) RETURNS INT\nDETERMINISTIC\nBEGIN\n\tRETURN p;\nEND"
		case .trigger: return "CREATE TRIGGER `new_trigger` BEFORE INSERT ON \(t) FOR EACH ROW\nBEGIN\n\t-- SET NEW.컬럼 = 값;\nEND"
		case .event: return "CREATE EVENT `new_event`\nON SCHEDULE EVERY 1 DAY\nDO\n\tSELECT 1"
		case .view: return "CREATE VIEW `new_view` AS\nSELECT 1"
		}
	}
}

struct RoutineInfo: Identifiable, Hashable {
	let schema: String
	let name: String
	let kind: RoutineKind
	/// 트리거: "BEFORE INSERT · 테이블", 이벤트: "매 1 DAY" 등
	var detail = ""
	/// 이벤트만: 켜짐/꺼짐
	var enabled: Bool?
	var comment = ""

	var id: String { Self.tabID(kind, schema, name) }

	static let prefix = "rt:"
	static let newPrefix = "rtnew:"

	/// 탭 id: "rt:<종류>:<DB>.<이름>"
	static func tabID(_ k: RoutineKind, _ schema: String, _ name: String) -> String { prefix + k.rawValue + ":" + schema + "." + name }

	/// 루틴 탭이면 (종류, DB, 이름). 새로 만드는 탭은 "rtnew:<종류>:<DB>:<임의값>" (이름 nil)
	static func parse(_ tab: String) -> (kind: RoutineKind, schema: String, name: String?)? {
		if tab.hasPrefix(newPrefix) {
			let parts = tab.dropFirst(newPrefix.count).split(separator: ":", maxSplits: 2).map(String.init)
			guard parts.count >= 2, let k = RoutineKind(rawValue: parts[0]) else { return nil }
			return (k, parts[1], nil)
		}
		guard tab.hasPrefix(prefix) else { return nil }
		let rest = tab.dropFirst(prefix.count)
		guard let colon = rest.firstIndex(of: ":"), let k = RoutineKind(rawValue: String(rest[..<colon])) else { return nil }
		let full = rest[rest.index(after: colon)...]
		guard let dot = full.firstIndex(of: ".") else { return nil }
		return (k, String(full[..<dot]), String(full[full.index(after: dot)...]))
	}

	static func isRoutineTab(_ tab: String) -> Bool { tab.hasPrefix(prefix) || tab.hasPrefix(newPrefix) }
}

/// 루틴 탭 하나의 편집 상태: SHOW CREATE 로 읽고, 저장하면 DROP → CREATE (본문을 바꾸는 ALTER 가 없다).
/// CREATE 가 실패하면 원래 정의로 다시 만든다. 따로 된 연결에서 USE <DB> 뒤에 실행한다 (앱 연결의 기본 DB 를 건드리지 않게)
@Observable
final class RoutineEditor {
	let kind: RoutineKind
	let schema: String
	/// 지금 이름 (새로 만드는 중이면 nil)
	private(set) var name: String?
	@ObservationIgnored private weak var session: Session?

	var text = ""
	private(set) var original = ""
	private(set) var loaded = false
	private(set) var saving = false
	private(set) var message: String?
	private(set) var isError = false
	/// 원래 DEFINER 를 그대로 둘지 (끄면 DEFINER 를 빼서 지금 계정으로)
	var keepDefiner = true
	/// 이벤트 스케줄러가 꺼져 있으면 경고
	private(set) var schedulerOff = false

	var isNew: Bool { name == nil }
	var changed: Bool { isNew || text != original }

	init(kind: RoutineKind, schema: String, name: String?, session: Session) {
		self.kind = kind
		self.schema = schema
		self.name = name
		self.session = session
		if name == nil {
			text = kind.template(table: session.tables.first { $0.schema == schema && !$0.isView }?.name)
			loaded = true
		}
	}

	private var q: (String) -> String { TableInspector.ident }

	@MainActor
	func load() async {
		guard let session, let name else { return }
		do {
			let r = try await session.query("SHOW CREATE \(kind.sqlWord) \(q(schema)).\(q(name))").last ?? QueryResult()
			guard let ddl = r.rows.isEmpty ? nil : r.string(0, kind.createColumn) else {
				throw RoutineError.message("정의를 읽지 못했습니다 (권한이 없거나 지워졌습니다)")
			}
			original = ddl
			text = ddl
			loaded = true
			message = nil
			isError = false
		} catch {
			loaded = true
			isError = true
			message = error.localizedDescription
		}
		if kind == .event {
			let v = (try? await session.query("SELECT @@event_scheduler").last)?.rows.first?.first?.string ?? ""
			schedulerOff = v.uppercased() != "ON"
		}
	}

	func revert() { text = original; message = nil; isError = false }

	/// 저장: 새 것이면 CREATE, 아니면 DROP → CREATE (실패하면 원래 것을 다시 만든다). 저장한 뒤의 새 이름
	@MainActor
	func save() async -> String? {
		guard let session, !saving, changed else { return nil }
		saving = true
		message = nil
		isError = false
		defer { saving = false }
		let sql = Self.clean(keepDefiner ? text : Self.stripDefiner(text))
		guard let newName = Self.parseName(sql, kind) else {
			isError = true
			message = "CREATE \(kind.sqlWord) `이름` … 꼴이어야 합니다"
			return nil
		}
		var conn: MySQLConnection?
		do {
			let c = try await session.sideConnection(purpose: kind.label)
			conn = c
			_ = try await c.query("USE \(q(schema))")
			if kind == .view, let old = name, old == newName {
				// 뷰는 이름이 같으면 CREATE OR REPLACE 로 (지우지 않아 권한이 그대로, 실패해도 원래 것이 남는다)
				_ = try await c.query(Self.orReplace(sql))
			} else if let old = name {
				_ = try await c.query("DROP \(kind.sqlWord) \(q(schema)).\(q(old))")
				do {
					_ = try await c.query(sql)
				} catch {
					// 원래 정의로 되돌린다 (DEFINER 를 그대로 두면 권한 문제로 실패할 수 있어 한 번 더 빼고 시도)
					if (try? await c.query(original)) == nil { _ = try? await c.query(Self.stripDefiner(original)) }
					throw error
				}
			} else {
				_ = try await c.query(sql)
			}
			c.close()
			conn = nil
			name = newName
			if kind == .view { try? await session.loadSchema() } else { await session.loadRoutines() }
			await load()
			message = "저장했습니다"
			return newName
		} catch {
			conn?.close()
			isError = true
			message = error.localizedDescription
			return nil
		}
	}

	/// 이벤트 켜기·끄기
	@MainActor
	func setEnabled(_ on: Bool) async {
		guard let session, let name, kind == .event else { return }
		do {
			_ = try await session.query("ALTER EVENT \(q(schema)).\(q(name)) \(on ? "ENABLE" : "DISABLE")")
			await session.loadRoutines()
			await load()
		} catch {
			isError = true
			message = error.localizedDescription
		}
	}

	// MARK: 글 다루기

	/// 앞뒤 공백, 끝의 ; 와 DELIMITER 줄을 뗀다 (서버에 보낼 때는 한 문장이라 DELIMITER 가 필요 없다)
	static func clean(_ s: String) -> String {
		var lines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DELIMITER ") }
		while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
		var t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		for end in ["$$", "//", ";;", ";"] where t.hasSuffix(end) { t = String(t.dropLast(end.count)).trimmingCharacters(in: .whitespacesAndNewlines); break }
		return t
	}

	/// "CREATE … VIEW" → "CREATE OR REPLACE … VIEW"
	static func orReplace(_ s: String) -> String {
		guard !s.uppercased().contains("OR REPLACE"),
		      let r = s.range(of: #"^\s*CREATE\b"#, options: [.regularExpression, .caseInsensitive]) else { return s }
		return s.replacingCharacters(in: r, with: "CREATE OR REPLACE")
	}

	static func stripDefiner(_ s: String) -> String {
		s.replacingOccurrences(of: #"DEFINER\s*=\s*(`[^`]*`|'[^']*'|[^@\s]+)@(`[^`]*`|'[^']*'|\S+)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
	}

	/// CREATE … PROCEDURE `이름` 에서 이름 (DB 가 붙어 있어도)
	static func parseName(_ s: String, _ k: RoutineKind) -> String? {
		let pattern = #"\b"# + k.sqlWord + #"\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(?:`[^`]+`|\w+)\s*\.\s*)?(`[^`]+`|\w+)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
		var n = String(s[r])
		if n.hasPrefix("`") { n = String(n.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`") }
		return n
	}

	enum RoutineError: LocalizedError {
		case message(String)
		var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
	}
}
