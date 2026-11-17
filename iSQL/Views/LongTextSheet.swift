import SwiftUI
import AppKit

/// 여러 줄 글자·JSON 칸 편집 (창 제목바 시트). 칸 안에서는 줄바꿈을 넣기 어려워서 따로 연다.
/// JSON 편집기: 열면 보기 좋게 펼치고 색칠, 틀리면 줄·칸을 짚는다. 저장은 안 고쳤으면 원본 그대로,
/// 고쳤으면 원래 모양(한 줄·공백·들여쓰기)을 따라간다 — varchar·text 는 글자 그대로 저장돼서 공백이 바뀌면 글자 비교하는 곳이 깨질 수 있다.
/// JSON 컬럼은 서버가 다시 쓰므로 한 줄로 (사용자 2026-11-17)
struct LongTextSheet: View {
	let request: LongEditRequest
	let table: TableInfo
	let apply: (Value) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var text: String
	@State private var jsonMode: Bool
	/// 커서를 옮길 자리 (틀린 곳 누르기)
	@State private var jump: Int?

	init(request: LongEditRequest, table: TableInfo, apply: @escaping (Value) -> Void) {
		self.request = request
		self.table = table
		self.apply = apply
		let json = request.isJSON && JSONFormat.check(request.text) == nil
		_jsonMode = State(initialValue: request.isJSON)
		_text = State(initialValue: json ? (JSONFormat.pretty(request.text) ?? request.text) : request.text)
	}

	/// JSON 편집기에서 틀린 곳 (nil 이면 올바름)
	private var jsonError: JSONFormat.Problem? {
		guard jsonMode, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return JSONFormat.check(text)
	}

	/// 글자 편집 중인데 JSON 처럼 보이고 올바르면 [JSON 편집기로]
	private var canSwitchToJSON: Bool { !jsonMode && JSONFormat.looksLikeJSON(text) && JSONFormat.check(text) == nil }

	/// 저장할 글: 안 고쳤으면 원본, 고쳤으면 원래 모양을 따라간다
	private var output: String {
		guard jsonMode else { return text }
		if let a = JSONFormat.compact(text), let b = JSONFormat.compact(request.text), a == b { return request.text }
		if request.jsonColumn { return JSONFormat.compact(text) ?? text }
		return JSONFormat.restyle(text, like: request.text) ?? text
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Text("\(table.name).\(request.column)").font(.headline)
				if jsonMode { Text("JSON").font(.caption.weight(.semibold)).foregroundStyle(.teal) }
				if request.wasNull { Text("지금 NULL").font(.callout).foregroundStyle(.secondary) }
				Spacer()
				Text("\(text.count.formatted())자 · \(text.split(separator: "\n", omittingEmptySubsequences: false).count.formatted())줄")
					.font(.callout).foregroundStyle(.secondary).monospacedDigit()
			}
			CodeTextView(text: $text, json: jsonMode, jump: $jump)
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
				.frame(minHeight: 320)
			HStack(spacing: 10) {
				if jsonMode {
					if let e = jsonError {
						Button { jump = e.offset } label: {
							Label(e.line > 0 ? "\(e.line)줄 \(e.column)칸: \(e.message)" : e.message, systemImage: "exclamationmark.triangle.fill")
								.foregroundStyle(.orange).lineLimit(2)
						}
						.buttonStyle(.plain)
						.help("눌러서 그 자리로")
					} else if !text.isEmpty {
						Label("올바른 JSON", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
					}
					Spacer()
					if !request.jsonColumn {
						Button("일반 글자로 편집") {
							// 원래 모양으로 돌려 놓고 글자 편집 (틀린 JSON 이면 그대로)
							if jsonError == nil { text = output }
							jsonMode = false
						}
						.help("JSON 규칙과 상관없이 글자 그대로 고칩니다")
					}
				} else {
					Spacer()
					if canSwitchToJSON {
						Button("JSON 편집기로") {
							text = JSONFormat.pretty(text) ?? text
							jsonMode = true
						}
						.help("JSON 처럼 보입니다. 보기 좋게 펼쳐 고치고, 저장할 때 원래 모양으로 돌려 놓습니다")
					}
				}
			}
			.font(.callout)
			HStack {
				Button("NULL 로") { apply(.null); dismiss() }
					.help("이 칸을 NULL 로 (NOT NULL 컬럼이면 저장할 때 서버가 거절합니다)")
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("적용") { apply(.text(output)); dismiss() }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.return, modifiers: .command)
					.disabled(jsonError != nil)
					.help(jsonError != nil ? "틀린 JSON 은 적용하지 않습니다 (일반 글자로 편집하면 그대로 넣을 수 있습니다)" : "적용 (⌘↩). 저장(⌘S)해야 서버에 반영됩니다")
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(minWidth: 680, idealWidth: 760, minHeight: 460)
	}
}

/// 고정폭 글자 편집 칸 (NSTextView). JSON 이면 색칠, jump 로 커서를 옮긴다
struct CodeTextView: NSViewRepresentable {
	@Binding var text: String
	var json: Bool
	@Binding var jump: Int?

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSTextView.scrollableTextView()
		let tv = scroll.documentView as! NSTextView
		tv.isRichText = false
		tv.allowsUndo = true
		tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
		tv.textColor = .labelColor
		tv.drawsBackground = false
		scroll.drawsBackground = false
		tv.isAutomaticQuoteSubstitutionEnabled = false
		tv.isAutomaticDashSubstitutionEnabled = false
		tv.isAutomaticTextReplacementEnabled = false
		tv.isAutomaticSpellingCorrectionEnabled = false
		tv.isContinuousSpellCheckingEnabled = false
		tv.textContainerInset = NSSize(width: 6, height: 8)
		tv.string = text
		tv.delegate = context.coordinator
		context.coordinator.textView = tv
		context.coordinator.recolor()
		DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		let c = context.coordinator
		let modeChanged = c.parent.json != json
		c.parent = self
		guard let tv = c.textView else { return }
		if tv.string != text { tv.string = text; c.recolor() } else if modeChanged { c.recolor() }
		if let j = jump {
			let p = min(max(0, j), (tv.string as NSString).length)
			tv.setSelectedRange(NSRange(location: p, length: 0))
			tv.scrollRangeToVisible(NSRange(location: p, length: 0))
			tv.window?.makeFirstResponder(tv)
			DispatchQueue.main.async { jump = nil }
		}
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: CodeTextView
		weak var textView: NSTextView?
		init(_ p: CodeTextView) { parent = p }

		func textDidChange(_ notification: Notification) {
			guard let tv = textView else { return }
			parent.text = tv.string
			recolor()
		}

		func recolor() {
			guard let tv = textView, let storage = tv.textStorage else { return }
			let all = NSRange(location: 0, length: storage.length)
			storage.beginEditing()
			storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
			if parent.json {
				for (r, k) in JSONFormat.tokens(storage.string as NSString) { storage.addAttribute(.foregroundColor, value: k.color, range: r) }
			}
			storage.endEditing()
			tv.typingAttributes[.foregroundColor] = NSColor.labelColor
		}
	}
}

/// JSON 글자 다듬기: 키 순서·숫자 표기를 그대로 두려고 파서 대신 글자를 훑어 공백만 바꾼다 (문자열 안은 건드리지 않음)
enum JSONFormat {
	static func pretty(_ s: String, indent: String = "  ") -> String? {
		var out = "", level = 0, inString = false, escaped = false
		var chars = Array(s)
		var i = 0
		func newline() { out += "\n" + String(repeating: indent, count: max(0, level)) }
		while i < chars.count {
			let c = chars[i]
			if inString {
				out.append(c)
				if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
				i += 1; continue
			}
			switch c {
			case "\"": inString = true; out.append(c)
			case "{", "[":
				// 빈 {} [] 는 붙여 둔다
				var j = i + 1
				while j < chars.count, chars[j].isWhitespace { j += 1 }
				if j < chars.count, chars[j] == (c == "{" ? "}" : "]") { out += String(c) + String(chars[j]); i = j + 1; continue }
				out.append(c); level += 1; newline()
			case "}", "]": level -= 1; newline(); out.append(c)
			case ",": out.append(c); newline()
			case ":": out += ": "
			case " ", "\t", "\n", "\r": break
			default: out.append(c)
			}
			i += 1
		}
		chars = []
		return inString ? nil : out
	}

	static func compact(_ s: String) -> String? {
		var out = "", inString = false, escaped = false
		for c in s {
			if inString {
				out.append(c)
				if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
				continue
			}
			if c == "\"" { inString = true }
			if c.isWhitespace { continue }
			out.append(c)
		}
		return inString ? nil : out
	}
}

extension JSONFormat {
	/// { 또는 [ 로 시작하는 글 (앞뒤 공백 빼고)
	static func looksLikeJSON(_ s: String) -> Bool {
		guard let f = s.first(where: { !$0.isWhitespace }), let l = s.last(where: { !$0.isWhitespace }) else { return false }
		return (f == "{" && l == "}") || (f == "[" && l == "]")
	}

	struct Problem {
		let message: String
		let line: Int
		let column: Int
		/// 글 안 위치 (UTF-16)
		let offset: Int
	}

	/// 틀린 곳 (올바르면 nil). JSONSerialization 의 "around line 3, column 15" 를 읽는다
	static func check(_ s: String) -> Problem? {
		guard let data = s.data(using: .utf8) else { return Problem(message: "글자를 읽지 못했습니다", line: 0, column: 0, offset: 0) }
		do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]); return nil }
		catch {
			let msg = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
			var line = 0, col = 0
			if let re = try? NSRegularExpression(pattern: #"line (\d+), column (\d+)"#),
			   let m = re.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
			   let a = Range(m.range(at: 1), in: msg), let b = Range(m.range(at: 2), in: msg) {
				// 칸은 0 부터 센다 → 보이는 칸은 +1
				line = Int(msg[a]) ?? 0; col = (Int(msg[b]) ?? 0) + 1
			}
			// 줄·칸 → 위치
			var offset = 0
			if line > 0 {
				let lines = s.components(separatedBy: "\n")
				for k in 0..<min(line - 1, lines.count) { offset += (lines[k] as NSString).length + 1 }
				offset += max(0, col - 1)
			}
			let short = msg.replacingOccurrences(of: #"\s*around line \d+, column \d+\.?"#, with: "", options: .regularExpression)
			return Problem(message: short, line: line, column: col, offset: offset)
		}
	}

	/// 원본의 모양: 여러 줄이면 같은 들여쓰기로 펼치고, 한 줄이면 원본처럼 : 와 , 뒤 공백을 넣거나 뺀다. 원본이 JSON 이 아니면 공백 없는 한 줄
	static func restyle(_ s: String, like original: String) -> String? {
		guard check(original) == nil, looksLikeJSON(original) else { return compact(s) }
		if original.contains("\n") {
			// 첫 들여쓴 줄의 앞 공백 (탭이면 탭)
			let indent = original.components(separatedBy: "\n").dropFirst()
				.compactMap { l -> String? in let w = l.prefix { $0 == " " || $0 == "\t" }; return w.isEmpty ? nil : String(w) }.first ?? "  "
			return pretty(s, indent: indent)
		}
		let (colon, comma) = spacing(original)
		guard var out = compact(s) else { return nil }
		if colon || comma { out = spaced(out, colon: colon, comma: comma) }
		return out
	}

	/// 문자열 밖의 ": " / ", " 쓰임
	private static func spacing(_ s: String) -> (Bool, Bool) {
		var inString = false, escaped = false, colon = false, comma = false
		let chars = Array(s)
		for (i, c) in chars.enumerated() {
			if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
			if c == "\"" { inString = true; continue }
			if i + 1 < chars.count, chars[i + 1] == " " { if c == ":" { colon = true } else if c == "," { comma = true } }
		}
		return (colon, comma)
	}

	private static func spaced(_ s: String, colon: Bool, comma: Bool) -> String {
		var out = "", inString = false, escaped = false
		for c in s {
			out.append(c)
			if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
			if c == "\"" { inString = true } else if (c == ":" && colon) || (c == "," && comma) { out.append(" ") }
		}
		return out
	}

	enum Kind {
		case key, string, number, literal
		var color: NSColor {
			switch self { case .key: .systemPurple; case .string: .systemRed; case .number: .systemOrange; case .literal: .systemBlue }
		}
	}

	/// 색칠 자리: 키(: 앞 문자열)·문자열·숫자·true/false/null
	static func tokens(_ ns: NSString) -> [(NSRange, Kind)] {
		let n = ns.length
		var out: [(NSRange, Kind)] = []
		var i = 0
		func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
		while i < n {
			let c = ns.character(at: i)
			if c == 34 {
				var j = i + 1
				while j < n { let d = ns.character(at: j); if d == 92 { j += 2; continue }; if d == 34 { break }; j += 1 }
				let end = min(j + 1, n)
				var k = end
				while k < n, [32, 9, 10, 13].contains(ns.character(at: k)) { k += 1 }
				out.append((NSRange(location: i, length: end - i), k < n && ns.character(at: k) == 58 ? .key : .string))
				i = end
			} else if isDigit(c) || c == 45 {
				var j = i + 1
				while j < n, let s = Unicode.Scalar(ns.character(at: j)), "0123456789.eE+-".unicodeScalars.contains(s) { j += 1 }
				out.append((NSRange(location: i, length: j - i), .number)); i = j
			} else if c == 116 || c == 102 || c == 110 {   // t f n
				for w in ["true", "false", "null"] where i + w.count <= n && ns.substring(with: NSRange(location: i, length: w.count)) == w {
					out.append((NSRange(location: i, length: w.count), .literal)); i += w.count - 1; break
				}
				i += 1
			} else {
				i += 1
			}
		}
		return out
	}
}
