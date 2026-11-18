import AppKit
import UniformTypeIdentifiers

/// SQLite 파일 알아보기·고르기·열기 (확장자는 정해져 있지 않아 파일 머리 16바이트로 가린다)
enum SQLiteFile {
	/// 흔한 확장자 (Info.plist 의 UTImportedTypeDeclarations 와 같게)
	static let extensions = ["sqlite", "sqlite3", "db", "db3", "s3db", "sl3"]
	static let type = UTType(importedAs: "org.sqlite.sqlite3")
	/// 고르기 창에 걸 종류 (확장자마다 시스템이 다른 종류로 볼 수도 있어 확장자로도)
	static var contentTypes: [UTType] { [type] + extensions.compactMap { UTType(filenameExtension: $0) } }

	/// SQLite 파일인지: 머리가 "SQLite format 3\0" 이거나 빈 파일 (sqlite3 이 빈 파일을 새 DB 로 연다)
	static func isSQLite(_ url: URL) -> Bool {
		guard let h = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? h.close() }
		let head = (try? h.read(upToCount: 16)) ?? Data()
		return head.isEmpty || head == Data("SQLite format 3\0".utf8)
	}

	/// 고르기 창: SQLite 확장자만, 아래 "모든 파일 보기" 로 다른 확장자도
	static func openPanel() -> NSOpenPanel {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		panel.message = "SQLite 파일을 고르세요"
		panel.allowedContentTypes = contentTypes
		let all = AllFilesToggle(panel: panel)
		panel.accessoryView = all.button
		panel.isAccessoryViewDisclosed = true
		objc_setAssociatedObject(panel, &AllFilesToggle.key, all, .OBJC_ASSOCIATION_RETAIN)
		return panel
	}

	/// SQLite 가 아니면 알리고 false
	static func checkOrAlert(_ url: URL) -> Bool {
		if isSQLite(url) { return true }
		let a = NSAlert()
		a.messageText = "SQLite 파일이 아닙니다"
		a.informativeText = "\(url.lastPathComponent) 은(는) SQLite 데이터베이스 파일이 아닙니다."
		a.runModal()
		return false
	}

	/// 동기화 폴더면 한 번 묻는다 (사용자 2026-11-18). 계속하면 true
	static func confirmSyncedFolder(_ url: URL, create: Bool) -> Bool {
		guard Server.isInSyncedFolder(url.path) else { return true }
		let a = NSAlert()
		a.messageText = "동기화되는 폴더의 파일입니다"
		a.informativeText = "iCloud Drive·Dropbox 처럼 실시간으로 동기화되는 폴더의 SQLite 파일은, 열어 둔 채 고치면 동기화가 중간 상태(-wal·-journal 파일)를 옮겨 파일이 깨질 수 있습니다. 동기화되지 않는 폴더를 권합니다."
		a.addButton(withTitle: create ? "그래도 만들기" : "그래도 쓰기")
		a.addButton(withTitle: "취소")
		return a.runModal() == .alertFirstButtonReturn
	}

	/// 그 파일을 쓰는 저장한 서버 (이 맥 경로로 견준다)
	static func server(for url: URL, in servers: [Server]) -> Server? {
		let p = url.standardizedFileURL.resolvingSymlinksInPath().path
		return servers.first { s in
			guard s.isFileDB, let sp = s.sqliteFilePath else { return false }
			return URL(fileURLWithPath: sp).standardizedFileURL.resolvingSymlinksInPath().path == p
		}
	}

	// MARK: - 기본 앱 (앱 설정 > 일반)

	/// 지금 SQLite 파일을 여는 기본 앱
	static var defaultApp: URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }
	static var isDefaultApp: Bool {
		guard let app = defaultApp else { return false }
		return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
	}
	/// iSQL 을 기본 앱으로 (macOS 가 한 번 확인을 묻는다). 확장자마다 시스템이 다른 종류로 보는 것도 같이
	static func makeDefault() async throws {
		var seen = Set<String>()
		for t in contentTypes where seen.insert(t.identifier).inserted {
			try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: t)
		}
	}
}

/// 고르기 창 아래 "모든 파일 보기" 체크 상자
private final class AllFilesToggle: NSObject {
	static var key = 0
	weak var panel: NSOpenPanel?
	let button: NSButton

	init(panel: NSOpenPanel) {
		self.panel = panel
		button = NSButton(checkboxWithTitle: "모든 파일 보기 (확장자가 다른 SQLite 파일)", target: nil, action: nil)
		super.init()
		button.target = self
		button.action = #selector(toggled)
		button.sizeToFit()
		button.frame.size.height += 16
	}

	@objc private func toggled() {
		panel?.allowedContentTypes = button.state == .on ? [] : SQLiteFile.contentTypes
	}
}
