import SwiftUI

/// 여러 줄 글자·JSON 칸 편집 (창 제목바 시트). 칸 안에서는 줄바꿈을 넣기 어려워서 따로 연다.
/// JSON 컬럼이면 아래에 올바른지 표시와 [정리](들여쓰기, 키 순서는 그대로)
struct LongTextSheet: View {
	let request: LongEditRequest
	let table: TableInfo
	let apply: (Value) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var text: String
	@FocusState private var focused: Bool

	init(request: LongEditRequest, table: TableInfo, apply: @escaping (Value) -> Void) {
		self.request = request
		self.table = table
		self.apply = apply
		_text = State(initialValue: request.text)
	}

	/// JSON 이 아니면 nil, 맞으면 .ok, 틀리면 오류 글자
	private var jsonCheck: String? {
		guard request.isJSON, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		guard let data = text.data(using: .utf8) else { return "글자를 읽지 못했습니다" }
		do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]); return "" }
		catch { return (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Text("\(table.name).\(request.column)").font(.headline)
				if request.isJSON { Text("JSON").font(.caption.weight(.semibold)).foregroundStyle(.teal) }
				if request.wasNull { Text("지금 NULL").font(.callout).foregroundStyle(.secondary) }
				Spacer()
				Text("\(text.count.formatted())자 · \(text.split(separator: "\n", omittingEmptySubsequences: false).count.formatted())줄")
					.font(.callout).foregroundStyle(.secondary).monospacedDigit()
			}
			TextEditor(text: $text)
				.font(.body.monospaced())
				.scrollContentBackground(.hidden)
				.padding(6)
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
				.focused($focused)
				.frame(minHeight: 320)
			if request.isJSON {
				HStack(spacing: 10) {
					if let c = jsonCheck {
						if c.isEmpty {
							Label("올바른 JSON", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
						} else {
							Label(c, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
						}
					}
					Spacer()
					Button("한 줄로") { if let t = JSONFormat.compact(text) { text = t } }
						.disabled(jsonCheck != "")
						.help("공백·줄바꿈을 빼서 한 줄로")
					Button("정리") { if let t = JSONFormat.pretty(text) { text = t } }
						.disabled(jsonCheck != "")
						.help("들여쓰기 (키 순서는 그대로)")
				}
				.font(.callout)
			}
			HStack {
				Button("NULL 로") { apply(.null); dismiss() }
					.help("이 칸을 NULL 로 (NOT NULL 컬럼이면 저장할 때 서버가 거절합니다)")
				Spacer()
				Button("취소", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("적용") { apply(.text(text)); dismiss() }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.return, modifiers: .command)
					.help("적용 (⌘↩). 저장(⌘S)해야 서버에 반영됩니다")
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(minWidth: 680, idealWidth: 760, minHeight: 460)
		.onAppear { focused = true }
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
