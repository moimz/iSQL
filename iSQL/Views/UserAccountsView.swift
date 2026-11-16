import SwiftUI

/// 설정 창 > 사용자 계정: 왼쪽 계정 목록([+ −] [↻]), 오른쪽 고른 계정 (비밀번호·잠금, 전역 권한, DB 별 권한, SHOW GRANTS)
struct UserAccountsView: View {
	let session: Session
	@Bindable var manager: AccountManager
	@State private var selectedID: String?
	/// 전역 권한 체크를 바꾸는 중 (적용 전)
	@State private var editing: Set<String>?
	@State private var addingUser = false
	@State private var changingPassword = false
	@State private var addingDBGrant = false
	@State private var confirmDrop = false
	@State private var confirmRevoke: DBGrant?

	private var selected: DBAccount? { manager.accounts.first { $0.id == selectedID } }

	var body: some View {
		Group {
			if let e = manager.loadError {
				ContentUnavailableView {
					Label("사용자 계정을 볼 수 없습니다", systemImage: "lock")
				} description: {
					Text(e).textSelection(.enabled)
				} actions: {
					Button("다시 읽기") { Task { await manager.load() } }
				}
			} else {
				// Mail 계정 설정처럼: 테두리 상자 안 목록 + 아래 [+ −], 오른쪽에 고른 계정 (창 가장자리에 붙는 사이드바가 아니다)
				HStack(alignment: .top, spacing: 16) {
					accountList.frame(width: 250)
					detail.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
				.padding(20)
			}
		}
		.task {
			if !manager.loaded { await manager.load() }
			// 처음엔 지금 접속한 계정을 고른다
			if selectedID == nil { selectedID = manager.accounts.first { $0.id == manager.current }?.id ?? manager.accounts.first?.id }
		}
		.onChange(of: selectedID) {
			editing = nil
			if let a = selected { Task { await manager.loadGrants(a) } }
		}
		.sheet(isPresented: $addingUser) {
			AddUserSheet(databases: session.databases) { user, host, password, makeDB in
				var sql = [AccountManager.createSQL(user: user, host: host, password: password)]
				let a = DBAccount(user: user, host: host)
				if makeDB {
					sql.append("CREATE DATABASE IF NOT EXISTS \(quoteName(user))")
					sql.append("GRANT ALL PRIVILEGES ON \(AccountManager.target(user)) TO \(a.sql)")
				}
				let ok = await manager.run(sql, then: a)
				if ok { selectedID = a.id; if makeDB { try? await session.loadSchema() } }
				return ok
			}
		}
		.sheet(isPresented: $changingPassword) {
			if let a = selected {
				PasswordSheet(account: a) { pw in
					await manager.run(["ALTER USER \(a.sql) IDENTIFIED BY \(literal(.text(pw)))"], then: a)
				}
			}
		}
		.sheet(isPresented: $addingDBGrant) {
			if let a = selected {
				DBGrantSheet(account: a, databases: session.databases) { db, privs in
					guard let sql = Privilege.grantSQL(privs, on: AccountManager.target(db), to: a) else { return true }
					return await manager.run([sql], then: a)
				}
			}
		}
		.confirmationDialog("계정 \(selected?.sql ?? "") 을(를) 삭제할까요?", isPresented: $confirmDrop) {
			Button("계정 삭제", role: .destructive) {
				guard let a = selected else { return }
				Task { if await manager.run(["DROP USER \(a.sql)"]) { selectedID = nil } }
			}
		} message: {
			Text(selected?.id == currentID ? "지금 이 계정으로 접속해 있습니다. 지우면 다음 접속부터 들어올 수 없습니다." : "되돌릴 수 없습니다.")
		}
		.confirmationDialog("\(confirmRevoke?.db ?? "") 의 권한을 모두 회수할까요?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
			Button("회수", role: .destructive) {
				guard let a = selected, let g = confirmRevoke else { return }
				confirmRevoke = nil
				let target = AccountManager.target(g.db)
				var sql = ["REVOKE ALL PRIVILEGES ON \(target) FROM \(a.sql)"]
				if g.privileges.contains("GRANT OPTION") { sql.append("REVOKE GRANT OPTION ON \(target) FROM \(a.sql)") }
				Task { await manager.run(sql, then: a) }
			}
		}
		.alert("실행하지 못했습니다", isPresented: Binding(get: { manager.runError != nil }, set: { if !$0 { manager.runError = nil } })) {
			Button("확인") { manager.runError = nil }
		} message: {
			Text(manager.runError ?? "")
		}
	}

	/// CURRENT_USER() 는 "user@host"
	private var currentID: String { manager.current }

	// MARK: 목록

	private var accountList: some View {
		VStack(spacing: 0) {
			List(selection: $selectedID) {
				ForEach(manager.accounts) { a in
					HStack(spacing: 6) {
						Image(systemName: a.locked == true ? "person.crop.circle.badge.xmark" : "person.crop.circle")
							.foregroundStyle(a.locked == true ? Color.secondary : Color.accentColor)
						VStack(alignment: .leading, spacing: 1) {
							Text(a.user.isEmpty ? "(익명)" : a.user).lineLimit(1)
							Text("@" + a.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
						}
						Spacer(minLength: 0)
						if a.id == currentID {
							Text("접속 중").font(.caption2.weight(.semibold)).foregroundStyle(.green)
						}
					}
					.tag(a.id)
				}
			}
			// .sidebar 는 설정 창 제목바까지 올라가 붙어서 테두리 상자 안 목록으로
			.listStyle(.inset)
			.scrollContentBackground(.hidden)
			.background(Color(nsColor: .textBackgroundColor).opacity(0.4))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
			.overlay { if manager.loading && manager.accounts.isEmpty { ProgressView() } }
			HStack(spacing: 8) {
				AddRemovePill(addHelp: "사용자 추가", add: { addingUser = true },
				              removeHelp: "고른 사용자 삭제…", remove: selected == nil ? nil : { confirmDrop = true })
				Spacer(minLength: 0)
				Button { Task { await manager.load() } } label: {
					if manager.loading { ProgressView().controlSize(.small).frame(width: 30, height: 28) } else { PillIcon(systemName: "arrow.clockwise") }
				}
				.pill()
				.help("다시 읽기")
			}
			.padding(.top, 10)
		}
	}

	// MARK: 고른 계정

	@ViewBuilder private var detail: some View {
		if let a = selected {
			ScrollView {
				VStack(alignment: .leading, spacing: 22) {
					header(a)
					globalSection(a)
					dbSection(a)
					grantsSection(a)
				}
				.padding(.horizontal, 4)
				.padding(.bottom, 12)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		} else {
			ContentUnavailableView("계정을 고르세요", systemImage: "person.2",
			                       description: Text("\(manager.accounts.count)개 계정"))
		}
	}

	private func header(_ a: DBAccount) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(a.sql).font(.title3.weight(.semibold).monospaced()).textSelection(.enabled)
			HStack(spacing: 10) {
				if !a.plugin.isEmpty { Text(a.plugin).font(.callout).foregroundStyle(.secondary) }
				if a.locked == true { Label("잠김", systemImage: "lock.fill").font(.callout).foregroundStyle(.orange) }
				Spacer()
				Button("비밀번호 바꾸기…") { changingPassword = true }
				if let locked = a.locked {
					Button(locked ? "잠금 풀기" : "잠그기") {
						Task { await manager.run(["ALTER USER \(a.sql) ACCOUNT \(locked ? "UNLOCK" : "LOCK")"], then: a) }
					}
				}
			}
		}
	}

	private func sectionTitle(_ s: String) -> some View {
		Text(s).font(.headline)
	}

	// 전역 권한: 데이터 / 구조 / 관리 세 칸 체크박스
	private func globalSection(_ a: DBAccount) -> some View {
		let current = editing ?? a.global
		let changes = AccountManager.globalChangeSQL(a, to: current)
		return VStack(alignment: .leading, spacing: 10) {
			HStack {
				sectionTitle("전역 권한 (모든 데이터베이스)")
				Spacer()
				Button("모두 선택") { editing = Set(Privilege.all.map(\.sql)) }.buttonStyle(.link)
				Button("모두 해제") { editing = [] }.buttonStyle(.link)
			}
			HStack(alignment: .top, spacing: 24) {
				ForEach(Privilege.Group.allCases, id: \.self) { g in
					VStack(alignment: .leading, spacing: 4) {
						Text(g.rawValue).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
						ForEach(Privilege.all.filter { $0.group == g }, id: \.sql) { p in
							Toggle(p.sql, isOn: Binding(get: { current.contains(p.sql) }, set: { on in
								var s = current
								if on { s.insert(p.sql) } else { s.remove(p.sql) }
								editing = s
							}))
							.toggleStyle(.checkbox)
							.font(.callout.monospaced())
						}
					}
				}
			}
			if !changes.isEmpty {
				VStack(alignment: .leading, spacing: 8) {
					Text(changes.joined(separator: ";\n") + ";")
						.font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
					HStack {
						Spacer()
						Button("되돌리기") { editing = nil }
						Button {
							Task { if await manager.run(changes, then: a) { editing = nil } }
						} label: {
							if manager.running { ProgressView().controlSize(.small) } else { Text("적용") }
						}
						.buttonStyle(.borderedProminent)
					}
				}
				.padding(10)
				.background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
			}
		}
	}

	// DB 별 권한 목록 + 추가·회수
	private func dbSection(_ a: DBAccount) -> some View {
		let list = manager.dbGrants[a.id] ?? []
		return VStack(alignment: .leading, spacing: 8) {
			HStack {
				sectionTitle("데이터베이스별 권한")
				Spacer()
				Button("데이터베이스 권한 추가…") { addingDBGrant = true }
			}
			if list.isEmpty {
				Text("없음").foregroundStyle(.secondary).font(.callout)
			}
			ForEach(list) { g in
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
					Text(g.db).font(.body.monospaced()).frame(width: 140, alignment: .leading).lineLimit(1)
					Text(g.privileges.count >= Privilege.all.filter(\.perDatabase).count - 1
					     ? "모든 권한" + (g.privileges.contains("GRANT OPTION") ? " + GRANT OPTION" : "")
					     : Privilege.all.map(\.sql).filter { g.privileges.contains($0) }.joined(separator: ", "))
						.font(.callout).foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
					Button { confirmRevoke = g } label: { Image(systemName: "minus.circle") }
						.buttonStyle(.borderless)
						.help("이 데이터베이스 권한 모두 회수")
				}
			}
		}
	}

	private func grantsSection(_ a: DBAccount) -> some View {
		let g = manager.showGrants[a.id] ?? []
		return VStack(alignment: .leading, spacing: 8) {
			sectionTitle("SHOW GRANTS")
			Text(g.isEmpty ? "—" : g.joined(separator: ";\n") + ";")
				.font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
		}
	}
}

// MARK: - 시트

/// 사용자 추가: 이름, 호스트(% / localhost / 직접), 비밀번호, (선택) 같은 이름의 DB 와 모든 권한
struct AddUserSheet: View {
	let databases: [String]
	let create: (String, String, String, Bool) async -> Bool
	@Environment(\.dismiss) private var dismiss
	@State private var user = ""
	@State private var hostKind = "%"
	@State private var customHost = ""
	@State private var password = ""
	@State private var confirm = ""
	@State private var makeDB = false
	@State private var running = false

	private var host: String { hostKind == "직접" ? customHost.trimmingCharacters(in: .whitespaces) : hostKind }
	private var problem: String? {
		if user.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
		if host.isEmpty { return "호스트를 넣으세요" }
		if password != confirm { return "비밀번호가 서로 다릅니다" }
		return nil
	}
	private var canCreate: Bool { !user.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil && !running }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("사용자 추가").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
				GridRow {
					Text("사용자 이름").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
					TextField("", text: $user).textFieldStyle(.roundedBorder)
				}
				GridRow {
					Text("호스트").foregroundStyle(.secondary)
					HStack {
						Picker("", selection: $hostKind) {
							Text("아무 곳 (%)").tag("%")
							Text("localhost").tag("localhost")
							Text("직접 넣기").tag("직접")
						}
						.labelsHidden().fixedSize()
						if hostKind == "직접" {
							TextField("예: 192.168.0.%", text: $customHost).textFieldStyle(.roundedBorder)
						}
					}
				}
				GridRow {
					Text("비밀번호").foregroundStyle(.secondary)
					SecureField("", text: $password).textFieldStyle(.roundedBorder)
				}
				GridRow {
					Text("비밀번호 확인").foregroundStyle(.secondary)
					SecureField("", text: $confirm).textFieldStyle(.roundedBorder)
				}
			}
			Toggle("같은 이름의 데이터베이스를 만들고 모든 권한 주기", isOn: $makeDB).toggleStyle(.checkbox)
			if let p = problem {
				Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
			} else if !user.isEmpty {
				Text(AccountManager.createSQL(user: user, host: host, password: password.isEmpty ? "" : "••••"))
					.font(.callout.monospaced()).foregroundStyle(.secondary)
			}
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button {
					running = true
					Task {
						let ok = await create(user.trimmingCharacters(in: .whitespaces), host, password, makeDB)
						running = false
						if ok { dismiss() }
					}
				} label: {
					if running { ProgressView().controlSize(.small) } else { Text("추가") }
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(!canCreate)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 460)
	}
}

/// 비밀번호 바꾸기
struct PasswordSheet: View {
	let account: DBAccount
	let change: (String) async -> Bool
	@Environment(\.dismiss) private var dismiss
	@State private var password = ""
	@State private var confirm = ""
	@State private var running = false

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(account.sql) 비밀번호 바꾸기").font(.headline)
			SecureField("새 비밀번호", text: $password).textFieldStyle(.roundedBorder)
			SecureField("새 비밀번호 확인", text: $confirm).textFieldStyle(.roundedBorder)
			if !confirm.isEmpty && password != confirm {
				Label("비밀번호가 서로 다릅니다", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
			}
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("바꾸기") {
					running = true
					Task { let ok = await change(password); running = false; if ok { dismiss() } }
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(password.isEmpty || password != confirm || running)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 400)
	}
}

/// 데이터베이스 권한 추가: DB 고르기 + 권한 체크 (기본: 데이터 넷)
struct DBGrantSheet: View {
	let account: DBAccount
	let databases: [String]
	let grant: (String, Set<String>) async -> Bool
	@Environment(\.dismiss) private var dismiss
	@State private var db = ""
	@State private var privs: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE"]
	@State private var running = false

	private var perDB: [Privilege] { Privilege.all.filter(\.perDatabase) }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("\(account.sql) 에 데이터베이스 권한 추가").font(.headline)
			HStack {
				Text("데이터베이스").foregroundStyle(.secondary)
				PopUp(selection: $db, options: databases.map { ($0, Optional($0)) })
					.frame(width: 240)
			}
			HStack {
				Button("모두 선택") { privs = Set(perDB.map(\.sql)) }.buttonStyle(.link)
				Button("모두 해제") { privs = [] }.buttonStyle(.link)
			}
			HStack(alignment: .top, spacing: 24) {
				ForEach(Privilege.Group.allCases, id: \.self) { g in
					let list = perDB.filter { $0.group == g }
					if !list.isEmpty {
						VStack(alignment: .leading, spacing: 4) {
							Text(g.rawValue).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
							ForEach(list, id: \.sql) { p in
								Toggle(p.sql, isOn: Binding(get: { privs.contains(p.sql) }, set: { on in
									if on { privs.insert(p.sql) } else { privs.remove(p.sql) }
								}))
								.toggleStyle(.checkbox)
								.font(.callout.monospaced())
							}
						}
					}
				}
			}
			if let sql = Privilege.grantSQL(privs, on: AccountManager.target(db), to: account), !db.isEmpty {
				Text(sql).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("추가") {
					running = true
					Task { let ok = await grant(db, privs); running = false; if ok { dismiss() } }
				}
				.buttonStyle(.borderedProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(db.isEmpty || privs.isEmpty || running)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 620)
		.onAppear { if db.isEmpty { db = databases.first ?? "" } }
	}
}
