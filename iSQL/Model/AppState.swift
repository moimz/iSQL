import Foundation
import AppKit

/// 앱 전체에서 하나: 서버 목록, 열린 창들(창마다 WindowModel), 지금 앞에 있는 창.
/// MCP 가 "지금 보고 있는 창의 서버 / 접속한 모든 서버 / 목록의 모든 서버" 를 고를 때 쓴다
@MainActor
final class AppState {
	static let shared = AppState()

	weak var store: ServerStore?
	/// 마지막으로 앞에 온(키) 창
	weak var activeModel: WindowModel?

	private final class WeakModel { weak var model: WindowModel?; init(_ m: WindowModel) { model = m } }
	private var models: [WeakModel] = []

	func register(_ m: WindowModel) {
		models.removeAll { $0.model == nil }
		if !models.contains(where: { $0.model === m }) { models.append(WeakModel(m)) }
		if activeModel == nil { activeModel = m }
	}

	/// 파일 메뉴 → 서버 내보내기·가져오기: 앞에 있는 창에 시트를 띄운다 (창이 없으면 삑)
	func requestTransfer(_ r: ServerTransferRequest) {
		guard let m = activeModel ?? allModels.first else { NSSound.beep(); return }
		m.transfer = r
	}

	var allModels: [WindowModel] {
		models.removeAll { $0.model == nil }
		return models.compactMap(\.model)
	}

	/// 모든 창에서 접속한 세션 (같은 서버가 두 창에 있으면 하나만)
	var connectedSessions: [Session] {
		var seen = Set<UUID>()
		var out: [Session] = []
		for m in allModels {
			for s in m.sessions.values where s.isConnected {
				guard let id = s.server?.id, seen.insert(id).inserted else { continue }
				out.append(s)
			}
		}
		return out
	}

	/// 지금 앞에 있는 창에서 보고 있는 서버
	var activeSession: Session? {
		guard let s = activeModel?.current, s.isConnected else { return nil }
		return s
	}
}
