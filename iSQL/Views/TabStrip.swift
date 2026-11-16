import SwiftUI

/// 탭바 공용 틀: 가로 스크롤 + 탭이 넘치면 오른쪽 끝에 < > 이동 버튼
/// (테이블 탭바와 쿼리 결과 탭바가 같이 쓴다)
struct TabStrip<ID: Hashable, Content: View>: View {
	/// 고른 탭 id (바뀌면 그 탭이 보이게 스크롤). 탭 뷰마다 .id(같은 값)
	var selected: ID?
	@ViewBuilder var content: Content

	@State private var position = ScrollPosition(edge: .leading)
	@State private var metrics = Metrics()

	private struct Metrics: Equatable {
		var offset: CGFloat = 0
		var content: CGFloat = 0
		var viewport: CGFloat = 0
		var overflows: Bool { content > viewport + 1 }
		var maxOffset: CGFloat { max(0, content - viewport) }
	}

	var body: some View {
		HStack(spacing: 0) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 0) { content }
					.scrollTargetLayout()
			}
			.scrollPosition($position)
			// 고른 탭이 보이게. 새로 연 탭은 아직 배치 전이라 한 박자 뒤에 한다
			.onChange(of: selected) { _, id in
				guard let id else { return }
				Task { @MainActor in
					try? await Task.sleep(for: .milliseconds(30))
					withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(id: id) }
				}
			}
			.onScrollGeometryChange(for: Metrics.self) { g in
				Metrics(offset: g.contentOffset.x + g.contentInsets.leading,
				        content: g.contentSize.width, viewport: g.containerSize.width)
			} action: { _, m in
				metrics = m
			}
			if metrics.overflows {
				Divider()
				HStack(spacing: 2) {
					arrow("chevron.left", help: "왼쪽 탭 보기", enabled: metrics.offset > 1) { page(-1) }
					arrow("chevron.right", help: "오른쪽 탭 보기", enabled: metrics.offset < metrics.maxOffset - 1) { page(1) }
				}
				.padding(.horizontal, 6)
			}
		}
	}

	private func arrow(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
				.frame(width: 22, height: 22)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.foregroundStyle(enabled ? .secondary : .quaternary)
		.disabled(!enabled)
		.help(help)
	}

	/// 보이는 너비의 80% 만큼 옆으로
	private func page(_ direction: CGFloat) {
		let x = min(max(0, metrics.offset + direction * metrics.viewport * 0.8), metrics.maxOffset)
		withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(x: x) }
	}
}

/// 굵기가 바뀌어도 너비가 그대로인 탭 이름: 굵은 글자 너비를 늘 잡아 둔다
/// (고른 탭만 semibold 라 탭을 바꿀 때마다 탭 너비가 달라져 옆 탭들이 움직였다)
struct TabTitle: View {
	let text: String
	let active: Bool

	var body: some View {
		ZStack(alignment: .leading) {
			Text(text).fontWeight(.semibold).lineLimit(1).hidden()
			Text(text).fontWeight(active ? .semibold : .regular).lineLimit(1)
		}
	}
}
