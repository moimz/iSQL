import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 콘솔 패널 (하단바 아래): 앱이 서버에 보낸 쿼리. 찾기, 지우기, 저장, 쿼리 패널에 넣기
struct ConsolePanel: View {
	let log: QueryLog
	/// 오른쪽 클릭 "쿼리 패널에 넣기"
	let insert: (String) -> Void
	@State private var source: ConsoleSource
	@AppStorage("consoleHeight") private var height = 220.0
	@State private var dragStart: Double?

	init(log: QueryLog, insert: @escaping (String) -> Void) {
		self.log = log
		self.insert = insert
		_source = State(initialValue: ConsoleSource(log: log))
	}

	var body: some View {
		VStack(spacing: 0) {
			// 끌어서 높이 바꾸기
			Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
				.padding(.vertical, 2)
				.contentShape(Rectangle())
				.onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
				.gesture(DragGesture(minimumDistance: 1).onChanged { v in
					if dragStart == nil { dragStart = height }
					height = min(max((dragStart ?? height) - v.translation.height, 100), 600)
				}.onEnded { _ in dragStart = nil })
			HStack(spacing: 8) {
				Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
				Text("콘솔").font(.headline)
				TextField("찾기", text: $source.filter)
					.textFieldStyle(.roundedBorder)
					.frame(maxWidth: 260)
				Text("\(source.rowCount.formatted())개").foregroundStyle(.secondary).monospacedDigit()
				Spacer()
				Button("저장…", action: save).disabled(log.entries.isEmpty)
				Button("지우기") { log.clear() }.disabled(log.entries.isEmpty)
			}
			.controlSize(.small)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			TableGrid(source: source)
		}
		.frame(height: height)
		.onAppear { source.insert = insert }
	}

	private func save() {
		let p = NSSavePanel()
		p.nameFieldStringValue = "iSQL 콘솔.txt"
		p.allowedContentTypes = [.plainText]
		guard p.runModal() == .OK, let url = p.url else { return }
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		let text = log.entries.map { e -> String in
			"\(f.string(from: e.time))\t\(e.server)\t\(e.database)\t\(String(format: "%.1fms", e.seconds * 1000))\t\(e.error.map { "오류: \($0)\t" } ?? "")\(e.sql)"
		}.joined(separator: "\n")
		try? text.write(to: url, atomically: true, encoding: .utf8)
	}
}

/// 콘솔 표: 새 쿼리가 위 (시각 제목을 누르면 오래된 것이 위). 오류 줄은 옅은 빨강 + 오류 칸, 위험 쿼리는 옅은 노랑
@Observable
final class ConsoleSource: GridSource {
	@ObservationIgnored let log: QueryLog
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored var insert: ((String) -> Void)?
	var filter = ""
	/// 새 것이 위 (시각 내림차순)
	var newestFirst = true

	init(log: QueryLog) { self.log = log }

	private static let timeFormat: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	@ObservationIgnored private var cacheKey = ""
	@ObservationIgnored private var cache: [QueryLog.Entry] = []

	/// 찾기를 거친 줄 (새 것이 위)
	private var shown: [QueryLog.Entry] {
		MainActor.assumeIsolated {
			let entries = log.entries
			let key = "\(entries.first?.id ?? 0)|\(entries.last?.id ?? 0)|\(entries.count)|\(filter)|\(newestFirst)"
			if key != cacheKey {
				let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
				let ordered = newestFirst ? Array(entries.reversed()) : entries
				cache = ordered.filter { e in
					f.isEmpty || e.sql.lowercased().contains(f) || e.server.lowercased().contains(f) || e.database.lowercased().contains(f)
						|| (e.error?.lowercased().contains(f) ?? false)
				}
				cacheKey = key
			}
			return cache
		}
	}

	var gridID: String { "console" }
	var gridColumns: [GridColumn] {
		[GridColumn(key: "time", title: "시각", mono: true, width: 116),
		 GridColumn(key: "server", title: "서버", width: 150),
		 GridColumn(key: "db", title: "DB", width: 110),
		 GridColumn(key: "ms", title: "시간", numeric: true, width: 70),
		 GridColumn(key: "error", title: "오류", width: 260),
		 GridColumn(key: "sql", title: "쿼리", mono: true, width: 900)]
	}
	var gridVersion: Int { MainActor.assumeIsolated { (log.entries.last?.id ?? 0) &* 31 &+ log.entries.count &+ filter.hashValue &+ (newestFirst ? 1 : 0) } }
	var rowCount: Int { shown.count }

	// 정렬은 시각만: 제목에 꺾쇠로 지금 순서를 보이고, 누르면 뒤집는다. 다른 컬럼을 눌러도 그대로 (삑 소리 없이)
	var currentSort: (key: String, ascending: Bool)? { ("time", !newestFirst) }
	func sort(by key: String?, ascending: Bool) -> Bool {
		if key == nil { newestFirst = true } else if key == "time" { newestFirst = !ascending }
		return true
	}

	private static let errorTint = NSColor.systemRed.withAlphaComponent(0.16)
	private static let dangerTint = NSColor.systemYellow.withAlphaComponent(0.16)

	func cell(_ row: Int, _ col: Int) -> GridCell {
		let list = shown
		guard row < list.count else { return GridCell(text: "") }
		let e = list[row]
		var c: GridCell
		switch col {
		case 0: c = GridCell(text: Self.timeFormat.string(from: e.time))
		case 1: c = GridCell(text: e.server)
		case 2: c = GridCell(text: e.database, dim: true)
		case 3: c = GridCell(text: e.seconds < 1 ? String(format: "%.1fms", e.seconds * 1000) : String(format: "%.2fs", e.seconds))
		case 4: c = GridCell(text: e.error ?? "", tooltip: e.error)
		default: c = GridCell(text: e.sql, tooltip: e.error.map { "오류: \($0)\n\n\(e.sql)" } ?? (e.sql.count > 80 ? e.sql : nil))
		}
		// 오류가 먼저 (위험 쿼리가 실패했으면 빨강)
		c.tint = e.error != nil ? Self.errorTint : (e.dangerous ? Self.dangerTint : nil)
		return c
	}

	func cellMenu(row: Int, col: Int?, selection: IndexSet) -> [GridMenuItem] {
		let list = shown
		let picked = selection.sorted().compactMap { $0 < list.count ? list[$0].sql : nil }
		guard !picked.isEmpty else { return [] }
		let sql = picked.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n")
		return [.action("쿼리 패널에 넣기") { self.insert?(sql) }]
	}
	var cellMenuFirst: Bool { true }
}
