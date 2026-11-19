import Foundation

/// 서버 목록 파일을 둘 곳 (iFont 와 같은 방식).
/// iCloud 를 쓸 수 있으면 iCloud Drive 의 앱 전용 폴더(iCloud.com.moimz.iSQL/Data/Servers, Finder 에는 안 보임), 아니면 이 맥 Application Support/iSQL/Servers.
/// 서버마다 <UUID>.json 하나씩 둬서 두 맥에서 서로 다른 서버를 고쳐도 부딪히지 않는다.
final class StorageLocation: @unchecked Sendable {
	static let containerID = "iCloud.com.moimz.iSQL"
	static let shared = StorageLocation()

	let servers: URL
	/// 그룹 이름과 순서 (서버가 없는 그룹도 있다)
	let groups: URL
	/// 서버마다 쿼리 편집기 내용 (<UUID>.sql). 두 맥이 같이 쓴다 (즐겨찾기 대신, 사용자 2026-11-17)
	let queries: URL
	let isCloud: Bool

	static let local: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("iSQL", isDirectory: true)

	private init() {
		let fm = FileManager.default
		var cloud: URL?
		if fm.ubiquityIdentityToken != nil, let c = fm.url(forUbiquityContainerIdentifier: Self.containerID) {
			cloud = c.appendingPathComponent("Data", isDirectory: true)
		}
		var root = cloud ?? Self.local
		var override = false
		#if DEBUG
		// 시험용(스크린샷 등): ISQL_DATA_DIR=<폴더> 면 그 폴더를 저장 위치로 (실제 서버 목록을 건드리지도 보이지도 않게). 배포판에는 없다
		if let d = ProcessInfo.processInfo.environment["ISQL_DATA_DIR"], !d.isEmpty {
			root = URL(fileURLWithPath: d, isDirectory: true)
			override = true
		}
		#endif
		servers = root.appendingPathComponent("Servers", isDirectory: true)
		groups = root.appendingPathComponent("groups.json")
		queries = root.appendingPathComponent("Queries", isDirectory: true)
		isCloud = cloud != nil
		try? fm.createDirectory(at: servers, withIntermediateDirectories: true)
		try? fm.createDirectory(at: queries, withIntermediateDirectories: true)
		if isCloud && !override { migrateLocal() }
	}

	/// iCloud 를 못 쓰던 때 이 맥에 만든 서버를 한 번 올린다
	private func migrateLocal() {
		let fm = FileManager.default
		let src = Self.local.appendingPathComponent("Servers")
		let marker = Self.local.appendingPathComponent("moved-to-icloud")
		guard !fm.fileExists(atPath: marker.path), fm.fileExists(atPath: src.path) else { return }
		for file in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
			let dst = servers.appendingPathComponent(file.lastPathComponent)
			if !fm.fileExists(atPath: dst.path), let data = try? Data(contentsOf: file) { Self.write(data, to: dst) }
		}
		try? "이 폴더의 서버를 \(Date()) 에 iCloud 로 옮겼습니다. 이 폴더는 백업입니다.\n".write(to: marker, atomically: true, encoding: .utf8)
	}

	/// 아직 내려받지 않은 파일(.이름.json.icloud)의 id. 다시 읽을 때 지워진 것으로 보지 않는다
	func placeholderIDs() -> Set<UUID> {
		guard isCloud else { return [] }
		let names = (try? FileManager.default.contentsOfDirectory(atPath: servers.path)) ?? []
		return Set(names.compactMap { n in
			guard n.hasPrefix("."), n.hasSuffix(".json.icloud") else { return nil }
			return UUID(uuidString: String(n.dropFirst().dropLast(".json.icloud".count)))
		})
	}

	func downloadAll() {
		for id in placeholderIDs() {
			try? FileManager.default.startDownloadingUbiquitousItem(at: servers.appendingPathComponent(id.uuidString + ".json"))
		}
	}

	/// iCloud 가 함께 쓰는 파일이라 조율해서 쓴다
	static func write(_ data: Data, to target: URL) {
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { u in
			try? data.write(to: u, options: .atomic)
		}
	}

	static func remove(_ target: URL) {
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &error) { u in
			try? FileManager.default.removeItem(at: u)
		}
	}
}

/// 다른 맥에서 바뀐 iCloud 파일을 지켜본다: 안 받은 파일은 받고, 충돌은 최근 것으로 정리하고, 바뀌면 알려 준다
final class CloudWatcher: NSObject, @unchecked Sendable {
	static let shared = CloudWatcher()
	/// iCloud 파일이 바뀌었다 (쿼리 편집기가 다른 맥 내용을 받아 넣는다)
	static let didChange = Notification.Name("iSQLCloudDidChange")
	private let query = NSMetadataQuery()
	private var onChange: (() -> Void)?
	private var pending: DispatchWorkItem?

	func start(onChange: @escaping () -> Void) {
		guard StorageLocation.shared.isCloud else { return }
		self.onChange = onChange
		query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
		query.predicate = NSPredicate(format: "%K LIKE '*.json' OR %K LIKE '*.sql'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
		NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidFinishGathering, object: query)
		NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidUpdate, object: query)
		query.start()
	}

	@objc private func changed() {
		query.disableUpdates()
		for i in 0..<query.resultCount {
			guard let item = query.result(at: i) as? NSMetadataItem, let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
			let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
			if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
				try? FileManager.default.startDownloadingUbiquitousItem(at: url)
			}
			if (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) == true {
				Self.resolveConflicts(url)
			}
		}
		query.enableUpdates()
		pending?.cancel()
		let work = DispatchWorkItem { [weak self] in
			self?.onChange?()
			NotificationCenter.default.post(name: CloudWatcher.didChange, object: nil)
		}
		pending = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	}

	/// 두 맥에서 같은 파일을 고쳤으면 가장 최근에 고친 것을 남긴다
	static func resolveConflicts(_ url: URL) {
		guard let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !others.isEmpty,
		      let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
		let newest = (others + [current]).max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }!
		if newest != current { _ = try? newest.replaceItem(at: url) }
		for v in others { v.isResolved = true }
		try? NSFileVersion.removeOtherVersionsOfItem(at: url)
	}
}

/// 서버별 쿼리 편집기 내용 파일 (StorageLocation.queries/<UUID>.sql)
enum QueryStore {
	static func url(_ id: UUID) -> URL { StorageLocation.shared.queries.appendingPathComponent(id.uuidString + ".sql") }

	/// 파일 내용. 없으면 nil (아직 안 받은 파일이면 받기를 시작하고 nil — 받으면 CloudWatcher 가 알려 준다)
	static func read(_ id: UUID) -> String? {
		let u = url(id)
		let fm = FileManager.default
		if !fm.fileExists(atPath: u.path) {
			let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
			if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: u) }
			return nil
		}
		var out: String?
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &error) { r in
			out = try? String(contentsOf: r, encoding: .utf8)
		}
		return out
	}

	static func write(_ id: UUID, _ text: String) {
		StorageLocation.write(Data(text.utf8), to: url(id))
	}

	static func remove(_ id: UUID) { StorageLocation.remove(url(id)) }
}
