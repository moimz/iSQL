import SwiftUI

/// 설정 창이 보여 줄 서버 (창마다 접속이 따로라, 톱니를 누른·서버를 고른 창의 세션)
@Observable
final class SettingsTarget {
	static let shared = SettingsTarget()
	weak var session: Session?
}

/// 서버 설정 창 (Settings 장면). 맥 설정창처럼 위에 아이콘 탭: 일반 / 사용자 계정 (내용은 차차 채운다)
struct ServerSettingsView: View {
	private var target = SettingsTarget.shared

	var body: some View {
		TabView {
			Tab("일반", systemImage: "gearshape") { page { general($0) } }
			Tab("사용자 계정", systemImage: "person.2") { page { accounts($0) } }
		}
		.frame(width: 640, height: 420)
	}

	/// 접속한 서버가 없으면 안내
	@ViewBuilder private func page<C: View>(@ViewBuilder _ content: (Session) -> C) -> some View {
		if let s = target.session, s.isConnected {
			content(s)
		} else {
			ContentUnavailableView("접속한 서버가 없습니다", systemImage: "cylinder.split.1x2",
			                       description: Text("서버에 접속한 뒤 제목바의 톱니를 누르세요."))
		}
	}

	// MARK: 일반

	private func general(_ session: Session) -> some View {
		Form {
			Section {
				if let s = session.server {
					LabeledContent("서버") {
						HStack(spacing: 6) {
							Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 8, height: 8)
							Text(s.displayName)
						}
					}
					LabeledContent("접속", value: s.subtitle)
				}
				if !session.serverVersion.isEmpty { LabeledContent("서버 버전", value: session.serverVersion) }
				LabeledContent("데이터베이스", value: "\(session.databases.count.formatted())개 · 테이블 \(session.tables.count.formatted())개")
			} footer: {
				Text("서버별 설정 항목은 여기에 차례로 들어갑니다.").foregroundStyle(.tertiary)
			}
		}
		.formStyle(.grouped)
	}

	// MARK: 사용자 계정

	private func accounts(_ session: Session) -> some View {
		ContentUnavailableView("사용자 계정", systemImage: "person.2",
		                       description: Text("\(session.server?.displayName ?? "이 서버")의 MySQL 사용자와 권한 관리는 준비 중입니다."))
	}
}
