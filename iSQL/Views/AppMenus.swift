import SwiftUI

/// 메뉴 막대의 보기 · 파일 · 윈도우 항목 (사용자 2026-11-19: 숨은 단축키를 메뉴로 — 메뉴에서 찾아볼 수 있게).
/// 실제 일은 지금 창의 TabArea 가 정해 `focusedSceneValue(\.tabCommands, …)` 로 넘긴다.
/// 접속한 서버가 없는 창(또는 설정 창)이면 nil → 항목이 흐려진다
struct TabCommands {
	/// 초점 탭이 테이블이면 지금 보기 (데이터 · 구조), 아니면 nil
	var mode: TableData.Mode?
	var setMode: (TableData.Mode) -> Void
	/// 조건 줄(데이터) · 검색(DB 개요)을 켤 수 있는지, 켜져 있는지
	var filterOn: Bool?
	var toggleFilter: () -> Void
	/// 테이블 정보 패널 (구조 보기로 바꿔서)
	var infoOn: Bool?
	var toggleInfo: () -> Void
	var queryOn: Bool?
	var toggleQuery: () -> Void
	var consoleOn: Bool
	var toggleConsole: () -> Void
	var refresh: () -> Void
	var save: () -> Void
	var quickOpen: () -> Void
	var hasTab: Bool
	var closeTab: () -> Void
	var moveTab: (Int) -> Void
}

extension FocusedValues {
	@Entry var tabCommands: TabCommands?
}

/// 보기 메뉴 (macOS 기본 "보기" 메뉴의 도구 막대 항목 위에 넣는다)
struct ViewMenuItems: View {
	@FocusedValue(\.tabCommands) private var c

	var body: some View {
		Button("데이터") { c?.setMode(.data) }
			.keyboardShortcut("1")
			.disabled(c?.mode == nil)
		Button("구조") { c?.setMode(.structure) }
			.keyboardShortcut("2")
			.disabled(c?.mode == nil)
		Divider()
		Button("새로고침") { c?.refresh() }
			.keyboardShortcut("r")
			.disabled(c == nil)
		Toggle("조건 줄", isOn: binding(c?.filterOn, c?.toggleFilter))
			.keyboardShortcut("f", modifiers: [.command, .option])
			.disabled(c?.filterOn == nil)
		Toggle("테이블 정보", isOn: binding(c?.infoOn, c?.toggleInfo))
			.keyboardShortcut("i", modifiers: [.command, .option])
			.disabled(c?.infoOn == nil)
		Divider()
		Toggle("쿼리 패널", isOn: binding(c?.queryOn, c?.toggleQuery))
			.keyboardShortcut("j")
			.disabled(c?.queryOn == nil)
		Toggle("콘솔", isOn: binding(c?.consoleOn, c?.toggleConsole))
			.keyboardShortcut("l", modifiers: [.command, .shift])
			.disabled(c == nil)
		Button("빠른 열기") { c?.quickOpen() }
			.keyboardShortcut("k")
			.disabled(c == nil)
		Divider()
	}

	/// 메뉴의 체크 표시: 지금 상태를 보여 주고, 누르면 토글 함수를 부른다
	private func binding(_ on: Bool?, _ toggle: (() -> Void)?) -> Binding<Bool> {
		Binding(get: { on ?? false }, set: { _ in toggle?() })
	}
}

/// 파일 메뉴: 저장 · 탭 닫기
struct FileMenuItems: View {
	@FocusedValue(\.tabCommands) private var c

	var body: some View {
		Button("저장") { c?.save() }
			.keyboardShortcut("s")
			.disabled(c == nil)
		Button("탭 닫기") { c?.closeTab() }
			.keyboardShortcut("w", modifiers: [.command, .shift])
			.disabled(c?.hasTab != true)
	}
}

/// 윈도우 메뉴: 이전 · 다음 탭 (맥 기본 앱들처럼)
struct WindowMenuItems: View {
	@FocusedValue(\.tabCommands) private var c

	var body: some View {
		Button("이전 탭") { c?.moveTab(-1) }
			.keyboardShortcut("[", modifiers: [.command, .shift])
			.disabled(c?.hasTab != true)
		Button("다음 탭") { c?.moveTab(1) }
			.keyboardShortcut("]", modifiers: [.command, .shift])
			.disabled(c?.hasTab != true)
		Divider()
	}
}
