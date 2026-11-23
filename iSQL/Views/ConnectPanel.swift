import SwiftUI
import AppKit

/// 접속 전 가운데 화면: 퀵 커넥트.
/// 왼쪽 목록에서 고른 서버의 설정을 바로 고치거나 접속하고, 아무것도 안 골랐으면 새 접속(저장 없이 바로 접속 가능).
struct ConnectPanel: View {
	@Environment(ServerStore.self) private var store
	let model: WindowModel

	var body: some View {
		let saved = model.selectedServerID.flatMap { id in store.servers.first { $0.id == id } }
		ConnectForm(model: model, initial: saved ?? model.draft, saved: saved != nil)
			.id(saved?.id.uuidString ?? "draft-" + model.draft.id.uuidString)
	}
}

struct ConnectForm: View {
	@Environment(ServerStore.self) private var store
	let model: WindowModel
	let saved: Bool
	@State private var server: Server
	@State private var mysqlPassword = ""
	@State private var sshSecret = ""
	@State private var testing = false
	@State private var testSteps: [TestStep] = []
	/// 접속 시험 차례 번호: 중단하면 올려서, 늦게 끝난 시험의 결과는 버리고 연결은 닫는다
	@State private var testRun = 0
	@State private var savedFlash = false
	/// 허용 IP 칸에 친 글 그대로 (치는 중에 쉼표가 사라지지 않게). 나눈 목록은 server.allowedIPs 에
	@State private var allowedText = ""

	struct TestStep: Identifiable {
		let id = UUID()
		var ok: Bool?
		var text: String
	}

	init(model: WindowModel, initial: Server, saved: Bool) {
		self.model = model
		self.saved = saved
		_server = State(initialValue: initial)
		_allowedText = State(initialValue: (initial.allowedIPs ?? []).joined(separator: ", "))
	}

	@State private var showPassword = false
	/// 이 맥에서만 쓰는 SQLite 경로를 바꿨을 때 다시 그리게
	@State private var localPathBump = 0
	@State private var showSecret = false

	var body: some View {
		GeometryReader { geo in
			ScrollView {
				VStack(spacing: 14) {
					card
					buttons
				}
				.frame(width: 520)
				.padding(.vertical, 30)
				// 창이 충분히 높으면 가운데, 모자라면 스크롤
				.frame(maxWidth: .infinity, minHeight: geo.size.height)
			}
		}
		.onAppear {
			if saved {
				mysqlPassword = Keychain.get(server.mysqlPasswordKey) ?? ""
				sshSecret = Keychain.get(server.sshSecretKey) ?? ""
			}
		}
		// 새 접속 내용은 다른 화면에 다녀와도 남게
		.onChange(of: server) { _, s in if !saved { model.draft = s } }
	}

	/// 상자: 위 가장자리에 걸친 DB 종류 탭 + 라벨 오른쪽 정렬 입력칸. 접속 방식(TCP/IP · SSH)은 그룹 아래 구분선 가운데 (사용자 2026-11-18)
	/// 애플 기본 TabView (박스 위에 탭이 걸친 모양). 지금은 MySQL · MariaDB 하나 (접속해 보고 둘을 가린다), 다른 DB 를 붙이면 탭이 늘어난다
	private var card: some View {
		TabView(selection: kindTab) {
			fields(ssh: server.ssh.enabled).tabItem { Text(SQLKind.mysql.familyLabel) }.tag("mysql")
			fields(ssh: server.ssh.enabled).tabItem { Text(SQLKind.sqlserver.label) }.tag("sqlserver")
			fields(ssh: server.ssh.enabled).tabItem { Text(SQLKind.oracle.label) }.tag("oracle")
			fields(ssh: false).tabItem { Text(SQLKind.sqlite.label) }.tag("sqlite")
		}
		// TabView 는 세로로 남는 공간을 다 차지한다 → 내용 높이에 맞춘다 (박스가 화면 끝까지 늘어나 입력칸이 가운데 떠 있었다)
		.fixedSize(horizontal: false, vertical: true)
	}

	private var groupNames: [String] { store.grouped.map(\.group).filter { !$0.isEmpty } }

	/// 위 탭: MySQL · MariaDB / SQL Server / Oracle / SQLite (고른 탭이 곧 서버 종류. MySQL·MariaDB 는 접속해 보고 가린다).
	/// 탭을 바꾸면 포트가 그 종류의 기본값이었으면 새 종류의 기본값으로, 사용자 root 는 비운다
	private var kindTab: Binding<String> {
		Binding(get: {
			switch server.sqlKind {
			case .sqlite: "sqlite"
			case .oracle: "oracle"
			case .sqlserver: "sqlserver"
			default: "mysql"
			}
		}, set: { tab in
			let old = server.sqlKind ?? .mysql
			let new: SQLKind = switch tab {
			case "sqlite": .sqlite
			case "oracle": .oracle
			case "sqlserver": .sqlserver
			default: old == .mariadb ? .mariadb : .mysql
			}
			guard new != old else { return }
			server.kind = new.rawValue
			if let p = old.defaultPort, server.port == p, let np = new.defaultPort { server.port = np }
			if new == .oracle || new == .sqlserver, server.user == "root" { server.user = "" }
			// SQL Server 는 자체 서명 인증서가 기본이라 "필수"(인증서 확인 안 함)로 시작
			if new == .sqlserver, server.tls == nil { server.tls = .required }
		})
	}

	/// SQLite: 파일 고르기·새로 만들기, 동기화 폴더 경고, 이 맥에 파일이 없을 때 안내
	@ViewBuilder private var sqliteRows: some View {
		let _ = localPathBump
		divider
		row("파일") {
			HStack(spacing: 6) {
				field(Binding(get: { server.path ?? "" }, set: { server.path = $0.isEmpty ? nil : $0 }), "~/경로/파일.sqlite")
				Button("고르기…") { pickSQLite(create: false) }
				Button("새로 만들기…") { pickSQLite(create: true) }
			}
		}
		if let p = server.sqliteFilePath {
			if !FileManager.default.fileExists(atPath: p) {
				GridRow {
					Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
					Label("이 맥에 파일이 없습니다. 고르기로 이 맥의 파일을 정하면 이 맥에서만 그 경로를 씁니다", systemImage: "questionmark.folder")
						.font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
				}
			} else if Server.isInSyncedFolder(p) {
				GridRow {
					Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
					Label("동기화되는 폴더의 파일입니다. 열어 둔 채 고치면 동기화가 중간 상태를 옮겨 파일이 깨질 수 있습니다", systemImage: "exclamationmark.icloud")
						.font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	/// 파일 고르기 / 새 파일 만들기. 동기화 폴더면 한 번 묻는다 (사용자 2026-11-18)
	private func pickSQLite(create: Bool) {
		let url: URL
		if create {
			let panel = NSSavePanel()
			panel.nameFieldStringValue = "새 데이터베이스.sqlite"
			panel.message = "새 SQLite 파일을 만들 곳"
			guard panel.runModal() == .OK, let u = panel.url else { return }
			url = u
		} else {
			let panel = SQLiteFile.openPanel()
			guard panel.runModal() == .OK, let u = panel.url else { return }
			url = u
		}
		Task {
			if !create { guard await SQLiteFile.checkOrAlert(url) else { return } }
			guard await SQLiteFile.confirmSyncedFolder(url, create: create) else { return }
			if create {
				do { (try await SQLiteConnection.open(path: url.path, create: true)).close() } catch {
					await Confirm.inform("파일을 만들지 못했습니다", error.localizedDescription)
					return
				}
			}
			setPath(url.path)
		}
	}

	/// 저장한 서버인데 서버 파일의 경로가 이 맥에 없으면(다른 맥 경로) 그 경로는 두고 이 맥 설정에만
	private func setPath(_ p: String) {
		if saved, let shared = server.path, !shared.isEmpty, !FileManager.default.fileExists(atPath: (shared as NSString).expandingTildeInPath) {
			UserDefaults.standard.set(p, forKey: Server.localPathKey(server.id))
			server.path = shared
			localPathBump += 1
		} else {
			UserDefaults.standard.removeObject(forKey: Server.localPathKey(server.id))
			server.path = Server.abbreviatedPath(p)
		}
		if server.name.isEmpty { server.name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
	}

	private func fields(ssh: Bool) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
				row("이름") { field($server.name, "운영 DB") }
				GridRow {
					Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
					colorDots
				}
				row("그룹") {
					HStack(spacing: 8) {
						// 남은 너비를 다 채우는 선택 칸 (SwiftUI Picker 는 너비를 안 지킨다 → PopUp)
						PopUp(selection: $server.group,
						      options: [("그룹 없음", Optional(""))] + (groupNames.isEmpty ? [] : [("", nil)]) + groupNames.map { ($0, Optional($0)) })
							.frame(maxWidth: .infinity)
						Button("그룹 추가…") { model.addGroup { server.group = $0 } }
					}
				}

				if server.isFileDB {
					sqliteRows
				} else {
				// 구분선 가운데에 접속 방식: TCP/IP · SSH (고른 것이 곧 SSH 터널 사용 여부)
				GridRow {
					HStack(spacing: 12) {
						Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
						Picker("", selection: $server.ssh.enabled) {
							Text("TCP/IP").tag(false)
							Text("SSH").tag(true)
						}
						.pickerStyle(.segmented)
						.labelsHidden()
						.fixedSize()
						Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
					}
					.gridCellColumns(2)
					.padding(.vertical, 6)
				}

				row("호스트") { field($server.host, ssh ? "127.0.0.1" : "db.example.com") }
				row("사용자") { field($server.user, "root") }
				row("비밀번호") { secret($mysqlPassword, show: $showPassword, "선택") }
				if server.sqlKind == .oracle {
					// Oracle: 서비스 이름(또는 SID)으로 붙고, "DB" 자리는 기본 스키마
					row("서비스") {
						HStack(spacing: 8) {
							field(Binding(get: { server.service ?? "" }, set: { server.service = $0.isEmpty ? nil : $0 }), "서비스 이름 (예: ORCLPDB1)")
							Picker("", selection: Binding(get: { server.oracleSID ?? false }, set: { server.oracleSID = $0 ? true : nil })) {
								Text("서비스 이름").tag(false)
								Text("SID").tag(true)
							}
							.pickerStyle(.segmented)
							.labelsHidden()
							.fixedSize()
						}
					}
					row("스키마") { field($server.database, "선택 (비우면 사용자 스키마)") }
				} else {
					row("DB") { field($server.database, "선택") }
				}
				row("포트") { number($server.port) }
				if server.sqlKind == .oracle {
					row("권한") {
						Toggle("SYSDBA 로 접속", isOn: Binding(get: { server.oracleSysDBA ?? false }, set: { server.oracleSysDBA = $0 ? true : nil }))
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				} else {
				// TLS: SSH 없이 바로 붙는 서버(RDS 등)용. SSH 터널 안에서도 서버가 TLS 를 요구하면 켠다
				row("TLS") {
					Picker("", selection: Binding(get: { server.tlsMode }, set: { server.tls = $0 == .off ? nil : $0 })) {
						ForEach(TLSMode.allCases) { Text($0.label).tag($0) }
					}
					.labelsHidden()
					.fixedSize()
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				if server.tlsMode == .verify {
					row("CA 파일") {
						HStack(spacing: 6) {
							field(Binding(get: { server.tlsCA ?? "" }, set: { server.tlsCA = $0.isEmpty ? nil : $0 }), "선택 (비우면 맥이 믿는 인증서)")
							Button("고르기…") {
								let panel = NSOpenPanel()
								panel.message = "서버 인증서를 확인할 CA 파일 (.pem · .crt)"
								guard panel.runModal() == .OK, let u = panel.url else { return }
								server.tlsCA = Server.abbreviatedPath(u.path)
							}
						}
					}
				}
				}

				if ssh {
					divider
					row("SSH 호스트") { field($server.ssh.host, "") }
					row("SSH 사용자") { field($server.ssh.user, "") }
					row("SSH 인증") {
						Picker("", selection: $server.ssh.auth) {
							ForEach(SSHAuth.allCases) { Text($0.label).tag($0) }
						}
						.pickerStyle(.segmented)
						.labelsHidden()
						.fixedSize()
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					if server.ssh.auth == .key {
						row("SSH 키") {
							HStack(spacing: 6) {
								field($server.ssh.keyPath, "선택 (비우면 SSH 기본 키 사용)")
								Button(action: pickKey) { Image(systemName: "key.fill").frame(width: 30, height: 30) }
									.buttonStyle(.plain)
									.foregroundStyle(Color.accentColor)
									.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
									.help("키 파일 고르기")
							}
						}
						row("키 암호") { secret($sshSecret, show: $showSecret, "선택") }
						GridRow {
							Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
							Text("암호로 보호된 키인 경우 비워 두면 키체인에 등록된 암호를 사용하거나, 암호 입력 창이 뜰 수 있습니다.")
								.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
						}
					} else {
						row("SSH 비밀번호") { secret($sshSecret, show: $showSecret, "") }
					}
					row("SSH 포트") { number($server.ssh.port) }
				}
				// 접속 허용 IP: 이 맥이 그 IP 가 아니면 접속하지 않고 VPN 을 켜라고 안내 (비면 검사 안 함)
				divider
				row("허용 IP") {
					field(Binding(get: { allowedText },
					              set: { allowedText = $0; let l = NetworkAccess.parseList($0); server.allowedIPs = l.isEmpty ? nil : l }),
					      "선택 (예: 203.0.113.10, 10.0.0.0/8)")
				}
				GridRow {
					Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
					Text("이 DB 에 들어갈 수 있는 이 맥의 IP. 적어 두면 접속 전에 확인하고, 아니면 VPN 을 켜라고 알려 줍니다. 비우면 확인하지 않습니다.")
						.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
				}
			}

			if !testSteps.isEmpty {
				Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1).padding(.vertical, 14)
				VStack(alignment: .leading, spacing: 6) {
					ForEach(testSteps) { step in
						HStack(alignment: .top, spacing: 8) {
							Group {
								if let ok = step.ok {
									Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
								} else {
									ProgressView().controlSize(.small)
								}
							}
							.frame(width: 16)
							Text(step.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
							// 진행 중인 줄 옆: 접속 시험 중단 (사용자 2026-11-19)
							if step.ok == nil && testing {
								Button(action: cancelTest) {
									Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
								}
								.buttonStyle(.plain)
								.help("접속 시험 중단")
							}
						}
					}
				}
				.font(.callout)
			}
		}
		.padding(20)
	}

	/// SSH 를 쓰면 호스트·사용자는 필수 (~/.ssh/config 별칭은 쓰지 않는다, 사용자 2026-11-18)
	private var missingSSH: Bool {
		server.ssh.enabled && (server.ssh.host.trimmingCharacters(in: .whitespaces).isEmpty || server.ssh.user.trimmingCharacters(in: .whitespaces).isEmpty)
	}

	private var buttons: some View {
		HStack(spacing: 10) {
			Button(action: test) { Label("접속 시험", systemImage: "bolt.horizontal") }
				.disabled(testing || missingSSH)
			Spacer()
			if savedFlash {
				Label("저장됨", systemImage: "checkmark").foregroundStyle(.green).transition(.opacity)
			}
			Button(saved ? "저장" : "목록에 저장", action: save)
				.keyboardShortcut("s")
				.disabled(missingSSH)
			Button(action: connect) { Text("접속").frame(width: 110) }
				.keyboardShortcut(.defaultAction)
				.buttonStyle(.borderedProminent)
				.disabled(missingSSH)
		}
		.help(missingSSH ? "SSH 호스트와 SSH 사용자를 입력하세요" : "")
		.controlSize(.large)
	}

	private var divider: some View {
		GridRow {
			Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1).gridCellColumns(2).padding(.vertical, 4)
		}
	}

	private var colorDots: some View {
		HStack(spacing: 10) {
			ForEach(ServerColor.allCases) { c in
				Button { server.color = c } label: {
					ZStack {
						if let col = c.swiftUI {
							Circle().fill(col.opacity(0.85)).frame(width: 18, height: 18)
						} else {
							Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 18, height: 18)
						}
						if server.color == c {
							Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 24, height: 24)
						}
					}
					.frame(width: 24, height: 24)
					.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.help(c.label)
			}
		}
	}

	private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
		GridRow {
			Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
			content()
		}
	}

	private func box<C: View>(_ c: C) -> some View {
		c.textFieldStyle(.plain)
			.padding(.horizontal, 9)
			.frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
	}

	private func field(_ text: Binding<String>, _ prompt: String) -> some View {
		box(TextField("", text: text, prompt: Text(prompt)))
	}

	private func number(_ value: Binding<Int>) -> some View {
		box(TextField("", value: value, format: .number.grouping(.never)))
	}

	private func secret(_ text: Binding<String>, show: Binding<Bool>, _ prompt: String) -> some View {
		box(HStack(spacing: 6) {
			if show.wrappedValue { TextField("", text: text, prompt: Text(prompt)) }
			else { PasswordField(placeholder: prompt, text: text, bordered: false) }
			Button { show.wrappedValue.toggle() } label: {
				Image(systemName: show.wrappedValue ? "eye.slash" : "eye").foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
			.help(show.wrappedValue ? "가리기" : "보기")
		})
	}

	private func connect() {
		model.open(server, mysqlPassword: mysqlPassword, sshSecret: server.ssh.enabled ? sshSecret : nil, given: true)
	}

	/// 저장. 목록의 서버인데 이름을 바꿨으면 먼저 묻는다 (사용자 2026-11-19):
	/// [예] = 바꾼 내용으로 새 서버 등록(원래 서버는 그대로), [아니오] = 그 서버 이름 바꾸기, [취소] = 저장 안 함
	private func save() {
		guard saved, let original = store.servers.first(where: { $0.id == server.id }),
		      original.name.trimmingCharacters(in: .whitespaces) != server.name.trimmingCharacters(in: .whitespaces) else {
			persist(server)
			return
		}
		Task {
			switch await Confirm.ask("이름이 변경되었습니다.\n새로운 서버로 등록하시겠습니까?",
			                         "[아니오] 를 누르면 ‘\(original.displayName)’ 의 이름을 바꿉니다.",
			                         buttons: ["예", "아니오"]) {
			case 0:
				var copy = server
				copy.id = UUID()
				copy.order = nil
				persist(copy, asNew: true)
			case 1:
				persist(server)
			default:
				break
			}
		}
	}

	/// 서버 파일·키체인에 저장. asNew: 목록 서버를 고치다 새 서버로 등록 → 새 서버를 고른다 (원래 서버는 그대로)
	private func persist(_ server: Server, asNew: Bool = false) {
		Keychain.set(mysqlPassword, for: server.mysqlPasswordKey)
		Keychain.set(server.ssh.enabled ? sshSecret : nil, for: server.sshSecretKey)
		store.save(server)
		if !saved || asNew {
			// 저장하면 목록에서 고른 상태가 되고, 새 접속 칸은 비운다
			model.draft = Server()
			model.selectedServerID = server.id
		} else {
			withAnimation { savedFlash = true }
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { savedFlash = false } }
		}
	}

	private func pickKey() {
		let panel = NSOpenPanel()
		panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
		panel.showsHiddenFiles = true
		panel.canChooseDirectories = false
		panel.message = "SSH 개인 키 파일을 고르세요 (.pub 가 아닌 파일)"
		if panel.runModal() == .OK, let url = panel.url {
			let home = FileManager.default.homeDirectoryForCurrentUser.path
			server.ssh.keyPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
		}
	}

	/// 접속 시험 중단: 화면은 바로 끝내고, 아직 열리는 중인 터널·연결은 끝나는 대로 닫는다 (막힌 소켓은 밖에서 끊을 수 없어서)
	private func cancelTest() {
		testRun += 1
		testing = false
		if let i = testSteps.indices.last, testSteps[i].ok == nil { testSteps[i].ok = false }
		testSteps.append(.init(ok: false, text: "접속 시험을 중단했습니다"))
	}

	private func test() {
		testRun += 1
		let run = testRun
		testing = true
		testSteps = []
		let s = server
		let mysqlPw = mysqlPassword
		let sshPw = s.ssh.enabled ? sshSecret : nil
		Task { @MainActor in
			defer { if run == testRun { testing = false } }
			do {
				let (tunnel, conn) = try await Session.open(s, mysqlPassword: mysqlPw, sshSecret: sshPw) { step in
					guard run == testRun else { return }
					if let i = testSteps.indices.last, testSteps[i].ok == nil { testSteps[i].ok = true }
					testSteps.append(.init(ok: nil, text: step))
				}
				// 중단한 뒤에 열렸으면 닫고 끝
				guard run == testRun else { conn.close(); tunnel?.close(); return }
				if s.ssh.enabled, let t = tunnel { testSteps[0].text = "SSH 터널 열림 (\(s.ssh.host) → 이 맥 \(t.localPort) 포트)" }
				// MySQL·MariaDB 는 버전을 보고 종류를 맞춘다 (저장하면 그 종류로)
				let detected = s.sqlKind?.detected(fromVersion: conn.serverVersion) ?? s.sqlKind
				if let detected, detected != server.sqlKind { server.kind = detected.rawValue }
				let info = try await (detected ?? .mysql).meta.connectionInfo { try await conn.query($0) }
				guard run == testRun else { conn.close(); tunnel?.close(); return }
				testSteps[testSteps.count - 1] = .init(ok: true, text: "\(detected?.label ?? s.kindLabel) 로그인 성공: \(info.user ?? s.user), 서버 \(info.version ?? conn.serverVersion), DB \(info.databases ?? "?")개" + (conn.tlsSummary.map { ", \($0)" } ?? ""))
				conn.close()
				tunnel?.close()
			} catch {
				guard run == testRun else { return }
				if let i = testSteps.indices.last, testSteps[i].ok == nil { testSteps[i].ok = false }
				testSteps.append(.init(ok: false, text: error.localizedDescription))
			}
		}
	}
}

extension Array {
	subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


