import Foundation
import Darwin

/// 서버의 "접속 허용 IP" 검사 (사용자 2026-11-23).
/// 1) 이 맥의 인터페이스에 공인 IP 가 붙어 있으면 그것으로 비교 (바깥에 묻지 않음)
/// 2) 아니면 내부망(사설 IP)을 쓰는 인터페이스마다 api.ipify.org 에 그 인터페이스로 묻는다 (Wi-Fi · 이더넷 · VPN 이 다른 공인 IP 일 수 있어서)
/// 3) 그래도 없으면 접속하지 않고 macOS 에 등록된 VPN 을 켜라고 안내한다
enum NetworkAccess {
	/// 검사 결과 (화면 · MCP 에 보인다)
	struct Report: Equatable {
		var allowed: Bool
		/// 허용된 IP (어느 인터페이스의 무엇으로 통과했는지)
		var matched: String?
		/// 본 IP 들: "Wi-Fi(en0) 192.168.0.5 → 공인 211.x" 같은 줄
		var seen: [Seen]
		var allowedList: [String]
	}
	struct Seen: Equatable, Hashable {
		var interface: String
		var local: String
		/// 공인 IP (인터페이스에 붙은 것이면 local 과 같음, 물어서 못 알아내면 nil)
		var publicIP: String?
		var asked: Bool
	}

	/// 칸에 적은 글을 목록으로 (쉼표 · 공백 · 줄바꿈으로 나눔)
	static func parseList(_ text: String) -> [String] {
		text.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0 == ";" }).map(String.init).filter { !$0.isEmpty }
	}

	// MARK: 검사

	static func check(_ allowed: [String]) async -> Report {
		let rules = allowed.compactMap(CIDR.init)
		var seen: [Seen] = []
		let locals = localAddresses()
		// 1) 인터페이스에 붙은 공인 IP
		for a in locals where !isPrivate(a.ip) {
			seen.append(Seen(interface: a.interface, local: a.ip, publicIP: a.ip, asked: false))
			if rules.contains(where: { $0.contains(a.ip) }) {
				return Report(allowed: true, matched: "\(a.interface) \(a.ip)", seen: seen, allowedList: allowed)
			}
		}
		// 2) 사설 IPv4 를 쓰는 인터페이스마다 그 인터페이스로 바깥에 묻는다 (동시에)
		let privates = Dictionary(grouping: locals.filter { isPrivate($0.ip) && !$0.ip.contains(":") }, by: \.interface).compactMap { $0.value.first }
		let answers = await withTaskGroup(of: (String, String, String?).self) { g in
			for a in privates { g.addTask { (a.interface, a.ip, await publicIP(via: a.interface)) } }
			var out: [(String, String, String?)] = []
			for await r in g { out.append(r) }
			return out.sorted { $0.0 < $1.0 }
		}
		var matched: String?
		for (iface, local, pub) in answers {
			seen.append(Seen(interface: iface, local: local, publicIP: pub, asked: true))
			if matched == nil, let pub, rules.contains(where: { $0.contains(pub) }) { matched = "\(iface) \(pub)" }
			// 내부망 주소 자체를 허용한 경우 (사설 IP 로 허용한 회사 내부망)
			if matched == nil, rules.contains(where: { $0.contains(local) }) { matched = "\(iface) \(local)" }
		}
		return Report(allowed: matched != nil, matched: matched, seen: seen, allowedList: allowed)
	}

	/// 그 인터페이스로만 나가서 공인 IPv4 를 묻는다 (3초)
	static func publicIP(via interface: String) async -> String? {
		await Task.detached {
			let p = Process()
			p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
			p.arguments = ["-s", "-4", "--max-time", "3", "--interface", interface, "https://api.ipify.org"]
			let out = Pipe()
			p.standardOutput = out
			p.standardError = FileHandle.nullDevice
			do { try p.run() } catch { return nil }
			p.waitUntilExit()
			let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
			return p.terminationStatus == 0 && CIDR(s) != nil ? s : nil
		}.value
	}

	/// 켜져 있는 인터페이스의 주소 (루프백 · 링크 로컬 · AirDrop 같은 것 빼고)
	static func localAddresses() -> [(interface: String, ip: String)] {
		var out: [(String, String)] = []
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return [] }
		defer { freeifaddrs(head) }
		let skip = ["lo", "awdl", "llw", "anpi", "ap", "bridge", "gif", "stf"]
		var p: UnsafeMutablePointer<ifaddrs>? = first
		while let cur = p {
			defer { p = cur.pointee.ifa_next }
			let flags = Int32(cur.pointee.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = cur.pointee.ifa_addr else { continue }
			let name = String(cString: cur.pointee.ifa_name)
			if skip.contains(where: { name.hasPrefix($0) }) { continue }
			let family = Int32(sa.pointee.sa_family)
			guard family == AF_INET || family == AF_INET6 else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
			guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
			var ip = String(cString: host)
			if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
			if ip.lowercased().hasPrefix("fe80") { continue }
			out.append((name, ip))
		}
		return out
	}

	/// 사설 · 내부 주소인지 (공인 IP 가 아님)
	static func isPrivate(_ ip: String) -> Bool {
		let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
		                     "fc00::/7", "fe80::/10", "::1/128"]
		return privateRanges.compactMap(CIDR.init).contains { $0.contains(ip) }
	}

	/// 인터페이스 이름을 사람이 읽게 (en0 → Wi-Fi(en0) 같은 건 시스템에 물어야 해서 utun 만 VPN 으로)
	static func label(_ interface: String) -> String {
		interface.hasPrefix("utun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec") ? "VPN(\(interface))" : interface
	}

	/// 안내 글 (MCP · 화면)
	static func explain(_ r: Report, server: String) -> String {
		var lines = ["지금 이 맥의 IP 가 \(server) 의 접속 허용 IP(\(r.allowedList.joined(separator: ", "))) 가 아닙니다."]
		for s in r.seen {
			lines.append("- \(label(s.interface)): \(s.local)" + (s.asked ? " → 공인 \(s.publicIP ?? "알 수 없음")" : " (공인)"))
		}
		return lines.joined(separator: "\n")
	}

	// MARK: VPN (macOS 시스템 설정 > VPN 에 등록된 것)

	struct VPN: Identifiable, Equatable {
		var id: String
		var name: String
		var status: String
		/// 끝의 [PPP:L2TP] · [IPSec] · [VPN:…]
		var kind = ""
		/// L2TP · PPTP 같은 PPP 방식: scutil 로 켜면 키체인의 공유 암호를 못 읽어 networksetup 으로 켠다
		var isPPP: Bool { kind.hasPrefix("PPP") }
		var connected: Bool { status == "Connected" }
		var connecting: Bool { status == "Connecting" }
	}

	/// `scutil --nc list`
	static func vpnList() async -> [VPN] {
		let text = await run("/usr/sbin/scutil", ["--nc", "list"])
		var out: [VPN] = []
		// 예: * (Disconnected)   1A2B-…  IPSec   "회사 VPN"   [IPSec]
		for line in text.split(separator: "\n") where line.contains("\"") {
			let s = String(line)
			guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")"), open < close,
			      let q1 = s.firstIndex(of: "\""), let q2 = s[s.index(after: q1)...].firstIndex(of: "\"") else { continue }
			let status = String(s[s.index(after: open)..<close])
			let after = s[s.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
			let id = after.first.map(String.init) ?? ""
			var kind = ""
			if let b1 = s.lastIndex(of: "["), let b2 = s.lastIndex(of: "]"), b1 < b2 { kind = String(s[s.index(after: b1)..<b2]) }
			out.append(VPN(id: id, name: String(s[s.index(after: q1)..<q2]), status: status, kind: kind))
		}
		return out
	}

	/// 켜기. L2TP 같은 PPP 방식을 `scutil --nc start` 로 켜면 "IPSec 공유 비밀이 없습니다" 가 뜬다 (키체인의 공유 암호를 못 읽음) →
	/// `networksetup -connectpppoeservice` 는 시스템 설정에서 켤 때처럼 저장된 암호를 쓴다 (사용자 2026-11-23 확인)
	static func start(_ vpn: VPN) async {
		if vpn.isPPP { _ = await run("/usr/sbin/networksetup", ["-connectpppoeservice", vpn.name]) }
		else { _ = await run("/usr/sbin/scutil", ["--nc", "start", vpn.id]) }
	}

	static func stop(_ vpn: VPN) async {
		if vpn.isPPP { _ = await run("/usr/sbin/networksetup", ["-disconnectpppoeservice", vpn.name]) }
		else { _ = await run("/usr/sbin/scutil", ["--nc", "stop", vpn.id]) }
	}

	private static func run(_ path: String, _ args: [String]) async -> String {
		await Task.detached {
			let p = Process()
			p.executableURL = URL(fileURLWithPath: path)
			p.arguments = args
			let out = Pipe()
			p.standardOutput = out
			p.standardError = FileHandle.nullDevice
			do { try p.run() } catch { return "" }
			p.waitUntilExit()
			return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		}.value
	}
}

/// IP 범위 (203.0.113.10, 10.0.0.0/8, 2001:db8::/32)
struct CIDR {
	let bytes: [UInt8]
	let prefix: Int

	init?(_ text: String) {
		let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
		guard let ip = parts.first, let b = CIDR.parse(ip) else { return nil }
		bytes = b
		if parts.count == 2 {
			guard let p = Int(parts[1]), p >= 0, p <= b.count * 8 else { return nil }
			prefix = p
		} else {
			prefix = b.count * 8
		}
	}

	func contains(_ ip: String) -> Bool {
		guard let b = CIDR.parse(ip), b.count == bytes.count else { return false }
		var left = prefix
		for i in 0..<bytes.count {
			guard left > 0 else { return true }
			let bits = min(8, left)
			// UInt8 끼리 밀어야 한다: Int 로 0xFF << n 을 UInt8 로 바꾸면 넘쳐서 앱이 죽었다 (/7 · /10 · /12, fdab:… 같은 IPv6 가 있는 맥, 2.7 (204))
			let mask: UInt8 = UInt8.max << UInt8(8 - bits)
			if b[i] & mask != bytes[i] & mask { return false }
			left -= bits
		}
		return true
	}

	static func parse(_ ip: String) -> [UInt8]? {
		var v4 = in_addr()
		if inet_pton(AF_INET, ip, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
		var v6 = in6_addr()
		if inet_pton(AF_INET6, ip, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
		return nil
	}
}
