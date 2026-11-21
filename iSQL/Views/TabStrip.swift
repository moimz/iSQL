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
					.coordinateSpace(.named(TabReorderSpace.name))
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
	/// 앞에 흐리게 붙는 글자 (DB 이름 "html.")
	var prefix: String? = nil
	let text: String
	let active: Bool

	var body: some View {
		HStack(spacing: 0) {
			if let prefix { Text(prefix).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
			ZStack(alignment: .leading) {
				Text(text).fontWeight(.semibold).lineLimit(1).hidden()
				Text(text).fontWeight(active ? .semibold : .regular).lineLimit(1)
			}
		}
	}
}

enum TabReorderSpace { static let name = "tabstrip" }

/// 탭 끌어 순서 바꾸기 상태 (탭바 하나에 하나)
struct TabReorder<ID: Hashable> {
	/// 끄는 탭
	var dragging: ID?
	/// 끄는 탭을 제자리에서 얼마나 옮겨 그릴지
	var offset: CGFloat = 0
	/// 끌기 시작할 때 그 탭의 왼쪽 끝 (탭바 안 좌표)
	var startX: CGFloat = 0
	/// 탭 너비 (순서를 바꾼 뒤 자리를 계산하는 데)
	var widths: [ID: CGFloat] = [:]
}

extension View {
	/// 편집기 탭처럼: 탭을 끌면 마우스를 따라오고, 옆 탭 가운데를 넘으면 그 탭이 비켜나며 순서가 바뀐다.
	/// 시스템 끌어 놓기(.draggable)는 마우스에 그림만 붙고 탭바는 그대로라 어색했다 (사용자)
	func reorderable<ID: Hashable>(_ id: ID, order: [ID], state: Binding<TabReorder<ID>>,
	                               move: @escaping (ID, ID?) -> Void) -> some View {
		modifier(TabReorderModifier(id: id, order: order, state: state, move: move))
	}
}

private struct TabReorderModifier<ID: Hashable>: ViewModifier {
	let id: ID
	let order: [ID]
	@Binding var state: TabReorder<ID>
	let move: (ID, ID?) -> Void

	private var isDragging: Bool { state.dragging == id }

	/// 지금 순서에서 탭 왼쪽 끝
	private func left(of target: ID, in ids: [ID]) -> CGFloat {
		var x: CGFloat = 0
		for i in ids { if i == target { return x }; x += state.widths[i] ?? 0 }
		return x
	}

	func body(content: Content) -> some View {
		content
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.widths[id] = $0 }
			.offset(x: isDragging ? state.offset : 0)
			.zIndex(isDragging ? 1 : 0)
			.shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6)
			// 끄는 탭은 순서가 바뀔 때 미끄러지지 않게 (옮겨 그리기로 마우스 밑에 붙어 있다)
			.transaction { if isDragging { $0.animation = nil } }
			.gesture(
				DragGesture(minimumDistance: 4, coordinateSpace: .named(TabReorderSpace.name))
					.onChanged { v in
						if state.dragging != id {
							state.dragging = id
							state.startX = left(of: id, in: order)
						}
						let w = state.widths[id] ?? 0
						// 왼쪽 끝을 0 에 묶으면 탭 너비가 같을 때 끄는 탭 가운데가 첫 탭 가운데를 못 넘어
						// 두 번째 탭을 맨 앞으로 못 옮겼다 (사용자 2026-11-21) → 반 탭만큼 왼쪽 밖까지 허용
						let wantX = max(-w / 2, state.startX + v.translation.width)
						// 끄는 탭 가운데가 넘어선 옆 탭들 → 들어갈 자리
						let others = order.filter { $0 != id }
						var x: CGFloat = 0, target = others.count
						for (i, o) in others.enumerated() {
							let ow = state.widths[o] ?? 0
							if wantX + w / 2 <= x + ow / 2 { target = i; break }
							x += ow
						}
						var newOrder = others
						newOrder.insert(id, at: target)
						if newOrder != order {
							move(id, target < others.count ? others[target] : nil)
						}
						state.offset = wantX - left(of: id, in: newOrder)
					}
					.onEnded { _ in
						withAnimation(.easeOut(duration: 0.15)) { state.offset = 0 }
						state.dragging = nil
					}
			)
	}
}
