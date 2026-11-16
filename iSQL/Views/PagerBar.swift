import SwiftUI

/// 쪽 줄에 대는 쪽 (테이블 데이터, 쿼리 결과)
protocol Pager: AnyObject {
	/// 쪽을 넘길 수 있는지 (직접 LIMIT 을 쓴 쿼리 결과 등은 아님)
	var pageable: Bool { get }
	/// "1,234행" / "~10,000행" / "900행~"
	var totalText: String { get }
	/// 어림값이라 눌러서 정확히 셀 수 있는지
	var totalIsApprox: Bool { get }
	/// 어림값 툴팁
	var approxHelp: String { get }
	var counting: Bool { get }
	func countExact() async
	var page: Int { get }
	var totalPages: (count: Int, approx: Bool)? { get }
	var offset: Int { get }
	var hasMore: Bool { get }
	var pageSize: Int { get }
	func goPage(_ p: Int) async
	func setPageSize(_ n: Int) async
	/// 다 읽었는데 행이 없음
	var isEmptyResult: Bool { get }
}

/// 쪽 줄 오른쪽: ~140,000행 ↻  < [ 3 ] / ~467 >  [300행]
struct PagerBar: View {
	let pager: Pager

	var body: some View {
		HStack(spacing: 10) {
			if !pager.totalText.isEmpty {
				if pager.totalIsApprox {
					// 숫자 옆 작은 ↻ (세는 동안은 그 자리에 로딩), 누르면 SELECT COUNT(*)
					Button { Task { await pager.countExact() } } label: {
						HStack(spacing: 4) {
							Text(pager.totalText).monospacedDigit().lineLimit(1).fixedSize()
							if pager.counting {
								ProgressView().controlSize(.mini).frame(width: 12, height: 12)
							} else {
								Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
									.frame(width: 12, height: 12)
							}
						}
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.disabled(pager.counting)
					.help(pager.approxHelp)
				} else {
					Text(pager.totalText).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
				}
			} else if pager.isEmptyResult {
				Text("행 없음").foregroundStyle(.secondary)
			}
			if pager.pageable {
				Button { Task { await pager.goPage(pager.page - 1) } } label: { Image(systemName: "chevron.left") }
					.disabled(pager.offset == 0)
					.help("이전 쪽")
				PageField(pager: pager)
				Button { Task { await pager.goPage(pager.page + 1) } } label: { Image(systemName: "chevron.right") }
					.disabled(!pager.hasMore)
					.help("다음 쪽")
				PopUp(selection: Binding(get: { pager.pageSize }, set: { n in Task { await pager.setPageSize(n) } }),
				      options: TableData.pageSizes.map { ("\($0)행", Optional($0)) })
					.frame(width: 90)
					.help("한 쪽에 보일 행 수")
			}
		}
	}
}

/// 지금 쪽 번호이자 쪽 번호 입력칸 (엔터로 이동) + 전체 쪽 수
struct PageField: View {
	let pager: Pager
	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 5) {
			TextField("", text: $text)
				.textFieldStyle(.roundedBorder)
				.multilineTextAlignment(.center)
				.monospacedDigit()
				.frame(width: 56)
				.focused($focused)
				.onSubmit {
					if let p = Int(text.trimmingCharacters(in: .whitespaces)) { Task { await pager.goPage(p) } }
					else { text = "\(pager.page)" }
				}
			if let t = pager.totalPages {
				// 좁은 칸(분할)에서도 줄바꿈하지 않게
				Text("/ \(t.approx ? "~" : "")\(t.count.formatted())").foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
			}
		}
		.onAppear { text = "\(pager.page)" }
		.onChange(of: pager.page) { _, p in text = "\(p)" }
		.onChange(of: focused) { _, f in if !f { text = "\(pager.page)" } }
		.help("쪽 번호를 넣고 엔터")
	}
}
