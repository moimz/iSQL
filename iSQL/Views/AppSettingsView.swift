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
				AppGeneralPage().frame(width: Self.width, height: 260)
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
	private var version: String {
		let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
		return "\(v) (\(b))"
	}

	var body: some View {
		Form {
			Section {
				LabeledContent("버전", value: version)
			} footer: {
				Text("서버마다 다른 설정은 접속한 창 제목바의 톱니(서버 설정)에 있습니다.").foregroundStyle(.tertiary)
			}
		}
		.formStyle(.grouped)
	}
}

/// 앱 설정 > MCP: Claude 같은 AI 도구가 iSQL 로 DB 를 보게 하는 로컬 서버
private struct MCPSettingsPage: View {
	@Bindable private var mcp = MCPServer.shared
	@State private var portText = String(MCPServer.shared.port)

	private var claudeCommand: String { "claude mcp add --transport http isql \(mcp.endpoint)" }

	var body: some View {
		Form {
			Section {
				Toggle(isOn: $mcp.enabled) {
					Text("MCP 서버 켜기")
					Text("이 맥에서만 (127.0.0.1) 받습니다")
				}
				statusLine
				LabeledContent("포트") {
					TextField("", text: $portText)
						.frame(width: 90)
						.multilineTextAlignment(.trailing)
						.onSubmit(applyPort)
				}
			} header: {
				Text("서버")
			} footer: {
				Text("기본 8766 (Sequel Ace 는 8765). 1024~65535, 엔터로 적용").foregroundStyle(.tertiary)
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

			Section("연결") {
				copyRow("주소", mcp.endpoint)
				copyRow("Claude Code", claudeCommand)
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
		case .active: "앞에 있는 iSQL 창에서 보고 있는 서버 하나만 열립니다. 창이나 서버를 바꾸면 따라 바뀝니다."
		case .connected: "iSQL 에서 지금 접속해 있는 서버들만 열립니다."
		case .all: "서버 목록의 모든 서버가 열립니다. 접속하지 않은 서버는 키체인 비밀번호로 iSQL 이 따로 접속합니다."
		}
	}

	@ViewBuilder private var statusLine: some View {
		switch mcp.status {
		case .running(let p):
			// 포트는 숫자 서식(8,799) 없이
			Label("\(String(p)) 포트에서 받는 중 — \(mcp.endpoint)", systemImage: "circle.fill")
				.foregroundStyle(.green).font(.callout)
		case .failed(let e):
			Label("열지 못했습니다: \(e)", systemImage: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange).font(.callout)
		case .stopped:
			Label("꺼짐", systemImage: "circle").foregroundStyle(.secondary).font(.callout)
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

	private func copyRow(_ label: String, _ value: String) -> some View {
		LabeledContent(label) {
			HStack(spacing: 8) {
				Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
				Button("복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(value, forType: .string)
				}
			}
		}
	}
}
