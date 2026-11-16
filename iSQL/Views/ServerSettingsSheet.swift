import SwiftUI

/// 서버별 설정 (제목바 서버 이름 옆 톱니 → 창 제목바 시트). 탭: 일반 / 사용자 계정 (내용은 차차 채운다)
struct ServerSettingsSheet: View {
	let session: Session
	@Environment(\.dismiss) private var dismiss
	/// 시트 안 TabView 는 크기 0 으로 만들어질 때 탭 너비를 재서 이름이 잘린다 → 뜬 뒤 한 번 다시 만든다 (Ai/iSQL.md)
	@State private var tabsReady = false

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 8) {
				if let s = session.server {
					Circle().fill(s.color.swiftUI ?? .secondary).frame(width: 9, height: 9)
					Text("\(s.displayName) 설정").font(.headline)
				} else {
					Text("서버 설정").font(.headline)
				}
			}
			TabView {
				general.tabItem { Text("일반") }
				accounts.tabItem { Text("사용자 계정") }
			}
			.frame(width: 640, height: 400)
			.id(tabsReady)
			HStack {
				Spacer()
				Button("닫기") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
			.controlSize(.large)
		}
		.padding(20)
		.onAppear { DispatchQueue.main.async { tabsReady = true } }
	}

	// MARK: 일반

	private var general: some View {
		VStack(alignment: .leading, spacing: 14) {
			Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
				if let s = session.server {
					row("이름", s.displayName)
					row("접속", s.subtitle)
				}
				if !session.serverVersion.isEmpty { row("서버 버전", session.serverVersion) }
				row("데이터베이스", "\(session.databases.count.formatted())개 · 테이블 \(session.tables.count.formatted())개")
			}
			Spacer(minLength: 0)
			Text("서버별 설정 항목은 여기에 차례로 들어갑니다.").font(.callout).foregroundStyle(.tertiary)
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private func row(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
			Text(value).textSelection(.enabled)
		}
	}

	// MARK: 사용자 계정

	private var accounts: some View {
		ContentUnavailableView("사용자 계정", systemImage: "person.2",
		                       description: Text("MySQL 사용자와 권한 관리는 준비 중입니다."))
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
