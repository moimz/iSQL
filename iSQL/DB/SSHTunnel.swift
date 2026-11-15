import Foundation
import Darwin

/// 시스템 ssh(/usr/bin/ssh)로 로컬 포트 포워딩을 띄운다.
/// ~/.ssh/config, ssh-agent, 키체인에 저장한 키 암호(UseKeychain)를 그대로 쓰려고 직접 SSH 를 구현하지 않는다.
/// 비밀번호·키 암호가 필요하면 ssh 가 이 앱을 SSH_ASKPASS 로 다시 띄우고, 그때 앱이 키체인에서 꺼내 준다 (Askpass.run).
final class SSHTunnel: @unchecked Sendable {
	let localPort: UInt16
	private let process: Process
	private let stderr = Pipe()
	private var errorText = ""
	private let lock = NSLock()

	var isRunning: Bool { process.isRunning }

	private init(process: Process, localPort: UInt16) {
		self.process = process
		self.localPort = localPort
	}

	enum TunnelError: LocalizedError {
		case failed(String)
		case timeout
		var errorDescription: String? {
			switch self {
			case .failed(let s): "SSH 터널을 열지 못했습니다.\n\(s)"
			case .timeout: "SSH 터널을 여는 데 너무 오래 걸립니다 (20초)."
			}
		}
	}

	/// 터널을 열고 로컬 포트가 받을 수 있게 될 때까지 기다린다
	/// secret: SSH 비밀번호나 키 암호 (없으면 nil). 잠깐 쓰는 키체인 항목에 넣어 askpass 가 꺼내 가게 하고, 터널이 열리면 지운다
	static func open(_ server: Server, secret: String?) async throws -> SSHTunnel {
		let port = try freePort()
		let ssh = server.ssh
		var args = [
			"-N",
			"-L", "127.0.0.1:\(port):\(server.host):\(server.port)",
			"-o", "ExitOnForwardFailure=yes",
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ServerAliveInterval=30",
			"-o", "ServerAliveCountMax=3",
			"-o", "ConnectTimeout=15",
			"-o", "NumberOfPasswordPrompts=1",
		]
		if ssh.port != 22 { args += ["-p", String(ssh.port)] }
		if !ssh.user.isEmpty { args += ["-l", ssh.user] }

		var env = ProcessInfo.processInfo.environment
		let askAccount = "askpass/\(UUID().uuidString)"
		switch ssh.auth {
		case .key:
			if !ssh.keyPath.isEmpty {
				args += ["-i", (ssh.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
			}
			if secret == nil {
				// 키 암호를 저장하지 않았으면 물어볼 곳이 없으니 묻지 않게 한다 (UseKeychain 으로 저장된 암호는 그대로 쓰인다)
				args += ["-o", "BatchMode=yes"]
			}
		case .password:
			args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
		}
		if secret != nil {
			env["SSH_ASKPASS"] = Bundle.main.executablePath
			env["SSH_ASKPASS_REQUIRE"] = "force"
			env[Askpass.accountKey] = askAccount
			Keychain.set(secret, for: askAccount)
		}
		defer { if secret != nil { Keychain.delete(askAccount) } }
		args.append(ssh.host)

		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		p.arguments = args
		p.environment = env
		p.standardInput = FileHandle.nullDevice
		p.standardOutput = FileHandle.nullDevice
		let tunnel = SSHTunnel(process: p, localPort: port)
		p.standardError = tunnel.stderr
		tunnel.stderr.fileHandleForReading.readabilityHandler = { [weak tunnel] h in
			let d = h.availableData
			guard let tunnel, !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
			tunnel.lock.withLock { tunnel.errorText += s }
		}
		try p.run()
		TunnelRegistry.add(p.processIdentifier)

		let deadline = Date().addingTimeInterval(20)
		while Date() < deadline {
			if !p.isRunning {
				TunnelRegistry.remove(p.processIdentifier)
				try? await Task.sleep(for: .milliseconds(100))   // 남은 에러 글을 마저 읽는다
				throw TunnelError.failed(tunnel.cleanError())
			}
			if canConnect(port) { return tunnel }
			try await Task.sleep(for: .milliseconds(150))
		}
		tunnel.close()
		throw TunnelError.timeout
	}

	func close() {
		stderr.fileHandleForReading.readabilityHandler = nil
		if process.isRunning { process.terminate() }
		TunnelRegistry.remove(process.processIdentifier)
	}

	deinit { close() }

	private func cleanError() -> String {
		let text = lock.withLock { errorText }
		let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
		return lines.isEmpty ? "ssh 가 종료 코드 \(process.terminationStatus) 로 끝났습니다." : lines.joined(separator: "\n")
	}

	/// 비어 있는 로컬 포트 하나를 고른다
	private static func freePort() throws -> UInt16 {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		guard fd >= 0 else { throw TunnelError.failed("로컬 포트를 고르지 못했습니다.") }
		defer { Darwin.close(fd) }
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_addr.s_addr = inet_addr("127.0.0.1")
		addr.sin_port = 0
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		let ok = withUnsafeMutablePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
		}
		guard ok else { throw TunnelError.failed("로컬 포트를 고르지 못했습니다.") }
		return UInt16(bigEndian: addr.sin_port)
	}

	private static func canConnect(_ port: UInt16) -> Bool {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		guard fd >= 0 else { return false }
		defer { Darwin.close(fd) }
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_addr.s_addr = inet_addr("127.0.0.1")
		addr.sin_port = port.bigEndian
		return withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
		}
	}
}

/// ssh 가 SSH_ASKPASS 로 이 앱을 띄웠을 때: 창을 띄우지 않고 키체인의 비밀번호를 표준출력으로 주고 끝낸다
enum Askpass {
	static let accountKey = "ISQL_ASKPASS_ACCOUNT"

	/// askpass 로 불린 경우면 처리하고 true
	static func runIfNeeded() -> Bool {
		guard let account = ProcessInfo.processInfo.environment[accountKey] else { return false }
		// 호스트 키 확인 같은 예/아니오 질문에는 답하지 않는다 (accept-new 로 처리)
		let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
		if prompt.contains("yes/no") { exit(1) }
		guard let secret = Keychain.get(account) else { exit(1) }
		FileHandle.standardOutput.write(Data((secret + "\n").utf8))
		exit(0)
	}
}

/// 앱이 띄운 ssh 터널 번호를 "터널번호 앱번호" 로 파일에 적어 둔다.
/// 앱이 끝날 때 자기 터널을 끄고, 시작할 때는 띄운 앱이 이미 죽은 터널만 끈다
/// (ssh 는 부모가 죽어도 혼자 남는다. iSQL 이 두 개 떠 있어도 서로의 터널은 건드리지 않는다)
enum TunnelRegistry {
	private static let lock = NSLock()
	private static let me = getpid()
	private static var file: URL {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iSQL", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("tunnels.pid")
	}

	private struct Entry: Hashable { var tunnel: Int32; var owner: Int32 }

	private static func read() -> Set<Entry> {
		guard let s = try? String(contentsOf: file, encoding: .utf8) else { return [] }
		return Set(s.split(separator: "\n").compactMap { line in
			let p = line.split(separator: " ").compactMap { Int32($0) }
			guard let t = p.first else { return nil }
			return Entry(tunnel: t, owner: p.count > 1 ? p[1] : 0)   // 예전 형식(번호만)은 주인 모름 = 0
		})
	}

	private static func write(_ e: Set<Entry>) {
		try? e.map { "\($0.tunnel) \($0.owner)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
	}

	static func add(_ pid: Int32) { lock.withLock { var e = read(); e.insert(Entry(tunnel: pid, owner: me)); write(e) } }
	static func remove(_ pid: Int32) { lock.withLock { write(read().filter { $0.tunnel != pid }) } }

	/// 시작할 때: 띄운 앱이 이미 없는 터널만 끈다
	static func killOrphans() {
		lock.withLock {
			var keep = Set<Entry>()
			for e in read() {
				if e.owner != 0 && e.owner != me && isAlive(e.owner) { keep.insert(e); continue }
				if isSSH(e.tunnel) { kill(e.tunnel, SIGTERM) }
			}
			write(keep)
		}
	}

	/// 끝날 때: 이 앱이 띄운 터널만 끈다
	static func killMine() {
		lock.withLock {
			var keep = Set<Entry>()
			for e in read() {
				if e.owner == me { if isSSH(e.tunnel) { kill(e.tunnel, SIGTERM) } } else { keep.insert(e) }
			}
			write(keep)
		}
	}

	private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

	private static func isSSH(_ pid: Int32) -> Bool {
		var buf = [CChar](repeating: 0, count: 4096)
		guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
		return String(cString: buf) == "/usr/bin/ssh"
	}
}
