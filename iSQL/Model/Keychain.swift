import Foundation
import Security

/// 비밀번호(MySQL, SSH 비밀번호, SSH 키 암호)는 전부 여기에만 둔다. 서버 파일에는 한 글자도 쓰지 않는다.
/// iCloud 키체인(동기화 항목)에 넣어서 다른 맥에서도 다시 입력할 필요가 없게 한다.
/// 서명이 없어 iCloud 키체인을 못 쓰면(Xcode 로 그냥 돌릴 때 등) 이 맥 로그인 키체인에 넣고, 그 사실을 화면에 보여 준다.
enum Keychain {
	static let service = "com.moimz.iSQL"

	enum Mode { case unknown, iCloud, localOnly }
	/// 마지막으로 쓴 방식 (화면 표시용)
	nonisolated(unsafe) static var mode: Mode = .unknown

	private static func base(_ account: String, cloud: Bool) -> [String: Any] {
		var q: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		if cloud {
			q[kSecUseDataProtectionKeychain as String] = true
			q[kSecAttrSynchronizable as String] = true
		}
		return q
	}

	static func get(_ account: String) -> String? {
		for cloud in [true, false] {
			var q = base(account, cloud: cloud)
			if cloud { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
			q[kSecReturnData as String] = true
			q[kSecMatchLimit as String] = kSecMatchLimitOne
			var out: CFTypeRef?
			if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
				return String(data: data, encoding: .utf8)
			}
		}
		return nil
	}

	/// nil 이나 빈 문자열이면 지운다
	@discardableResult
	static func set(_ value: String?, for account: String) -> Bool {
		guard let value, !value.isEmpty else { delete(account); return true }
		let data = Data(value.utf8)
		if write(data, account, cloud: true) {
			mode = .iCloud
			// 예전에 이 맥에만 넣어 둔 것이 있으면 지운다 (두 곳에 남지 않게)
			SecItemDelete(base(account, cloud: false) as CFDictionary)
			return true
		}
		if write(data, account, cloud: false) { mode = .localOnly; return true }
		return false
	}

	private static func write(_ data: Data, _ account: String, cloud: Bool) -> Bool {
		let q = base(account, cloud: cloud)
		let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecSuccess { return true }
		if status != errSecItemNotFound { return false }
		var add = q
		add[kSecValueData as String] = data
		add[kSecAttrLabel as String] = "iSQL"
		if cloud { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
		return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
	}

	static func delete(_ account: String) {
		var q = base(account, cloud: true)
		q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
		SecItemDelete(q as CFDictionary)
		SecItemDelete(base(account, cloud: false) as CFDictionary)
	}

	/// iCloud 키체인을 쓸 수 있는지 시험 삼아 한 번 써 본다 (앱 시작 때)
	static func probe() {
		let account = "probe"
		if write(Data("1".utf8), account, cloud: true) {
			mode = .iCloud
			var q = base(account, cloud: true)
			q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
			SecItemDelete(q as CFDictionary)
		} else {
			mode = .localOnly
		}
	}
}
