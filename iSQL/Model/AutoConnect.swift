import Foundation
import AppKit

/// 앱 열 때 자동 접속 (이 맥에만 기억, UserDefaults):
/// - 서버별 "앱 열 때 자동 접속" 표시 (서버 목록 오른쪽 클릭)
/// - 앱 설정 "앱을 열면 마지막에 접속해 있던 서버에 다시 접속": 접속을 닫지 않고 끈 서버들
/// 보여 줄 서버(끌 때 보던 서버, 없으면 목록 첫 서버)를 먼저 접속해 띄우고, 나머지는 뒤에서 차례로
enum AutoConnect {
	private static let d = UserDefaults.standard
	static let reconnectKey = "reconnectLast"

	/// 서버별 자동 접속 표시
	static var servers: Set<UUID> {
		get { Set((d.stringArray(forKey: "autoConnect") ?? []).compactMap(UUID.init)) }
		set { d.set(newValue.map(\.uuidString).sorted(), forKey: "autoConnect") }
	}

	static func toggle(_ id: UUID) {
		var s = servers
		if s.contains(id) { s.remove(id) } else { s.insert(id) }
		servers = s
	}

	/// 끌 때 접속해 있던 서버와 보고 있던 서버
	private static var lastConnected: [UUID] { (d.stringArray(forKey: "lastConnected") ?? []).compactMap(UUID.init) }
	private static var lastViewed: UUID? { d.string(forKey: "lastViewed").flatMap(UUID.init) }

	/// 앱이 끝나는 중이면 기억을 바꾸지 않는다 (끝나면서 접속이 닫혀도 "접속해 있던 서버" 로 남게)
	nonisolated(unsafe) static var terminating = false
	/// 첫 창만 자동 접속한다
	nonisolated(unsafe) static var didRun = false

	/// 자동 시험으로 띄운 앱은 자동 접속도 기억도 하지 않는다 (같은 설정을 쓰는 진짜 앱의 기억을 건드리지 않게)
	static var testing: Bool { ProcessInfo.processInfo.environment["ISQL_AUTOTEST_PORT"] != nil }

	/// 지금 접속해 있는 서버(접속됨·접속 중)와 보고 있는 서버를 적어 둔다
	static func record(connected: [UUID], viewing: UUID?) {
		guard !terminating, !testing else { return }
		d.set(connected.map(\.uuidString), forKey: "lastConnected")
		if let viewing { d.set(viewing.uuidString, forKey: "lastViewed") }
	}

	/// 앱을 열 때 접속할 서버들 (보여 줄 서버가 맨 앞). 저장된 서버만 (비밀번호가 키체인에 있다)
	static func plan(saved: [Server]) -> [Server] {
		var ids = servers
		if d.bool(forKey: reconnectKey) { ids.formUnion(lastConnected) }
		let list = saved.filter { ids.contains($0.id) }
		guard !list.isEmpty else { return [] }
		if let v = lastViewed, let first = list.first(where: { $0.id == v }) {
			return [first] + list.filter { $0.id != v }
		}
		return list
	}
}
