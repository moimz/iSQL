import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// DB 개요 탭: 테이블 목록·용량 (phpMyAdmin 구조 화면처럼). 아래 줄에 내보내기와 합계
struct DatabaseOverviewView: View {
	let session: Session
	@Bindable var overview: DatabaseOverview
	@FocusState private var searchFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			// 검색 줄 (제목바 검색 버튼·⌥⌘F): 테이블 이름·코멘트로 거른다
			if overview.showSearch {
				HStack(spacing: 0) {
					SidebarSearchField(text: $overview.searchText, prompt: "테이블 이름, 코멘트 검색", focused: $searchFocused)
						.frame(maxWidth: 420)
						.onExitCommand { overview.searchText = "" }
					if overview.isFiltered {
						Text("\(overview.rowCount) / \(overview.stats.count)개").foregroundStyle(.secondary).monospacedDigit()
					}
					Spacer(minLength: 0)
				}
				.onAppear { searchFocused = true }
				Divider()
			}
			ZStack {
				TableGrid(source: overview) { overview.selection = $0 }
				if overview.loading && overview.stats.isEmpty { ProgressView() }
				if let e = overview.error {
					Text(e).foregroundStyle(.red).textSelection(.enabled).padding()
						.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
				}
			}
			Divider()
			HStack(spacing: 10) {
				// [+ | 내보내기] 묶음. + 는 테이블 만들기 (아직 기능 없음)
				AddExportGroup(addHelp: "새 테이블 만들기",
				               add: { session.createTableRequest = CreateTableRequest(schema: overview.schema) },
				               showsRemove: true, removeHelp: "고른 테이블 삭제…",
				               remove: overview.selection.isEmpty ? nil : {
				                   session.requestDrop(schema: overview.schema, overview.selection.compactMap { overview.stat(at: $0) })
				               },
				               exportHelp: overview.selection.isEmpty ? "모든 테이블 내보내기" : "고른 테이블 내보내기") {
					overview.requestExportPicked()
				}
				Text(overview.selection.isEmpty
				     ? (overview.isFiltered ? "고른 테이블 없음 (내보내기는 보이는 \(overview.rowCount)개)" : "고른 테이블 없음 (내보내기는 전체)")
				     : "\(overview.selection.count)개 고름")
					.foregroundStyle(.secondary)
				Spacer(minLength: 12)
				Text(summary).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
				Button { Task { await overview.load() } } label: {
					if overview.loading { ProgressView().controlSize(.small).frame(width: 30, height: 28) } else { PillIcon(systemName: "arrow.clockwise") }
				}
				.pill()
				.help("새로고침 (⌘R)")
			}
			.controlSize(.large)
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
		}
		.task { if overview.stats.isEmpty { await overview.load() } }
	}

	private var summary: String {
		let n = overview.stats.filter { !$0.isView }.count
		let views = overview.stats.count - n
		return "테이블 \(n)개\(views > 0 ? " · 뷰 \(views)개" : "") · 행 ~\(overview.totalRows.formatted()) · 데이터 \(DatabaseOverview.size(overview.totalData)) · 인덱스 \(DatabaseOverview.size(overview.totalIndex)) · 전체 \(DatabaseOverview.size(overview.totalData + overview.totalIndex))"
	}
}
