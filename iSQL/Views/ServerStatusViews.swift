import SwiftUI
import AppKit

/// 설정 창 "상태" 탭: 위 요약 칸 + [프로세스 | 쿼리 통계] 표. 보이는 동안만 5초마다 읽는다
struct ServerStatusTab: View {
	let session: Session
	@State private var monitor: ServerStatusMonitor
	@State private var page = 0

	init(session: Session) {
		self.session = session
		_monitor = State(initialValue: ServerStatusMonitor(session: session))
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Toggle("\(Int(ServerStatusMonitor.interval))초마다 새로 읽기", isOn: Binding(get: { !monitor.paused }, set: { monitor.paused = !$0 }))
					.toggleStyle(.checkbox)
				if let u = monitor.updated {
					Text("마지막 \(u.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary).monospacedDigit()
				}
				Spacer()
				Button { Task { await monitor.refresh() } } label: { Label("새로 읽기", systemImage: "arrow.clockwise") }
			}
			.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
			if let e = monitor.error {
				Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8)
			}
			if let s = monitor.summary { cards(s).padding(.horizontal, 16).padding(.bottom, 6) }
			HStack {
				Picker("", selection: $page) {
					Text("프로세스 \(monitor.processes.count)").tag(0)
					Text("쿼리 통계").tag(1)
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				.fixedSize()
				Spacer()
				Text(page == 0 ? "노랑: 10초 넘게 도는 쿼리 · 빨강: 잠금 대기 · 오른쪽 클릭으로 멈추기·끊기"
				               : "서버가 켜진 뒤(또는 통계를 비운 뒤) 오래 걸린 쿼리 순, 값은 ? 로 묶음")
					.font(.callout).foregroundStyle(.secondary).lineLimit(1)
			}
			.padding(.horizontal, 16).padding(.vertical, 8)
			Group {
				if page == 0 {
					TableGrid(source: monitor.processSource)
				} else if let e = monitor.digestError {
					ContentUnavailableView("쿼리 통계 없음", systemImage: "chart.bar.xaxis", description: Text(e))
				} else {
					TableGrid(source: monitor.digestSource)
				}
			}
			.settingsTableFrame()
		}
		.onAppear { monitor.start() }
		.onDisappear { monitor.stop() }
	}

	private func cards(_ s: ServerDiagnostics.Summary) -> some View {
		LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
			StatCard(title: "가동 시간", value: ServerDiagnostics.duration(s.uptime), detail: s.version)
			StatCard(title: "연결", value: "\(s.connected) / \(s.maxConnections)", detail: "실행 중 \(s.running)", warn: s.connectionsTight)
			StatCard(title: "초당 쿼리", value: String(format: monitor.qps < 10 ? "%.1f" : "%.0f", monitor.qps), detail: String(format: "평균 %.1f", s.avgQPS))
			StatCard(title: "느린 쿼리", value: s.slowQueries.formatted(), detail: s.longQueryTime.isEmpty ? "" : "기준 \(ServerDiagnostics.trimNumber(s.longQueryTime))초", warn: s.slowQueries > 0)
			StatCard(title: "버퍼 풀 적중률", value: s.bufferHit.map { String(format: "%.2f%%", $0 * 100) } ?? "—", detail: "95% 아래면 메모리 부족", warn: s.bufferLow)
			StatCard(title: "버퍼 풀 사용", value: ServerDiagnostics.bytes(s.bufferUsed), detail: "전체 \(ServerDiagnostics.bytes(s.bufferSize))")
			StatCard(title: "받은 데이터", value: ServerDiagnostics.bytes(s.received), detail: "시작한 뒤")
			StatCard(title: "보낸 데이터", value: ServerDiagnostics.bytes(s.sent), detail: "시작한 뒤")
		}
	}
}

private struct StatCard: View {
	let title: String
	let value: String
	var detail = ""
	var warn = false

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title).font(.caption).foregroundStyle(.secondary)
			Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
				.foregroundStyle(warn ? Color.orange : .primary)
				.lineLimit(1).minimumScaleFactor(0.7)
			Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(warn ? Color.orange.opacity(0.6) : .clear))
	}
}

/// 설정 창 "서버 설정" 탭: SHOW GLOBAL VARIABLES (보기만). 자주 보는 것은 맨 위 + 설명
struct ServerVariablesTab: View {
	let session: Session
	@State private var source = VariablesSource()
	@State private var error: String?

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				TextField("변수 이름·값 찾기", text: $source.filter)
					.textFieldStyle(.roundedBorder)
					.frame(maxWidth: 280)
				Text("\(source.count.formatted())개").foregroundStyle(.secondary).monospacedDigit()
				Spacer()
				Text("보기만 합니다 (SET GLOBAL 은 다시 시작하면 사라지고 서버 전체에 영향이 커서)").font(.callout).foregroundStyle(.secondary)
				Button { Task { await load() } } label: { Label("새로 읽기", systemImage: "arrow.clockwise") }
			}
			.padding(.horizontal, 16).padding(.vertical, 10)
			if let error { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).padding(.bottom, 8) }
			TableGrid(source: source)
				.settingsTableFrame()
		}
		.task { await load() }
	}

	private func load() async {
		do {
			source.set(try await session.meta.variables(session.query))
			error = nil
		} catch {
			self.error = error.localizedDescription
		}
	}
}

/// 서버 변수 표: 주요 변수(설명 있음)가 먼저, 나머지는 이름 순
@Observable
final class VariablesSource: GridSource {
	@ObservationIgnored var scrollOrigin: CGPoint = .zero
	@ObservationIgnored private var all: [(String, String)] = []
	var filter = "" { didSet { rebuild() } }
	private(set) var gridVersion = 0
	@ObservationIgnored private var shown: [(name: String, value: String)] = []
	/// 보이는 줄 수 (찾기 옆에 보인다. shown 은 관찰하지 않아서 따로)
	private(set) var count = 0

	/// 자주 보는 변수와 설명 (이 순서로 맨 위)
	static let major: [(String, String)] = [
		("version", "MySQL 버전"),
		("max_connections", "동시에 받을 수 있는 최대 연결 수"),
		("innodb_buffer_pool_size", "InnoDB 가 데이터·인덱스를 올려 두는 메모리. 보통 서버 메모리의 50~75%"),
		("innodb_log_file_size", "redo 로그 파일 크기 (8.0.30 부터는 innodb_redo_log_capacity)"),
		("innodb_redo_log_capacity", "redo 로그 전체 크기"),
		("innodb_flush_log_at_trx_commit", "1: 커밋마다 디스크에 씀(안전), 2·0: 빠르지만 장애 때 최근 1초 잃을 수 있음"),
		("long_query_time", "이 초보다 오래 걸리면 느린 쿼리로 셈"),
		("slow_query_log", "느린 쿼리 로그 켜짐"),
		("max_allowed_packet", "쿼리·결과 한 덩어리 최대 크기 (큰 INSERT·BLOB 에 영향)"),
		("wait_timeout", "놀고 있는 연결을 끊기까지 초"),
		("sql_mode", "SQL 엄격도 (ONLY_FULL_GROUP_BY, STRICT_TRANS_TABLES 등)"),
		("character_set_server", "새 DB 의 기본 문자셋"),
		("collation_server", "새 DB 의 기본 콜레이션"),
		("time_zone", "서버 시간대 (SYSTEM 이면 OS 설정)"),
		("transaction_isolation", "기본 트랜잭션 격리 수준"),
		("log_bin", "바이너리 로그 켜짐 (복제·시점 복구)"),
		("binlog_format", "바이너리 로그 형식 (ROW 권장)"),
		("performance_schema", "성능 통계 켜짐 (상태 탭의 쿼리 통계에 필요)"),
		("tmp_table_size", "메모리 임시 테이블 최대 크기 (넘으면 디스크로)"),
		("table_open_cache", "열어 둘 수 있는 테이블 수"),
	]
	private static let majorIndex = Dictionary(uniqueKeysWithValues: major.enumerated().map { ($1.0, $0) })
	private static let notes = Dictionary(uniqueKeysWithValues: major)

	func set(_ list: [(String, String)]) { all = list; rebuild() }

	private func rebuild() {
		let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
		let hits = all.filter { f.isEmpty || $0.0.lowercased().contains(f) || $0.1.lowercased().contains(f) }
		let top = hits.filter { Self.majorIndex[$0.0] != nil }.sorted { Self.majorIndex[$0.0]! < Self.majorIndex[$1.0]! }
		let rest = hits.filter { Self.majorIndex[$0.0] == nil }.sorted { $0.0 < $1.0 }
		shown = (top + rest).map { (name: $0.0, value: $0.1) }
		count = shown.count
		gridVersion += 1
	}

	var gridID: String { "variables" }
	var gridColumns: [GridColumn] {
		[GridColumn(key: "name", title: "이름", mono: true, width: 300),
		 GridColumn(key: "value", title: "값", width: 260),
		 GridColumn(key: "note", title: "설명", width: 520)]
	}
	var rowCount: Int { shown.count }
	var sortable: Bool { false }

	func cell(_ row: Int, _ col: Int) -> GridCell {
		guard row < shown.count else { return GridCell(text: "") }
		let v = shown[row]
		let major = Self.majorIndex[v.name] != nil
		switch col {
		case 0: return GridCell(text: v.name, tint: major ? NSColor.controlAccentColor.withAlphaComponent(0.08) : nil)
		case 1: return GridCell(text: Self.pretty(v.name, v.value), tooltip: v.value.count > 40 ? v.value : nil,
		                        tint: major ? NSColor.controlAccentColor.withAlphaComponent(0.08) : nil)
		default: return GridCell(text: Self.notes[v.name] ?? "", dim: true, tint: major ? NSColor.controlAccentColor.withAlphaComponent(0.08) : nil)
		}
	}

	/// 크기 변수는 사람이 읽는 크기를 덧붙인다: 134217728 (128 MB)
	static func pretty(_ name: String, _ value: String) -> String {
		guard let n = Int64(value), n >= 1 << 20,
		      ["size", "buffer", "packet", "length", "capacity", "cache_size"].contains(where: { name.contains($0) }) else { return value }
		return "\(value) (\(ServerDiagnostics.bytes(n)))"
	}
}

extension View {
	/// 설정 창 안의 표: 창 끝까지 꽉 채우지 않고 여백 + 둥근 테두리 (사용자 계정 탭과 같은 모양)
	func settingsTableFrame() -> some View {
		self
			.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
			.padding(.horizontal, 16)
			.padding(.bottom, 16)
			.frame(maxHeight: .infinity)
	}
}
