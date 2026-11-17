import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 서버 내보내기·가져오기 요청 (메뉴 막대 파일 메뉴, .isql 더블클릭)
enum ServerTransferRequest: Identifiable {
	case export
	case importFile(URL?)
	var id: String {
		switch self {
		case .export: "export"
		case .importFile(let u): "import:" + (u?.path ?? "")
		}
	}
}

/// 창에 서버 내보내기·가져오기 시트와 파일 열기(.isql 더블클릭)를 붙인다 (ContentView 본문 식이 길어 따로)
struct ServerTransferHost: ViewModifier {
	@Bindable var model: WindowModel
	@Environment(ServerStore.self) private var store

	func body(content: Content) -> some View {
		content
			.sheet(item: $model.transfer) { req in
				switch req {
				case .export: ExportServersSheet(store: store)
				case .importFile(let url): ImportServersSheet(store: store, initialURL: url)
				}
			}
			// Finder 에서 .isql 을 두 번 누르면 이 창에 가져오기 시트 (파일이 미리 들어간 채)
			.onOpenURL { url in
				if url.isFileURL { model.transfer = .importFile(url) }
			}
			// 파일을 열 때 새 창을 만들지 않고 열려 있는 창이 받는다
			.handlesExternalEvents(preferring: ["*"], allowing: ["*"])
	}
}

// MARK: - 내보내기

/// 서버 정보 내보내기: 서버 고르기(여러 개) + 암호 → 저장 위치. SSH 키 파일은 같이, 키의 암호는 빼고
struct ExportServersSheet: View {
	let store: ServerStore
	@Environment(\.dismiss) private var dismiss
	@State private var picked: Set<UUID>
	@State private var password = ""
	@State private var confirm = ""
	@State private var result: (ok: Bool, text: String)?
	/// 서버 고르기 목록 한 줄 높이
	static let rowHeight: CGFloat = 26

	init(store: ServerStore) {
		self.store = store
		_picked = State(initialValue: Set(store.servers.map(\.id)))
	}

	private var canExport: Bool { !picked.isEmpty && password.count >= 4 && password == confirm }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("서버 정보 내보내기").font(.headline)
			HStack {
				Text("내보낼 서버 \(picked.count) / \(store.servers.count)개").foregroundStyle(.secondary).monospacedDigit()
				Spacer()
				Button("모두 선택") { picked = Set(store.servers.map(\.id)) }
				Button("모두 해제") { picked = [] }.disabled(picked.isEmpty)
			}
			.buttonStyle(.link)
			ScrollView {
				// 줄 높이는 모두 같게 (그룹 줄·서버 줄, 키 아이콘 있는 줄)
				VStack(alignment: .leading, spacing: 0) {
					ForEach(store.grouped, id: \.group) { g in
						if !g.group.isEmpty {
							let ids = Set(g.servers.map(\.id))
							Toggle(isOn: Binding(get: { !ids.isEmpty && ids.isSubset(of: picked) },
							                     set: { on in if on { picked.formUnion(ids) } else { picked.subtract(ids) } })) {
								Label(g.group, systemImage: "folder").fontWeight(.semibold)
							}
							.frame(height: Self.rowHeight)
						}
						ForEach(g.servers) { s in
							Toggle(isOn: Binding(get: { picked.contains(s.id) },
							                     set: { on in if on { picked.insert(s.id) } else { picked.remove(s.id) } })) {
								HStack(spacing: 6) {
									Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 8, height: 8)
									Text(s.displayName)
									Text(s.subtitle).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
									if s.ssh.enabled && s.ssh.auth == .key && !s.ssh.keyPath.isEmpty {
										Image(systemName: "key").foregroundStyle(.secondary).help("SSH 키 파일도 함께: \(s.ssh.keyPath)")
									}
								}
							}
							.frame(height: Self.rowHeight)
							.padding(.leading, g.group.isEmpty ? 0 : 20)
						}
					}
				}
				.toggleStyle(.checkbox)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(height: 240)
			.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					Text("암호").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
					PasswordField(placeholder: "가져올 때 넣을 암호 (4자 이상)", text: $password)
				}
				GridRow {
					Text("암호 확인").foregroundStyle(.secondary)
					PasswordField(text: $confirm)
				}
			}
			if !confirm.isEmpty && password != confirm {
				Label("암호가 서로 다릅니다", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
			}
			if let r = result {
				Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
					.foregroundStyle(r.ok ? Color.green : Color.red).font(.callout).textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Spacer()
				Button(result?.ok == true ? "닫기" : "취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("내보내기…", action: export)
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled(!canExport)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 560)
	}

	private func export() {
		let servers = ServerStore.sorted(store.servers.filter { picked.contains($0.id) })
		do {
			let (payload, warnings) = try ServerTransfer.payload(servers)
			let data = try ServerTransfer.seal(payload, password: password)
			let panel = NSSavePanel()
			panel.allowedContentTypes = [.isqlServers]
			panel.nameFieldStringValue = servers.count == 1 ? servers[0].displayName + ".isql" : "iSQL 서버 \(servers.count)개.isql"
			panel.canCreateDirectories = true
			guard panel.runModal() == .OK, let url = panel.url else { return }
			try data.write(to: url, options: .atomic)
			result = (true, "\(servers.count)개 서버를 내보냈습니다: \(url.lastPathComponent)" + (warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")))
		} catch {
			result = (false, error.localizedDescription)
		}
	}
}

// MARK: - 가져오기

/// 서버 설정 가져오기: 파일 고르기(두 번 눌러 열었으면 미리 들어감) + 암호 → 서버 목록 보고 고르기 → 가져오기.
/// .isql 이 아니면 다른 앱에서 내보낸 파일 (나중에 지원)
struct ImportServersSheet: View {
	let store: ServerStore
	@Environment(\.dismiss) private var dismiss
	@State private var url: URL?
	@State private var password = ""
	@State private var payload: ServerTransfer.Payload?
	@State private var picked: Set<UUID> = []
	@State private var passphrases: [UUID: String] = [:]
	@State private var failure: String?
	@State private var done: String?
	@State private var passwordFocused = false
	/// 다른 앱 파일이면 그 앱 이름 (Sequel Ace), 가져오지 못한 것
	@State private var source: String?
	@State private var skipped: [String] = []

	init(store: ServerStore, initialURL: URL?) {
		self.store = store
		_url = State(initialValue: initialURL)
	}

	private var isISQL: Bool { url?.pathExtension.lowercased() == "isql" }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("서버 설정 가져오기").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
				GridRow {
					Text("파일").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
					HStack {
						// 입력칸처럼 보이는 경로 상자 (고치지는 못하고 "선택…" 으로만 바꾼다)
						Text(url?.path ?? "파일을 고르세요")
							.foregroundStyle(url == nil ? .tertiary : .primary)
							.lineLimit(1).truncationMode(.middle)
							.padding(.horizontal, 8)
							.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
							.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
							.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
						Button("선택…", action: choose)
					}
				}
				// 암호는 iSQL 파일(.isql)일 때만 (다른 앱 파일은 암호 없이 바로 목록)
				if isISQL {
					GridRow {
						Text("암호").foregroundStyle(.secondary)
						PasswordField(placeholder: "내보낼 때 넣은 암호", text: $password, focus: $passwordFocused, onSubmit: open)
							.disabled(payload != nil)
					}
				}
			}
			if let p = payload { serverList(p) }
			if let f = failure {
				Label(f, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
			}
			if let d = done {
				Label(d, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
			}
			HStack {
				Spacer()
				Button(done != nil ? "닫기" : "취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				// 처음엔 "확인"(암호로 파일 열기), 열리면 목록이 보이고 "가져오기"
				if done == nil {
					if payload == nil {
						Button("확인", action: open)
							.buttonStyle(.borderedProminent)
							.keyboardShortcut(.defaultAction)
							.disabled(!isISQL || password.isEmpty)
					} else {
						Button("가져오기", action: apply)
							.buttonStyle(.borderedProminent)
							.keyboardShortcut(.defaultAction)
							.disabled(picked.isEmpty)
					}
				}
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 600)
		.onAppear { fileChanged() }
	}

	@ViewBuilder private func serverList(_ p: ServerTransfer.Payload) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if let source {
				Text("\(source) 접속 \(p.servers.count)개 · 비밀번호는 들어 있지 않아 처음 접속할 때 묻습니다")
					.font(.callout).foregroundStyle(.secondary)
			} else {
				Text("\(p.servers.count)개 서버 · \(p.exported.formatted(date: .abbreviated, time: .shortened)) 에 내보냄")
					.font(.callout).foregroundStyle(.secondary)
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(p.servers) { item in row(item) }
				}
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: 280)
			.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
			ForEach(skipped, id: \.self) { t in
				Label(t, systemImage: "minus.circle").font(.callout).foregroundStyle(.secondary)
			}
		}
	}

	private func row(_ item: ServerTransfer.Item) -> some View {
		let s = item.server
		let exists = store.servers.contains { $0.id == s.id }
		return VStack(alignment: .leading, spacing: 4) {
			Toggle(isOn: Binding(get: { picked.contains(s.id) }, set: { on in if on { picked.insert(s.id) } else { picked.remove(s.id) } })) {
				HStack(spacing: 6) {
					Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 8, height: 8)
					Text(s.displayName).fontWeight(.medium)
					Text(exists ? "이미 있음 — 덮어씀" : "새 서버").font(.caption).foregroundStyle(exists ? .orange : .green)
				}
			}
			.toggleStyle(.checkbox)
			Group {
				Text(s.subtitle).foregroundStyle(.secondary)
				if let k = item.sshKey {
					let have = ServerTransfer.existingKey(k)
					if let have {
						Label("SSH 키: 이 맥에 있는 같은 키를 씀 (\(have))", systemImage: "key")
					} else {
						Label("SSH 키: ~/.ssh 에 \(k.fileName) 로 저장", systemImage: "key")
					}
					// 이 맥에 이미 있는 키면 키 암호도 이미 쓰고 있을 테니 묻지 않는다 (사용자)
					if k.encrypted && have == nil {
						HStack {
							Text("키 암호").foregroundStyle(.secondary)
							PasswordField(placeholder: "선택 — 넣으면 이 맥 키체인에 저장", text: Binding(get: { passphrases[s.id] ?? "" }, set: { passphrases[s.id] = $0 }))
						}
					}
				}
				// 다른 앱 파일: 키 파일은 경로만 있다 → 이 맥에 있는지
				if item.sshKey == nil, s.ssh.enabled, s.ssh.auth == .key, !s.ssh.keyPath.isEmpty {
					if FileManager.default.fileExists(atPath: (s.ssh.keyPath as NSString).expandingTildeInPath) {
						Label("SSH 키: \(s.ssh.keyPath)", systemImage: "key")
					} else {
						Label("SSH 키 \(s.ssh.keyPath) 가 이 맥에 없습니다", systemImage: "key").foregroundStyle(.orange)
					}
				}
				if item.mysqlPassword == nil && source == nil { Text("MySQL 비밀번호 없음 — 접속할 때 묻습니다").foregroundStyle(.orange) }
			}
			.font(.callout)
			.padding(.leading, 22)
		}
	}

	private func choose() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.isqlServers, .data]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let u = panel.url else { return }
		url = u
		password = ""
		fileChanged()
	}

	/// 파일이 정해졌을 때: .isql 이면 암호 칸에 포커스, 다른 앱 파일이면 바로 읽어 목록
	private func fileChanged() {
		payload = nil
		source = nil
		skipped = []
		failure = nil
		done = nil
		guard let url else { return }
		if isISQL { passwordFocused = true; return }
		do {
			let r = try OtherAppImport.read(url, existing: store.servers)
			var p = ServerTransfer.Payload()
			p.servers = r.items
			payload = p
			source = r.app
			skipped = r.skipped
			// 새 접속만 체크 (이미 있는 서버는 덮어쓸지 사용자가 고른다)
			let have = Set(store.servers.map(\.id))
			picked = Set(r.items.map(\.id).filter { !have.contains($0) })
		} catch {
			failure = error.localizedDescription
		}
	}

	private func open() {
		// 엔터(암호 칸)와 확인 단추가 같이 불려도 한 번만
		guard let url, isISQL, !password.isEmpty, payload == nil else { return }
		failure = nil
		do {
			let data = try Data(contentsOf: url)
			let p = try ServerTransfer.open(data, password: password)
			payload = p
			picked = Set(p.servers.map(\.id))
		} catch {
			failure = error.localizedDescription
		}
	}

	private func apply() {
		guard let p = payload else { return }
		let items = p.servers.filter { picked.contains($0.id) }
		do {
			try ServerTransfer.apply(items, store: store, keyPassphrases: passphrases)
			done = "\(items.count)개 서버를 가져왔습니다"
			failure = nil
		} catch {
			failure = error.localizedDescription
		}
	}
}
