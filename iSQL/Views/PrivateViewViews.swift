import SwiftUI
import AppKit

/// 사이드바: 그 DB 의 나만 보는 뷰 (눈 + 자물쇠)
struct PrivateViewRows: View {
	let session: Session
	let schema: String
	var search = ""

	var body: some View {
		let list = session.privateViews(schema).filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
		ForEach(list) { v in
			PrivateViewRow(view: v, selected: session.activeTab == v.tabID)
				.onTapGesture {
					session.queryPanel?.open = false
					session.openPrivateView(v)
				}
				.contextMenu { PrivateViewMenu(session: session, view: v) }
		}
	}
}

/// 눈 아이콘 오른쪽 아래에 작은 자물쇠: "서버에 없고 나만 본다"
struct PrivateViewIcon: View {
	var selected = false
	var body: some View {
		Image(systemName: "eye")
			.font(.system(size: 11))
			.foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
			.overlay(alignment: .bottomTrailing) {
				Image(systemName: "lock.fill")
					.font(.system(size: 7, weight: .bold))
					.foregroundStyle(selected ? Color.white : .orange)
					.offset(x: 4, y: 3)
			}
	}
}

private struct PrivateViewRow: View {
	let view: PrivateView
	let selected: Bool
	@State private var hover = false

	var body: some View {
		// 일반 뷰 줄(TableRow)과 같은 자리: 눈 아이콘·간격 같게, 자물쇠는 고정 핀처럼 오른쪽에
		HStack(spacing: 6) {
			Image(systemName: "eye")
				.font(.system(size: 11))
				.foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
			Text(view.name).lineLimit(1).truncationMode(.middle)
				.foregroundStyle(selected ? Color.white : .primary)
			Spacer(minLength: 8)
			Image(systemName: "lock.fill").font(.system(size: 9))
				.foregroundStyle(selected ? Color.white.opacity(0.85) : .orange)
				.help("나만 보는 뷰 (서버에 없음)")
		}
		.padding(.leading, 30)
		.padding(.trailing, 10)
		.frame(minHeight: 26)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : (hover ? Color.primary.opacity(0.06) : .clear)))
		.padding(.horizontal, 6)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.help("나만 보는 뷰 (서버에 없음, iCloud)\n\(view.sql)")
	}
}

struct PrivateViewMenu: View {
	let session: Session
	let view: PrivateView

	var body: some View {
		Button("열기") { session.openPrivateView(view) }
		Button("SQL 복사") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(view.sql + ";", forType: .string)
		}
		Button("쿼리 패널에 넣기") {
			guard let p = session.queryPanel else { return }
			p.text = p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? view.sql + ";" : p.text + "\n\n" + view.sql + ";"
			p.database = view.schema
			p.open = true
		}
		Divider()
		Button("이름 바꾸기…") {
			let f = NSTextField(string: view.name)
			f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
			Task {
				guard await Confirm.ask("나만 보는 뷰 이름", buttons: ["바꾸기"], accessory: f) == 0 else { return }
				let n = f.stringValue.trimmingCharacters(in: .whitespaces)
				if !n.isEmpty { session.renamePrivateView(view, to: n) }
			}
		}
		Button("삭제…", role: .destructive) {
			Task {
				if await Confirm.ask("나만 보는 뷰 ‘\(view.name)’ 을 삭제할까요?", "서버에는 없는 뷰라 데이터는 그대로입니다. 다른 맥에서도 사라집니다.",
				                     buttons: ["삭제"], destructive: true) == 0 { session.deletePrivateView(view) }
			}
		}
	}
}

/// 나만 보는 뷰 탭: 위 줄(이름·SQL·새로 읽기) + 쿼리 결과와 같은 표 (쪽 나누기·한 테이블이면 고치기)
struct PrivateViewTabView: View {
	let session: Session
	let view: PrivateView
	@State private var output: QueryOutput?
	@State private var error: String?
	@State private var loading = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				PrivateViewIcon()
				Text(view.name).font(.headline)
				Text("나만 보는 뷰").font(.caption).foregroundStyle(.orange)
				Text(view.sql).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
					.textSelection(.enabled)
				Spacer()
				Button { Task { await run(refresh: true) } } label: { Label("새로고침", systemImage: "arrow.clockwise") }
					.disabled(loading)
					.help("새로고침 (⌘R)")
			}
			.padding(.horizontal, 12).padding(.vertical, 8)
			Divider()
			if let output {
				VStack(spacing: 0) { ResultBody(output: output, source: output.source).id(ObjectIdentifier(output.source)) }
			} else if let error {
				ContentUnavailableView("실행하지 못했습니다", systemImage: "xmark.octagon", description: Text(error))
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.task(id: view.id) { await run(refresh: false) }
		// ⌘R (TabArea 가 초점 탭이 이 뷰일 때 보낸다)
		.onReceive(NotificationCenter.default.publisher(for: Self.refreshRequest, object: session)) { n in
			if n.userInfo?["view"] as? UUID == view.id, !loading { Task { await run(refresh: true) } }
		}
	}

	static let refreshRequest = Notification.Name("iSQL.privateViewRefresh")

	@MainActor
	private func run(refresh: Bool) async {
		loading = true
		defer { loading = false }
		do {
			output = try await session.runPrivateView(view, refresh: refresh)
			error = nil
		} catch {
			self.error = error.localizedDescription
		}
	}
}
