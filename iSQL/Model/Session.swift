import Foundation
import AppKit
import UniformTypeIdentifiers
import Observation

/// 테이블 하나 (모든 DB 의 테이블을 한 목록으로 보여 주려고 DB 이름을 같이 가진다)
/// 테이블 삭제·비우기 요청
struct TableActionRequest: Identifiable {
	enum Kind { case drop, truncate, dropDatabase }
	let id = UUID()
	let kind: Kind
	let schema: String
	let tables: [TableStat]

	/// 확인 창의 빨간 버튼
	var confirmLabel: String {
		switch kind {
		case .drop: "삭제"
		case .truncate: "비우기"
		case .dropDatabase: "데이터베이스 삭제"
		}
	}

	var title: String {
		if kind == .dropDatabase { return "데이터베이스 \(schema) 을(를) 삭제할까요?" }
		let verb = kind == .drop ? "삭제할까요?" : "비울까요?"
		if tables.count == 1 { return "\(tables[0].isView ? "뷰" : "테이블") \(tables[0].name) 을(를) \(verb)" }
		return "\(tables.count)개를 \(verb)"
	}

	var message: String {
		if kind == .dropDatabase {
			return "테이블·뷰 \(tables.count)개와 모든 데이터가 함께 지워지며 되돌릴 수 없습니다."
		}
		let names = tables.prefix(10).map(\.name).joined(separator: ", ") + (tables.count > 10 ? " 외 \(tables.count - 10)개" : "")
		let what = kind == .drop ? "데이터와 구조가 모두 지워지며" : "구조는 남고 모든 행이 지워지며(AUTO_INCREMENT 도 처음으로)"
		return "\(schema): \(names)\n\(what) 되돌릴 수 없습니다."
	}
}

struct TableInfo: Identifiable, Hashable {
	var schema: String
	var name: String
	var isView: Bool
	var comment: String
	var rows: Int64?
	/// 저장 엔진. InnoDB 의 TABLE_ROWS 는 어림값, MyISAM 은 정확하다
	var engine = ""
	var rowsExact: Bool { engine.uppercased() == "MYISAM" || engine.uppercased() == "ARIA" }
	var id: String { schema + "." + name }
	/// SQL 에 쓰는 이름
	var quoted: String { "`\(schema.replacingOccurrences(of: "`", with: "``"))`.`\(name.replacingOccurrences(of: "`", with: "``"))`" }
}

struct ColumnInfo: Identifiable, Hashable {
	var name: String
	var type: String
	var nullable: Bool
	var key: String
	var defaultValue: String?
	var extra: String
	var comment: String
	var id: String { name }
}

/// 창 하나가 붙어 있는 서버 접속 (터널 + MySQL 연결 + 테이블 목록)
@Observable
final class Session {
	enum State: Equatable {
		case idle
		case connecting(String)
		case connected
		case failed(String)
	}

	private(set) var server: Server?
	private(set) var state: State = .idle
	private(set) var serverVersion = ""
	/// 시스템 DB 를 뺀 DB 이름 (테이블이 없는 DB 도 있다)
	private(set) var databases: [String] = []
	private(set) var tables: [TableInfo] = []
	/// 테이블 id → 컬럼
	private(set) var columns: [String: [ColumnInfo]] = [:]
	private(set) var loadingSchema = false
	/// 연 탭의 데이터 (탭 id → 데이터, 다른 탭으로 옮겨도 저장 안 한 변경이 남게).
	/// 같은 테이블을 두 탭에 열면 탭마다 따로(행·필터·쪽·수정) 가진다.
	/// 화면을 그리는 중에 채워지므로 관찰하지 않는다. 변경 여부는 각 TableData 가 관찰된다
	@ObservationIgnored private(set) var openData: [String: TableData] = [:]

	// MARK: 탭 id
	// 탭 id = 테이블 id ("db.table"), 같은 테이블의 두 번째 탭부터 "db.table␟2" (DB 개요 탭은 "db:<스키마>", 사본 없음)

	static let copySeparator: Character = "\u{1F}"

	/// 탭 id 에서 테이블 id (사본 번호를 뗀다)
	static func tableID(ofTab id: String) -> String {
		id.firstIndex(of: copySeparator).map { String(id[..<$0]) } ?? id
	}

	/// 이 테이블의 새 탭 id (왼쪽·오른쪽 어디에도 안 쓰인 것)
	private func newTabID(for tableID: String) -> String {
		let used = Set(tabs + parked)
		if !used.contains(tableID) { return tableID }
		var n = 2
		while used.contains(tableID + String(Self.copySeparator) + String(n)) { n += 1 }
		return tableID + String(Self.copySeparator) + String(n)
	}

	/// 이 테이블을 연 탭 중 저장 안 한 변경이 있는 것이 있는지 (사이드바 주황 점)
	func isUnsaved(table id: String) -> Bool {
		unsavedTables.contains { Self.tableID(ofTab: $0) == id }
	}

	/// 서버마다 하나인 쿼리 패널 (접속하면 만든다, 입력 내용은 서버별로 남는다)
	private(set) var queryPanel: QueryPanel?
	/// 지금 연결의 기본 DB (USE 로 바뀐다)
	var currentDB = ""

	/// 쿼리 패널에서 바꾼 테이블이 탭으로 열려 있으면 "다시 읽기 필요" 표시
	func markStale(_ names: [String], defaultDB: String) {
		for n in names {
			let id = n.contains(".") ? n : (defaultDB.isEmpty ? "" : defaultDB + "." + n)
			for (tab, d) in openData {
				let tid = Self.tableID(ofTab: tab)
				guard tid == id || (!n.contains(".") && tid.hasSuffix("." + n) && defaultDB.isEmpty) else { continue }
				d.stale = true
			}
		}
	}

	private var tunnel: SSHTunnel?
	private var conn: MySQLConnection?
	/// MCP 가 따로 붙을 곳: SSH 면 이 터널의 로컬 포트, 아니면 서버 주소. 비밀번호는 메모리에만
	@ObservationIgnored private var sideEndpoint: (host: String, port: Int)?
	@ObservationIgnored private var sidePassword: String?

	/// 같은 서버에 연결을 하나 더 연다 (MCP 용: USE 를 해도 이 창의 쿼리 패널 기본 DB 가 바뀌지 않게). 터널은 같이 쓴다
	func sideConnection() async throws -> MySQLConnection {
		guard let server, let e = sideEndpoint else { throw MySQLError.closed }
		return try await MySQLConnection.connect(.init(host: e.host, port: e.port, user: server.user,
		                                               password: sidePassword ?? "", database: server.database))
	}

	static let systemSchemas: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

	var isConnected: Bool { state == .connected }

	// MARK: - 접속

	@MainActor
	/// 비밀번호는 부르는 쪽이 준다 (저장한 서버는 키체인에서, 퀵 커넥트는 입력칸에서)
	func connect(_ server: Server, mysqlPassword: String?, sshSecret: String?) async {
		disconnect()
		self.server = server
		do {
			let (t, c) = try await Self.open(server, mysqlPassword: mysqlPassword, sshSecret: sshSecret) { [weak self] step in
				self?.state = .connecting(step)
			}
			tunnel = t
			conn = c
			sideEndpoint = t.map { ("127.0.0.1", Int($0.localPort)) } ?? (server.host, server.port)
			sidePassword = mysqlPassword
			serverVersion = c.serverVersion
			state = .connecting("테이블 목록 읽는 중…")
			try await loadSchema()
			currentDB = server.database
			if queryPanel == nil { queryPanel = QueryPanel(session: self, serverID: server.id) }
			state = .connected
			restoreTabs()
		} catch {
			disconnect()
			self.server = server
			state = .failed(error.localizedDescription)
		}
	}

	func disconnect() {
		conn?.close()
		conn = nil
		tunnel?.close()
		tunnel = nil
		sideEndpoint = nil
		sidePassword = nil
		server = nil
		state = .idle
		databases = []
		tables = []
		columns = [:]
		openData = [:]
		overviews = [:]
		unsavedTables = []
		holdMemory = true
		tabs = []
		parked = []
		activeTab = nil
		expanded = []
		holdMemory = false
	}

	/// 그 탭의 데이터 (테이블 탭이 아니면 nil)
	func data(tab id: String) -> TableData? {
		if let d = openData[id] { return d }
		guard let t = table(id) else { return nil }
		let d = TableData(table: t, tab: id, session: self)
		openData[id] = d
		return d
	}

	/// 저장 안 한 변경이 있는 테이블 id
	private(set) var unsavedTables: Set<String> = []

	/// 열린 탭 (테이블 id 순서대로)과 지금 탭. 왼쪽 탭바
	private(set) var tabs: [String] = []
	var activeTab: String? { didSet { rememberTabs() } }
	/// 오른쪽 분할(임시 영역)에 옮겨 둔 이 서버의 탭. 순서·보이는 탭은 창(WindowModel)이 정한다.
	/// 데이터(openData)는 여기 그대로 두고, 다시 켜면 왼쪽 탭으로 되살린다 (TabMemory 에 같이 적는다)
	private(set) var parked: [String] = []
	/// 왼쪽 탭을 열거나 고를 때마다 늘어난다 → 창이 왼쪽 탭에 초점을 준다
	private(set) var leftFocusTick = 0
	/// 오른쪽에 있는 탭을 사이드바에서 다시 열면: 그 탭에 초점 (창이 넣어 준다)
	@ObservationIgnored var focusParked: ((String) -> Void)?
	/// 오른쪽에 있는 이 서버 탭을 닫아 달라 (지운 테이블, 창이 넣어 준다)
	@ObservationIgnored var closeParkedTab: ((String) -> Void)?
	/// 사이드바에서 펼친 DB (처음엔 모두 접힘)
	var expanded: Set<String> = [] { didSet { rememberTabs() } }
	/// 끊을 때 비우는 동안은 기억하지 않는다 (다음 접속에 복원해야 하니까)
	@ObservationIgnored private var holdMemory = false

	/// 서버별로 열린 탭·지금 탭·펼친 DB 를 기억한다 (이 맥에만)
	private func rememberTabs() {
		guard !holdMemory, let id = server?.id, state == .connected else { return }
		TabMemory.save(server: id, tabs: tabs + parked, active: activeTab, expanded: expanded)
	}

	/// 접속 뒤: 지난번 탭을 되살린다 (지금 없는 테이블은 뺀다)
	private func restoreTabs() {
		guard let id = server?.id, let m = TabMemory.load(server: id) else { return }
		holdMemory = true
		let existing = Set(tables.map(\.id)).union(databases.map(Self.databaseTabID))
		// 오른쪽에 있던 사본까지 왼쪽으로 되살리므로, 같은 테이블은 하나만 (사용자 결정)
		var seen = Set<String>()
		tabs = m.tabs.filter { tab in
			let tid = Self.tableID(ofTab: tab)
			return existing.contains(tid) && seen.insert(tid).inserted
		}
		activeTab = m.active.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
		expanded = m.expanded.intersection(databases)
		holdMemory = false
	}

	// MARK: 내보내기

	/// 내보내기 요청 (창이 제목바 시트로 띄운다)
	var exportRequest: ExportRequest?

	func requestExport(_ target: ExportTarget) { exportRequest = ExportRequest(target: target) }

	/// 데이터베이스 복제 요청 (창이 제목바 시트로 띄운다)
	var duplicateRequest: DuplicateRequest?

	/// 테이블 이름 바꾸기·복제 요청 (창이 제목바 시트로 띄운다)
	var tableNameRequest: TableNameRequest?

	/// 이름을 바꾼 뒤: 목록을 다시 읽고, 열린 탭(왼쪽)은 새 이름으로 옮겨 다시 읽는다. 오른쪽 분할 탭은 닫는다
	@MainActor
	func tableRenamed(schema: String, from old: String, to new: String) async {
		let oldID = schema + "." + old, newID = schema + "." + new
		try? await loadSchema()
		for i in tabs.indices where Self.tableID(ofTab: tabs[i]) == oldID {
			let t = tabs[i]
			let moved = newID + t.dropFirst(oldID.count)
			openData[t] = nil
			setUnsaved(t, false)
			tabs[i] = String(moved)
			if activeTab == t { activeTab = String(moved) }
		}
		for t in parked where Self.tableID(ofTab: t) == oldID { closeParkedTab?(t) }
		if let o = overviews[schema] { Task { await o.load() } }
		rememberTabs()
	}

	/// SQL 파일 가져오기 요청 (창이 제목바 시트로 띄운다)
	var importRequest: ImportRequest?

	/// SQL 파일 가져오기: 먼저 파일을 고르고, 고르면 시트
	@MainActor
	func requestImport(schema: String?) {
		guard let url = Self.pickSQLFile() else { return }
		importRequest = ImportRequest(schema: schema, job: SQLImportJob(url: url, session: self))
	}

	@MainActor
	static func pickSQLFile() -> URL? {
		let p = NSOpenPanel()
		p.title = "가져올 SQL 파일"
		p.prompt = "고르기"
		p.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
		p.allowsOtherFileTypes = true
		p.canChooseDirectories = false
		p.allowsMultipleSelection = false
		return p.runModal() == .OK ? p.url : nil
	}

	/// 가져오기가 끝난 뒤 (멈춘 경우도): 목록·DB 개요 다시 읽기, 열린 데이터 탭은 다시 읽거나 "바뀜" 표시
	@MainActor
	func dataImported(schema: String?) async {
		try? await loadSchema()
		for (key, o) in overviews where schema == nil || key == schema { Task { await o.load() } }
		for (tab, d) in openData where schema == nil || Self.tableID(ofTab: tab).hasPrefix(schema! + ".") {
			if d.hasChanges { d.stale = true } else if d.loaded { Task { await d.load() } }
		}
	}

	/// 테이블 삭제·비우기 요청 (어디서 부르든 창이 확인 창 하나로 묻는다: DB 개요 −, 오른쪽 클릭 메뉴)
	var tableAction: TableActionRequest?
	/// 삭제·비우기 실패 글자 (창이 알림으로 보인다)
	var tableActionError: String?

	func requestDrop(schema: String, _ tables: [TableStat]) {
		guard !tables.isEmpty else { return }
		tableAction = TableActionRequest(kind: .drop, schema: schema, tables: tables)
	}

	/// 데이터베이스 통째로 삭제 (사이드바 − · DB 머리 오른쪽 클릭)
	func requestDropDatabase(_ schema: String) {
		tableAction = TableActionRequest(kind: .dropDatabase, schema: schema, tables: tables.filter { $0.schema == schema }.map(TableStat.init))
	}

	/// 설정 창 > 사용자 계정 (처음 볼 때 만든다)
	@ObservationIgnored private var accountStore: AccountManager?
	func accountManager() -> AccountManager {
		if let m = accountStore { return m }
		let m = AccountManager(session: self)
		accountStore = m
		return m
	}

	/// 서버 설정을 바꿨을 때 (설정 창). 저장은 부른 쪽이 ServerStore 에
	func updateServer(_ s: Server) {
		guard s.id == server?.id else { return }
		server = s
	}

	/// 새 데이터베이스 시트 (사이드바 +)
	var creatingDatabase = false

	/// 지금 탭(테이블·DB 개요)의 데이터베이스 — 사이드바 − 가 지울 DB
	var currentSchema: String? {
		guard let id = activeTab else { return nil }
		return table(id)?.schema ?? Self.databaseOf(tab: id)
	}

	/// 새 데이터베이스를 만든 뒤: 목록을 다시 읽고 펼쳐서 DB 개요 탭을 연다
	@MainActor
	func databaseCreated(_ name: String) async {
		try? await loadSchema()
		expanded.insert(name)
		openDatabase(name)
	}

	func requestTruncate(schema: String, _ tables: [TableStat]) {
		let list = tables.filter { !$0.isView }
		guard !list.isEmpty else { return }
		tableAction = TableActionRequest(kind: .truncate, schema: schema, tables: list)
	}

	/// 확인받은 삭제·비우기 실행. 일부만 됐을 수 있으니 실패해도 목록·탭을 맞춘다
	@MainActor
	func perform(_ r: TableActionRequest) async {
		func name(_ t: TableStat) -> String { quoteName(r.schema) + "." + quoteName(t.name) }
		var failure: String?
		switch r.kind {
		case .drop:
			let views = r.tables.filter(\.isView), bases = r.tables.filter { !$0.isView }
			do {
				if !views.isEmpty { _ = try await query("DROP VIEW " + views.map(name).joined(separator: ", ")) }
				if !bases.isEmpty { _ = try await query("DROP TABLE " + bases.map(name).joined(separator: ", ")) }
			} catch { failure = error.localizedDescription }
			try? await loadSchema()
			// 실제로 지워진 것만 탭을 닫는다
			let left = Set(tables.filter { $0.schema == r.schema }.map(\.name))
			closeTabs(ofTables: Set(r.tables.map(\.name).filter { !left.contains($0) }.map { r.schema + "." + $0 }))
		case .dropDatabase:
			do { _ = try await query("DROP DATABASE " + quoteName(r.schema)) } catch { failure = error.localizedDescription }
			try? await loadSchema()
			if !databases.contains(r.schema) {
				closeTabs(ofTables: Set(r.tables.map { r.schema + "." + $0.name }))
				closeTab(Self.databaseTabID(r.schema))
				expanded.remove(r.schema)
				overviews[r.schema] = nil
			}
			tableActionError = failure
			return
		case .truncate:
			// TRUNCATE 는 테이블 하나씩. 외래 키로 막히면 거기서 멈춘다
			for t in r.tables {
				do { _ = try await query("TRUNCATE TABLE " + name(t)) } catch { failure = "\(t.name): \(error.localizedDescription)"; break }
			}
			try? await loadSchema()
			// 열린 데이터 탭: 저장 안 한 변경이 없으면 다시 읽고, 있으면 "바뀜" 표시
			let ids = Set(r.tables.map { r.schema + "." + $0.name })
			for (tab, d) in openData where ids.contains(Self.tableID(ofTab: tab)) {
				if d.hasChanges { d.stale = true } else if d.loaded { Task { await d.load() } }
			}
			for id in ids { if let t = table(id) { await reloadInspector(t) } }
		}
		if let o = overviews[r.schema] { o.selection = []; await o.load() }
		tableActionError = failure
	}

	/// 새 테이블 만들기 요청 (창이 제목바 시트로 띄운다)
	var createTableRequest: CreateTableRequest?

	/// 테이블을 만든 뒤: 목록을 다시 읽고, 그 DB 개요가 열려 있으면 다시 읽고, 새 테이블을 탭으로 연다
	@MainActor
	func tableCreated(schema: String, name: String) async {
		try? await loadSchema()
		if let o = overviews[schema] { Task { await o.load() } }
		if let t = tables.first(where: { $0.schema == schema && $0.name == name }) {
			expanded.insert(schema)
			openTab(t)
		}
	}

	/// DB 전체 (사이드바 DB 머리 오른쪽 클릭): 고르기 목록을 보이고 전부 체크
	func requestExport(schema: String) {
		let all = tables.filter { $0.schema == schema }.map(TableStat.init)
		requestExport(.database(schema: schema, tables: all, picked: Set(all.map(\.name)), showPicker: true))
	}

	// MARK: DB 개요 탭 ("db:<스키마>")

	static func databaseTabID(_ schema: String) -> String { "db:" + schema }
	/// DB 개요 탭이면 그 스키마
	static func databaseOf(tab id: String) -> String? { id.hasPrefix("db:") ? String(id.dropFirst(3)) : nil }

	/// DB 개요 (탭을 다시 열어도 다시 읽지 않게 보관)
	@ObservationIgnored private var overviews: [String: DatabaseOverview] = [:]
	func overview(_ schema: String) -> DatabaseOverview {
		if let o = overviews[schema] { return o }
		let o = DatabaseOverview(schema: schema, session: self)
		overviews[schema] = o
		return o
	}

	/// DB 이름을 누르면: DB 개요 탭
	func openDatabase(_ schema: String) {
		open(tabID: Self.databaseTabID(schema))
	}

	private func open(tabID id: String) {
		if parked.contains(id) { focusParked?(id); return }
		leftFocusTick += 1
		if !tabs.contains(id) {
			if let a = activeTab, let i = tabs.firstIndex(of: a) { tabs.insert(id, at: i + 1) } else { tabs.append(id) }
		}
		activeTab = id
		rememberTabs()
	}

	/// 사이드바에서 테이블 열기: 왼쪽에 이미 있으면 그 탭, 없으면 새 탭 (오른쪽에 같은 테이블이 있어도 왼쪽에 따로 연다)
	func openTab(_ t: TableInfo) {
		leftFocusTick += 1
		let id = tabs.first { Self.tableID(ofTab: $0) == t.id } ?? newTabID(for: t.id)
		if !tabs.contains(id) {
			// 지금 탭 바로 오른쪽에 연다
			if let a = activeTab, let i = tabs.firstIndex(of: a) { tabs.insert(id, at: i + 1) } else { tabs.append(id) }
		}
		activeTab = id
		rememberTabs()
	}

	/// 왼쪽에 이 탭과 같은 테이블(또는 같은 DB 개요)이 열려 있는지
	func leftHasSame(as tab: String) -> Bool {
		let tid = Self.tableID(ofTab: tab)
		return tabs.contains { Self.tableID(ofTab: $0) == tid }
	}

	/// 왼쪽 탭의 사본을 만들어 오른쪽에 둔다 (데이터는 새로 읽는다). 새 탭 id
	func duplicateToParked(_ tab: String) -> String? {
		guard table(tab) != nil else { return nil }
		let id = newTabID(for: Self.tableID(ofTab: tab))
		parked.append(id)
		rememberTabs()
		return id
	}

	func closeTab(_ id: String) {
		guard let i = tabs.firstIndex(of: id) else { return }
		tabs.remove(at: i)
		openData[id] = nil
		setUnsaved(id, false)
		if activeTab == id { activeTab = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)] }
		rememberTabs()
	}

	/// 지운 테이블의 탭(왼쪽·오른쪽, 사본까지)을 닫는다
	func closeTabs(ofTables ids: Set<String>) {
		guard !ids.isEmpty else { return }
		for t in tabs where ids.contains(Self.tableID(ofTab: t)) { closeTab(t) }
		for t in parked where ids.contains(Self.tableID(ofTab: t)) { closeParkedTab?(t) }
	}

	/// 왼쪽 탭을 고른다 (탭바 누르기)
	func selectTab(_ id: String) {
		leftFocusTick += 1
		activeTab = id
	}

	// MARK: 오른쪽 분할 (임시 영역)

	/// 왼쪽 탭을 오른쪽으로: 탭바에서만 빼고 데이터는 둔다
	func park(_ id: String) {
		guard let i = tabs.firstIndex(of: id) else { return }
		tabs.remove(at: i)
		if !parked.contains(id) { parked.append(id) }
		if activeTab == id { activeTab = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)] }
		rememberTabs()
	}

	/// 왼쪽 탭 순서 바꾸기 (끌어 놓기): before 탭 앞으로, nil 이면 맨 뒤로
	func moveTab(_ id: String, before: String?) {
		guard id != before, let i = tabs.firstIndex(of: id) else { return }
		tabs.remove(at: i)
		if let b = before, let j = tabs.firstIndex(of: b) { tabs.insert(id, at: j) } else { tabs.append(id) }
		rememberTabs()
	}

	/// 오른쪽 탭을 왼쪽으로: before 탭 앞에 (nil 이면 지금 탭 바로 오른쪽) 넣고 고른다
	func unpark(_ id: String, before: String? = nil) {
		parked.removeAll { $0 == id }
		if !tabs.contains(id) {
			if let b = before, let j = tabs.firstIndex(of: b) { tabs.insert(id, at: j) }
			else if let a = activeTab, let i = tabs.firstIndex(of: a) { tabs.insert(id, at: i + 1) } else { tabs.append(id) }
		}
		selectTab(id)
		rememberTabs()
	}

	/// 오른쪽 탭 닫기
	func closeParked(_ id: String) {
		parked.removeAll { $0 == id }
		openData[id] = nil
		setUnsaved(id, false)
		rememberTabs()
	}

	/// 탭 id(또는 테이블 id)의 테이블
	func table(_ id: String) -> TableInfo? {
		let tid = Self.tableID(ofTab: id)
		return tables.first { $0.id == tid }
	}

	func setUnsaved(_ id: String, _ on: Bool) {
		if on != unsavedTables.contains(id) { if on { unsavedTables.insert(id) } else { unsavedTables.remove(id) } }
	}

	/// 터널(필요하면)과 MySQL 연결을 연다. 접속 시험에서도 쓴다
	@MainActor
	static func open(_ server: Server, mysqlPassword: String?, sshSecret: String?,
	                 progress: (String) -> Void) async throws -> (SSHTunnel?, MySQLConnection) {
		var tunnel: SSHTunnel?
		var host = server.host
		var port = server.port
		if server.ssh.enabled {
			progress("SSH 터널 여는 중… (\(server.ssh.host))")
			let t = try await SSHTunnel.open(server, secret: sshSecret?.isEmpty == false ? sshSecret : nil)
			tunnel = t
			host = "127.0.0.1"
			port = Int(t.localPort)
		}
		progress("MySQL 로그인 중…")
		do {
			let c = try await MySQLConnection.connect(.init(host: host, port: port, user: server.user,
			                                                password: mysqlPassword ?? "", database: server.database))
			return (tunnel, c)
		} catch {
			tunnel?.close()
			throw error
		}
	}

	// MARK: - 테이블 목록

	@MainActor
	func loadSchema() async throws {
		guard let conn else { return }
		loadingSchema = true
		defer { loadingSchema = false }
		let excluded = Self.systemSchemas.map { "'\($0)'" }.joined(separator: ",")
		let results = try await conn.query("""
			SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN (\(excluded)) ORDER BY SCHEMA_NAME;
			SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_COMMENT, TABLE_ROWS, ENGINE FROM information_schema.TABLES
			 WHERE TABLE_SCHEMA NOT IN (\(excluded)) ORDER BY TABLE_SCHEMA, TABLE_NAME;
			SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
			  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN (\(excluded)) ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
			""")
		guard results.count >= 3 else { return }

		databases = results[0].rows.compactMap { $0.first?.string }

		tables = results[1].rows.map { r in
			let isView = r[2].string == "VIEW"
			return TableInfo(schema: r[0].string ?? "", name: r[1].string ?? "", isView: isView,
			                 // MySQL 은 뷰의 코멘트에 "VIEW" 라고 넣는다
			                 comment: isView ? "" : (r[3].string ?? ""),
			                 rows: r[4].string.flatMap { Int64($0) }, engine: r[safe: 5]?.string ?? "")
		}

		var cols: [String: [ColumnInfo]] = [:]
		for r in results[2].rows {
			let id = (r[0].string ?? "") + "." + (r[1].string ?? "")
			cols[id, default: []].append(ColumnInfo(name: r[2].string ?? "", type: r[3].string ?? "", nullable: r[4].string == "YES",
			                                        key: r[5].string ?? "", defaultValue: r[6].string, extra: r[7].string ?? "",
			                                        comment: r[8].string ?? ""))
		}
		columns = cols
	}

	/// 검색: 테이블 이름, 테이블 코멘트, 컬럼 이름, 컬럼 코멘트. 띄어 쓴 낱말은 모두 들어 있어야 한다
	func search(_ text: String) -> [TableInfo] {
		let words = text.lowercased().split(separator: " ").map(String.init)
		guard !words.isEmpty else { return tables }
		return tables.filter { t in
			let cols = columns[t.id] ?? []
			let hay = ([t.schema, t.name, t.comment] + cols.flatMap { [$0.name, $0.comment] }).joined(separator: "\n").lowercased()
			return words.allSatisfy { hay.contains($0) }
		}
	}

	/// 이 테이블이 검색어에 걸린 이유가 컬럼이면 그 컬럼 이름들 (목록에 보여 주려고)
	func matchedColumns(_ t: TableInfo, _ text: String) -> [String] {
		let words = text.lowercased().split(separator: " ").map(String.init)
		guard !words.isEmpty else { return [] }
		let direct = "\(t.schema) \(t.name) \(t.comment)".lowercased()
		if words.allSatisfy({ direct.contains($0) }) { return [] }
		return (columns[t.id] ?? []).filter { c in
			let h = (c.name + " " + c.comment).lowercased()
			return words.contains { h.contains($0) }
		}.map(\.name)
	}

	func query(_ sql: String) async throws -> [QueryResult] {
		guard let conn else { throw MySQLError.closed }
		return try await conn.query(sql)
	}

	// MARK: 테이블 정보 패널 (구조 보기 오른쪽)

	/// 구조 보기에서 테이블 정보 패널을 펼쳤는지 (탭을 바꿔도 그대로).
	/// 처음엔 펼쳐 두고(사용자: 인덱스가 점점 복잡해진다), 닫으면 닫은 채로 기억한다 (UserDefaults "showTableInfo", 이 맥에만)
	var showTableInfo = UserDefaults.standard.object(forKey: "showTableInfo") as? Bool ?? true {
		didSet { UserDefaults.standard.set(showTableInfo, forKey: "showTableInfo") }
	}
	/// 엔진·문자셋·콜레이션 목록 (패널을 처음 열 때 읽는다)
	private(set) var catalog = ServerCatalog()
	@ObservationIgnored private var catalogLoaded = false
	@ObservationIgnored private var inspectors: [String: TableInspector] = [:]

	/// 테이블 정보 패널을 한 번이라도 열었으면 다시 읽는다 (구조를 바꾸면 인덱스의 컬럼 이름·키가 바뀐다)
	@MainActor
	func reloadInspector(_ table: TableInfo) async {
		if let i = inspectors[table.id] { await i.load() }
	}

	func inspector(for table: TableInfo) -> TableInspector {
		if let i = inspectors[table.id] { return i }
		let i = TableInspector(table: table, session: self)
		inspectors[table.id] = i
		return i
	}

	@MainActor
	func loadCatalogIfNeeded() async throws {
		guard !catalogLoaded else { return }
		var c = ServerCatalog()
		let e = try await query("SHOW ENGINES").last ?? QueryResult()
		let iSupport = e.columns.firstIndex { $0.name.caseInsensitiveCompare("Support") == .orderedSame } ?? 1
		c.engines = e.rows.filter { ["YES", "DEFAULT"].contains($0[safe: iSupport]?.string?.uppercased() ?? "") }
			.compactMap { $0.first?.string }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
		let cs = try await query("SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS ORDER BY CHARACTER_SET_NAME").last ?? QueryResult()
		c.charsets = cs.rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
		let co = try await query("SELECT COLLATION_NAME, CHARACTER_SET_NAME FROM information_schema.COLLATIONS ORDER BY COLLATION_NAME").last ?? QueryResult()
		c.collations = co.rows.map { ($0[0].string ?? "", $0[safe: 1]?.string ?? "") }
		// 전문 검색 파서·n-gram 조각 크기 (없는 서버면 비워 둔다)
		c.fulltextParsers = (try? await query("SELECT PLUGIN_NAME FROM information_schema.PLUGINS WHERE PLUGIN_TYPE = 'FTPARSER' AND PLUGIN_STATUS = 'ACTIVE'").last)?
			.rows.compactMap { $0.first?.string } ?? []
		if c.fulltextParsers.contains("ngram") {
			c.ngramTokenSize = (try? await query("SELECT @@ngram_token_size").last)?.rows.first?.first?.string.flatMap { Int($0) }
		}
		catalog = c
		catalogLoaded = true
	}
}

/// 서버별로 열어 둔 탭 (UserDefaults "tabs.<서버id>", 이 맥에만)
enum TabMemory {
	struct Saved: Codable {
		var tabs: [String]
		var active: String?
		var expanded: Set<String>
	}

	private static func key(_ id: UUID) -> String { "tabs.\(id.uuidString)" }

	static func save(server: UUID, tabs: [String], active: String?, expanded: Set<String>) {
		if let data = try? JSONEncoder().encode(Saved(tabs: tabs, active: active, expanded: expanded)) {
			UserDefaults.standard.set(data, forKey: key(server))
		}
	}

	static func load(server: UUID) -> Saved? {
		guard let data = UserDefaults.standard.data(forKey: key(server)) else { return nil }
		return try? JSONDecoder().decode(Saved.self, from: data)
	}
}
