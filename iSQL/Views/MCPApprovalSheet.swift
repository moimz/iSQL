import SwiftUI
import AppKit

/// MCP 가 "안전한 쿼리만 자동 허용" 을 넘는 쿼리를 실행하려 할 때 묻는 제목바 시트 (사용자 2026-11-23).
/// 답(허용 · 거절)을 받을 때까지 MCP 요청은 기다린다. 2분 동안 답이 없으면 거절. 여러 요청이 오면 하나씩 묻는다
@MainActor
enum MCPApproval {
	struct Request {
		let server: String
		let database: String?
		/// 권한 밖 문장 (이것을 허용할지 묻는다)
		let blocked: [String]
		/// 실행할 문장 전체 수
		let total: Int
		let syntax: SQLSyntax
	}

	/// 하나씩 묻게 줄을 세운다
	private static var queue: Task<Bool, Never>?

	static func ask(_ r: Request, window: NSWindow?) async -> Bool {
		let prev = queue
		let t = Task { @MainActor () -> Bool in
			_ = await prev?.value
			return await present(r, window: window)
		}
		queue = t
		return await t.value
	}

	private static func present(_ r: Request, window: NSWindow?) async -> Bool {
		NSApp.activate()
		return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
			var done = false
			let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
			let host = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
			func finish(_ ok: Bool) {
				guard !done else { return }
				done = true
				if let host, panel.sheetParent != nil { host.endSheet(panel) } else { panel.orderOut(nil) }
				cont.resume(returning: ok)
			}
			panel.contentViewController = NSHostingController(rootView: MCPApprovalView(request: r, answer: finish))
			if let host { host.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
			// 답이 없으면 2분 뒤 거절 (MCP 요청이 끝없이 매달리지 않게)
			DispatchQueue.main.asyncAfter(deadline: .now() + 120) { finish(false) }
		}
	}
}

private struct MCPApprovalView: View {
	let request: MCPApproval.Request
	let answer: (Bool) -> Void

	/// 종류별 개수 (WHERE 없는 UPDATE 3개, DELETE 80개 …)
	private var summary: String {
		var counts: [(String, Int)] = []
		for s in request.blocked {
			let k = SQLSplitter.danger(s, request.syntax) ?? firstWord(s)
			if let i = counts.firstIndex(where: { $0.0 == k }) { counts[i].1 += 1 } else { counts.append((k, 1)) }
		}
		return counts.map { "\($0.0) \($0.1)개" }.joined(separator: ", ")
	}

	private func firstWord(_ s: String) -> String {
		SQLSplitter.stripComments(s, request.syntax).trimmingCharacters(in: .whitespacesAndNewlines)
			.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map { String($0).uppercased() } ?? "SQL"
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 10) {
				Image(systemName: "exclamationmark.shield.fill").font(.system(size: 28)).foregroundStyle(.orange)
				VStack(alignment: .leading, spacing: 3) {
					Text("AI(MCP)가 자동 허용 밖의 쿼리를 실행하려 합니다").font(.headline)
					Text(request.server + (request.database.map { $0.isEmpty ? "" : " · " + $0 } ?? "")).foregroundStyle(.secondary)
					Text("허용 밖 \(request.blocked.count)개 (전체 \(request.total)개 중): \(summary)").font(.callout)
				}
			}
			// 문장이 많아도 버튼이 밀리지 않게 스크롤 칸
			ScrollView {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(Array(request.blocked.prefix(500).enumerated()), id: \.offset) { _, s in
						Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
							.font(.system(size: 11.5, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					if request.blocked.count > 500 { Text("… 외 \(request.blocked.count - 500)개").foregroundStyle(.secondary) }
				}
				.padding(10)
			}
			.frame(height: 220)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
			Text("허용하면 이번 요청의 문장을 모두 실행합니다. 2분 안에 답하지 않으면 거절합니다.").font(.caption).foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button("거절") { answer(false) }.keyboardShortcut(.cancelAction)
				Button("이번만 허용") { answer(true) }.buttonStyle(.borderedProminent)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 560)
	}
}
