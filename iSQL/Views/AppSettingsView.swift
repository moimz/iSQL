import SwiftUI
import AppKit

/// iSQL 앱 설정 (⌘,, Settings 장면). 서버별 설정은 제목바 톱니 → ServerSettingsWindow.
/// 맥 설정창 규칙대로 폭은 탭마다 같고 높이만 바뀐다
struct AppSettingsView: View {
	static let width: CGFloat = 680
	@AppStorage("appSettingsTab") private var tab = "general"

	var body: some View {
		TabView(selection: $tab) {
			Tab("일반", systemImage: "gearshape", value: "general") {
				AppGeneralPage().frame(width: Self.width, height: 530)
			}
			Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted", value: "mcp") {
				MCPSettingsPage().frame(width: Self.width, height: 700)
			}
		}
		.background(SettingsWindowStyler())
	}
}

/// 앱 설정 > 일반 (앱 전역 설정은 차례로 들어간다)
private struct AppGeneralPage: View {
	@AppStorage(AutoConnect.reconnectKey) private var reconnectLast = false
	private var version: String {
		let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
		return "\(v) (\(b))"
	}

	var body: some View {
		Form {
			Section {
				Toggle("앱 실행 시 마지막 세션 복원", isOn: $reconnectLast)
			} footer: {
				Text("앱 실행 시 마지막 세션에서 접속 중인 모든 서버에 자동으로 접속합니다. (단, 앱 실행 시 자동 접속 설정이 된 서버는 마지막 세션 상태와 무관하게 접속합니다.)").foregroundStyle(.tertiary)
			}
			TimeZoneSection()
			FileAssociationSection()
			UpdateSection(version: version)
		}
		.formStyle(.grouped)
	}
}

/// 앱 설정 > 일반 > 시간 표시: 날짜로 보는 컬럼(유닉스 시간)과 Oracle 의 시간대 붙은 값을 이 시간대로 (사용자 2026-11-20)
private struct TimeZoneSection: View {
	@AppStorage(DisplayTime.key) private var zone = ""

	var body: some View {
		Section {
			Picker("시간대", selection: $zone) {
				Text("시스템 시간대 사용 (\(TimeZone.current.identifier))").tag("")
				Divider()
				ForEach(DisplayTime.choices, id: \.self) { Text($0).tag($0) }
			}
		} header: {
			Text("시간 표시")
		} footer: {
			Text("컬럼을 날짜로 볼 때(유닉스 시간)와 Oracle 의 시간대가 붙은 값을 이 시간대로 보여 줍니다. 서버에 저장된 값은 바뀌지 않습니다.").foregroundStyle(.tertiary)
		}
	}
}

/// 앱 설정 > 일반 > 업데이트: 지금 버전, 자동 확인 켜기/끄기, 지금 확인 (Updater · Sparkle)
private struct UpdateSection: View {
	let version: String
	@Bindable private var updater = Updater.shared

	var body: some View {
		Section {
			LabeledContent("버전") {
				HStack(spacing: 8) {
					Text(version).foregroundStyle(.secondary).monospacedDigit()
					Button("업데이트 확인…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
				}
			}
			Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
		} header: {
			Text("업데이트")
		} footer: {
			Text("하루에 한 번 새 버전이 있는지 확인하고, 있으면 설치할지 묻습니다.").foregroundStyle(.tertiary)
		}
	}
}

/// 앱 설정 > 일반 > 파일 연결: SQLite 파일을 두 번 눌렀을 때 iSQL 로 열지 (.isql 은 늘 iSQL 이라 없다)
private struct FileAssociationSection: View {
	@State private var appName = ""
	@State private var isDefault = false
	@State private var error: String?

	var body: some View {
		Section {
			LabeledContent("SQLite 파일 (.sqlite · .db …)") {
				HStack(spacing: 8) {
					Text(appName).foregroundStyle(.secondary)
					Button("iSQL 을 기본 앱으로") { makeDefault() }.disabled(isDefault)
				}
			}
		} header: {
			Text("파일 연결")
		} footer: {
			Text(error ?? "Finder 의 \"다음으로 열기\" 에는 늘 iSQL 이 있습니다. 기본 앱으로 정하면 두 번 눌러 iSQL 로 엽니다.")
				.foregroundStyle(error == nil ? .tertiary : .secondary)
		}
		.onAppear(perform: refresh)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
	}

	private func refresh() {
		isDefault = SQLiteFile.isDefaultApp
		appName = isDefault ? "iSQL" : SQLiteFile.defaultApp.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "없음"
	}

	private func makeDefault() {
		Task {
			do { try await SQLiteFile.makeDefault(); error = nil } catch { self.error = "바꾸지 못했습니다: \(error.localizedDescription)" }
			refresh()
		}
	}
}

/// 앱 설정 > MCP: Claude 같은 AI 도구가 iSQL 로 DB 를 보게 하는 로컬 서버
private struct MCPSettingsPage: View {
	@Bindable private var mcp = MCPServer.shared
	@State private var portText = String(MCPServer.shared.port)

	private var claudeCommand: String { "claude mcp add --transport http isql \(mcp.endpoint)" }

	var body: some View {
		Form {
			// iVNC 와 같은 모양 (Ai.md "MCP 설정 화면"): 켜기 · 포트 · 상태 · 주소 복사 · 연결 명령 복사를 한 칸에 (2026-11-21 사용자 지시)
			Section {
				Toggle("MCP 서버 켜기", isOn: $mcp.enabled)
				LabeledContent("포트") {
					TextField("포트", text: $portText)
						.labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
						.onSubmit(applyPort)
				}
				LabeledContent("상태") {
					switch mcp.status {
					case .stopped: Text("꺼짐").foregroundStyle(.secondary)
					case .running(let p): Label("듣는 중 (127.0.0.1:\(String(p)))", systemImage: "circle.fill").foregroundStyle(.green)
					case .failed(let e): Text("열지 못했습니다: \(e)").foregroundStyle(.red)
					}
				}
				LabeledContent("주소") {
					// 오른쪽 끝을 아래 "연결 명령 복사" 버튼과 맞춘다
					HStack(spacing: 8) {
						Text(mcp.endpoint).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(1).fixedSize()
						Button("복사") { copy(mcp.endpoint) }
					}
					.frame(maxWidth: .infinity, alignment: .trailing)
				}
				LabeledContent("Claude Code") {
					Button("연결 명령 복사") { copy(claudeCommand) }
				}
			} footer: {
				Text("이 맥 안(127.0.0.1)에서만 받습니다. 암호는 MCP 로 넘기지 않습니다.")
			}

			Section("접근 범위") {
				Picker("", selection: $mcp.scope) {
					ForEach(MCPScope.allCases) { s in Text(s.label).tag(s) }
				}
				.pickerStyle(.radioGroup)
				.labelsHidden()
				Text(scopeHelp).font(.callout).foregroundStyle(.secondary)
			}

			Section("쿼리 권한") {
				Picker("", selection: $mcp.permission) {
					ForEach(MCPPermission.allCases) { p in
						VStack(alignment: .leading, spacing: 1) {
							Text(p.label)
							Text(p.detail).font(.caption).foregroundStyle(.secondary)
						}
						.tag(p)
					}
				}
				.pickerStyle(.radioGroup)
				.labelsHidden()
			}

			Section("최근 요청") {
				if mcp.log.isEmpty {
					Text("아직 없음").foregroundStyle(.secondary)
				}
				ForEach(mcp.log.prefix(8)) { e in
					HStack(spacing: 8) {
						Image(systemName: e.ok ? "checkmark.circle" : "xmark.octagon").foregroundStyle(e.ok ? Color.secondary : Color.orange)
						Text(e.text).lineLimit(1).truncationMode(.tail)
						Spacer()
						Text(e.time, style: .time).foregroundStyle(.tertiary).monospacedDigit()
					}
					.font(.callout)
				}
			}
		}
		.formStyle(.grouped)
	}

	private var scopeHelp: String {
		switch mcp.scope {
		case .active: "현재 iSQL에서 보고 있는 서버만 접근 가능합니다. 서버 변경 시 접근 가능한 서버가 자동으로 변경됩니다."
		case .connected: "현재 iSQL에서 접속하고 있는 모든 서버에 접근 가능합니다."
		case .all: "서버 목록의 모든 서버에 접근 가능합니다. 아직 접속하지 않은 서버는 필요에 따라 자동으로 접속합니다."
		}
	}

	private func applyPort() {
		if let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) {
			mcp.port = p
		} else {
			NSSound.beep()
			portText = String(mcp.port)
		}
	}

	private func copy(_ s: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(s, forType: .string)
	}
}
