import SwiftUI
import AppKit

/// iSQL 정보 창 (메뉴 iSQL > iSQL에 관하여). macOS 기본 정보 창은 글 영역이 창 가로를 꽉 채워
/// 여백·둥근 상자를 줄 수 없어서 직접 만든다 (사용자 2026-11-20). 글이 길면 상자 안에서 스크롤
struct AboutView: View {
	static let windowID = "about"

	private var version: String {
		let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
		return "버전 \(v) (\(b))"
	}

	var body: some View {
		VStack(spacing: 0) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 96, height: 96)
				.padding(.top, 8)
			Text("iSQL").font(.title2.bold()).padding(.top, 10)
			Text(version).font(.callout).foregroundStyle(.secondary).padding(.top, 4)

			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					section("상표") {
						Text("MySQL · Oracle 은 Oracle, MariaDB 는 MariaDB Corporation Ab, SQLite 는 Hipp, Wyrick & Company 의 상표이며, 서버 목록의 로고는 접속한 DB 종류를 알리는 데만 씁니다. iSQL 은 이 회사들과 관계가 없습니다.")
					}
					section("오픈소스") {
						item("Simple Icons (CC0)", "로고 그림")
						item("Sparkle (MIT)", "자동 업데이트")
						item("python-oracledb (UPL · Apache 2.0), oracle-nio (Apache 2.0)", "Oracle 접속 코드를 참고해 옮김")
					}
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(14)
			}
			.frame(height: 170)
			.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
			.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.padding(.top, 18)
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 20)
		.frame(width: 360)
	}

	private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title).fontWeight(.semibold).foregroundStyle(.primary.opacity(0.75))
			content()
		}
		.fixedSize(horizontal: false, vertical: true)
	}

	private func item(_ name: String, _ what: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Text("·")
			Text(name) + Text(" — " + what).foregroundStyle(.tertiary)
		}
	}
}

/// 메뉴 iSQL > iSQL에 관하여 (기본 정보 창 대신 AboutView)
struct AboutMenuButton: View {
	@Environment(\.openWindow) private var openWindow
	var body: some View {
		Button("iSQL에 관하여") { openWindow(id: AboutView.windowID) }
	}
}
