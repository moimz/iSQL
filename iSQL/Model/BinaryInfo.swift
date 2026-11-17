import Foundation

/// 바이너리(BLOB) 값 알아보기: 앞 몇 바이트(매직 넘버)로 파일 형식
enum BinaryInfo {
	struct Kind {
		let name: String
		/// 저장할 때 붙일 확장자
		let ext: String
		/// 훑어보기(Quick Look)로 보여 줄 만한지 (이미지·PDF·영상)
		let previewable: Bool
	}

	static func kind(_ d: Data) -> Kind? {
		let b = [UInt8](d.prefix(16))
		func starts(_ p: [UInt8], at o: Int = 0) -> Bool { b.count >= o + p.count && Array(b[o..<(o + p.count)]) == p }
		if starts([0x89, 0x50, 0x4E, 0x47]) { return Kind(name: "PNG 이미지", ext: "png", previewable: true) }
		if starts([0xFF, 0xD8, 0xFF]) { return Kind(name: "JPEG 이미지", ext: "jpg", previewable: true) }
		if starts(Array("GIF8".utf8)) { return Kind(name: "GIF 이미지", ext: "gif", previewable: true) }
		if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return Kind(name: "WebP 이미지", ext: "webp", previewable: true) }
		if starts([0x42, 0x4D]) && b.count >= 6 { return Kind(name: "BMP 이미지", ext: "bmp", previewable: true) }
		if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return Kind(name: "TIFF 이미지", ext: "tiff", previewable: true) }
		if starts(Array("ftyp".utf8), at: 4) {
			let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
			if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") { return Kind(name: "HEIC 이미지", ext: "heic", previewable: true) }
			if brand.hasPrefix("qt") { return Kind(name: "MOV 영상", ext: "mov", previewable: true) }
			return Kind(name: "MP4 영상", ext: "mp4", previewable: true)
		}
		if starts(Array("%PDF".utf8)) { return Kind(name: "PDF", ext: "pdf", previewable: true) }
		if starts([0x50, 0x4B, 0x03, 0x04]) { return Kind(name: "ZIP", ext: "zip", previewable: false) }
		if starts([0x1F, 0x8B]) { return Kind(name: "gzip", ext: "gz", previewable: false) }
		if starts(Array("ID3".utf8)) || starts([0xFF, 0xFB]) { return Kind(name: "MP3 소리", ext: "mp3", previewable: true) }
		if starts(Array("RIFF".utf8)) && starts(Array("WAVE".utf8), at: 8) { return Kind(name: "WAV 소리", ext: "wav", previewable: true) }
		return nil
	}

	/// 표 칸에 보일 글자: "PNG 이미지 · 24 KB", 모르면 "바이너리 · 6바이트"
	static func describe(_ d: Data) -> String {
		let size = d.count < 1024 ? "\(d.count)바이트" : ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file)
		return "\(kind(d)?.name ?? "바이너리") · \(size)"
	}

	/// 글자로 읽히는 바이트인지 (UTF-8 이고 제어 문자가 없음 — 탭·줄바꿈은 괜찮다)
	static func text(_ d: Data) -> String? {
		guard let s = String(data: d, encoding: .utf8) else { return nil }
		return s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" } ? nil : s
	}

	/// 복사용 16진수 0x… (너무 길면 앞 16,000바이트만 — 엑셀 내보내기와 같게)
	static func hex(_ d: Data) -> String {
		"0x" + d.prefix(16_000).map { String(format: "%02X", $0) }.joined()
	}
}

extension Value {
	/// 표에 보일 글자 (바이너리는 글자로 읽히면 글자, 아니면 "PNG 이미지 · 24 KB")
	var display: String? {
		if case .bytes(let d) = self { return BinaryInfo.text(d) ?? BinaryInfo.describe(d) }
		return string
	}
	/// 클립보드용 글자 (바이너리는 글자로 읽히면 글자, 아니면 0x…)
	var clipboard: String? {
		if case .bytes(let d) = self { return BinaryInfo.text(d) ?? BinaryInfo.hex(d) }
		return string
	}
}
