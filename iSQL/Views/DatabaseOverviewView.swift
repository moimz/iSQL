import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// DB 개요 탭: 테이블 목록·용량 (phpMyAdmin 구조 화면처럼). 아래 줄에 내보내기와 합계
struct DatabaseOverviewView: View {
	let session: Session
	let overview: DatabaseOverview

	var body: some View {
		VStack(spacing: 0) {
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
				               exportHelp: overview.selection.isEmpty ? "모든 테이블 내보내기" : "고른 테이블 내보내기") {
					overview.requestExportPicked()
				}
				Text(overview.selection.isEmpty ? "고른 테이블 없음 (내보내기는 전체)" : "\(overview.selection.count)개 고름")
					.foregroundStyle(.secondary)
				Spacer(minLength: 12)
				Text(summary).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
				Button { Task { await overview.load() } } label: {
					if overview.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
				}
				.help("다시 읽기")
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
