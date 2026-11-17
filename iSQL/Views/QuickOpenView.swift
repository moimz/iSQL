import SwiftUI

/// ⌘K 빠른 열기 창: 위 가운데에 뜨고, 이름 몇 글자로 테이블·DB 를 찾아 연다.
/// ↑↓ 고르기 · ↵ 열기 · ⌘↵ 오른쪽 분할에 열기 · esc 닫기
struct QuickOpenView: View {
	let session: Session
	let close: () -> Void
	@State private var query = ""
	@State private var selected = 0
	@FocusState private var focused: Bool

	private var items: [QuickOpen.Item] {
		var recent = session.recent
		// 빈 글일 때 지금 보는 탭은 빼고 (바로 앞에 본 것이 맨 위)
		if query.isEmpty, let a = session.activeTab { recent.removeAll { $0 == Session.tableID(ofTab: a) } }
		return QuickOpen.search(query, tables: session.tables, databases: session.databases, recent: recent)
	}

	var body: some View {
		let list = items
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
				TextField("테이블·DB 이름으로 열기", text: $query)
					.textFieldStyle(.plain)
					.font(.system(size: 18))
					.focused($focused)
					.onKeyPress(.downArrow) { move(1, count: list.count); return .handled }
					.onKeyPress(.upArrow) { move(-1, count: list.count); return .handled }
					.onKeyPress(.escape) { close(); return .handled }
					.onKeyPress(keys: [.return], phases: .down) { press in
						open(list, right: press.modifiers.contains(.command))
						return .handled
					}
			}
			.padding(.horizontal, 14)
			.frame(height: 48)
			Divider()
			if list.isEmpty {
				Text(query.isEmpty ? "테이블이나 DB 이름을 입력하세요 (띄엄띄엄 쳐도 됩니다)" : "찾는 테이블이 없습니다")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, minHeight: 60)
			} else {
				if query.isEmpty {
					Text("최근 연 것").font(.caption).foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
				}
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(spacing: 0) {
							ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
								// .id(i) 를 붙이면 ForEach 의 줄 구분(item.id)을 덮어써서, 목록이 바뀌어도 옛 줄이 남았다
								QuickOpenRow(item: item, selected: i == selected)
									.contentShape(Rectangle())
									.onTapGesture { selected = i; open(list, right: false) }
							}
						}
						.padding(6)
					}
					.frame(maxHeight: 360)
					.fixedSize(horizontal: false, vertical: true)
					.onChange(of: selected) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
				}
			}
			Divider()
			Text("↑↓ 고르기   ↵ 열기   ⌘↵ 오른쪽 분할에 열기   esc 닫기")
				.font(.caption).foregroundStyle(.tertiary)
				.frame(maxWidth: .infinity)
				.frame(height: 26)
		}
		.frame(width: 580)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
		.shadow(color: .black.opacity(0.3), radius: 24, y: 8)
		.onAppear { focused = true }
		.onChange(of: query) { selected = 0 }
	}

	private func move(_ d: Int, count: Int) {
		guard count > 0 else { return }
		selected = (selected + d + count) % count
	}

	private func open(_ list: [QuickOpen.Item], right: Bool) {
		guard list.indices.contains(selected) else { NSSound.beep(); return }
		// 쿼리 패널이 떠 있으면 숨기고 연다 (사이드바에서 누를 때와 같게)
		session.queryPanel?.open = false
		switch list[selected].kind {
		case .table(let t):
			if right, let split = session.openInSplit { split(t) } else { session.openTab(t) }
		case .database(let s):
			session.openDatabase(s)
		}
		close()
	}
}

private struct QuickOpenRow: View {
	let item: QuickOpen.Item
	let selected: Bool

	var body: some View {
		HStack(spacing: 8) {
			switch item.kind {
			case .table(let t):
				Image(systemName: t.isView ? "eye" : "tablecells")
					.foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
					.frame(width: 18)
				(Text(t.schema + ".").foregroundStyle(selected ? Color.white.opacity(0.7) : .secondary) + Text(t.name))
					.lineLimit(1)
				Spacer(minLength: 12)
				if !t.comment.isEmpty {
					Text(t.comment).lineLimit(1).font(.callout)
						.foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
				}
			case .database(let s):
				Image(systemName: "cylinder.split.1x2")
					.foregroundStyle(selected ? Color.white.opacity(0.85) : Color.accentColor)
					.frame(width: 18)
				Text(s).fontWeight(.semibold).lineLimit(1)
				Spacer(minLength: 12)
				Text("데이터베이스").font(.callout).foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
			}
		}
		.foregroundStyle(selected ? Color.white : .primary)
		.padding(.horizontal, 10)
		.frame(height: 30)
		.background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
	}
}
