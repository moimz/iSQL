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
			.id(saved?.id.uuidString ?? "draft")
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
	@State private var savedFlash = false

	struct TestStep: Identifiable {
		let id = UUID()
		var ok: Bool?
		var text: String
	}

	init(model: WindowModel, initial: Server, saved: Bool) {
		self.model = model
		self.saved = saved
		_server = State(initialValue: initial)
	}

	@State private var showPassword = false
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

	/// 상자: 위 가장자리에 걸친 TCP/IP · SSH 전환 + 라벨 오른쪽 정렬 입력칸
	/// 애플 기본 TabView (박스 위에 탭이 걸친 모양): TCP/IP · SSH. 고른 탭이 곧 SSH 터널 사용 여부
	private var card: some View {
		TabView(selection: $server.ssh.enabled) {
			fields(ssh: false).tabItem { Text("TCP/IP") }.tag(false)
			fields(ssh: true).tabItem { Text("SSH") }.tag(true)
		}
		// TabView 는 세로로 남는 공간을 다 차지한다 → 내용 높이에 맞춘다 (박스가 화면 끝까지 늘어나 입력칸이 가운데 떠 있었다)
		.fixedSize(horizontal: false, vertical: true)
	}

	private var groupNames: [String] { store.grouped.map(\.group).filter { !$0.isEmpty } }

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

				divider

				row("\(server.sqlKind?.familyLabel ?? server.kindLabel) 호스트") { field($server.host, ssh ? "127.0.0.1" : "db.example.com") }
				row("사용자") { field($server.user, "root") }
				row("비밀번호") { secret($mysqlPassword, show: $showPassword, "선택") }
				row("DB") { field($server.database, "선택") }
				row("포트") { number($server.port) }

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

	private func save() {
		Keychain.set(mysqlPassword, for: server.mysqlPasswordKey)
		Keychain.set(server.ssh.enabled ? sshSecret : nil, for: server.sshSecretKey)
		store.save(server)
		if !saved {
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

	private func test() {
		testing = true
		testSteps = []
		let s = server
		let mysqlPw = mysqlPassword
		let sshPw = s.ssh.enabled ? sshSecret : nil
		Task { @MainActor in
			defer { testing = false }
			do {
				let (tunnel, conn) = try await Session.open(s, mysqlPassword: mysqlPw, sshSecret: sshPw) { step in
					if let i = testSteps.indices.last, testSteps[i].ok == nil { testSteps[i].ok = true }
					testSteps.append(.init(ok: nil, text: step))
				}
				if s.ssh.enabled, let t = tunnel { testSteps[0].text = "SSH 터널 열림 (\(s.ssh.host) → 이 맥 \(t.localPort) 포트)" }
				// MySQL·MariaDB 는 버전을 보고 종류를 맞춘다 (저장하면 그 종류로)
				let detected = s.sqlKind?.detected(fromVersion: conn.serverVersion) ?? s.sqlKind
				if let detected, detected != server.sqlKind { server.kind = detected.rawValue }
				let info = try await (detected ?? .mysql).meta.connectionInfo { try await conn.query($0) }
				testSteps[testSteps.count - 1] = .init(ok: true, text: "\(detected?.label ?? s.kindLabel) 로그인 성공: \(info.user ?? s.user), 서버 \(info.version ?? conn.serverVersion), DB \(info.databases ?? "?")개")
				conn.close()
				tunnel?.close()
			} catch {
				if let i = testSteps.indices.last, testSteps[i].ok == nil { testSteps[i].ok = false }
				testSteps.append(.init(ok: false, text: error.localizedDescription))
			}
		}
	}
}

extension Array {
	subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


