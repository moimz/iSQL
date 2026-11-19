import Foundation

/// 날짜·시각을 보여 줄 시간대 (앱 설정 > 일반 > 시간 표시, 사용자 2026-11-20).
/// 비어 있으면 시스템(이 맥) 시간대. 쓰는 곳: 컬럼을 날짜로 보기(유닉스 시간), Oracle 의 시간대 붙은 값 · 세션 시간대
enum DisplayTime {
	static let key = "displayTimeZone"

	/// 고른 시간대 이름 ("" = 시스템)
	static var identifier: String { UserDefaults.standard.string(forKey: key) ?? "" }
	static var zone: TimeZone { identifier.isEmpty ? .current : TimeZone(identifier: identifier) ?? .current }

	/// "2026-11-20 13:45:12" (+ 소수 자리)
	static func format(_ date: Date, fractionDigits: Int = 0) -> String {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = zone
		let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
		var s = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
		if fractionDigits > 0 {
			let ns = c.nanosecond ?? 0
			let frac = String(format: "%09d", ns).prefix(fractionDigits)
			s += "." + frac
		}
		return s
	}

	/// format 의 꼴(소수 자리는 있어도 없어도)을 그 시간대의 시각으로
	static func parse(_ s: String) -> Date? {
		let t = s.trimmingCharacters(in: .whitespaces)
		guard let m = t.wholeMatch(of: #/(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?/#) else { return nil }
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = zone
		var c = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3),
		                       hour: m.4.flatMap { Int($0) } ?? 0, minute: m.5.flatMap { Int($0) } ?? 0, second: m.6.flatMap { Int($0) } ?? 0)
		if let f = m.7 { c.nanosecond = Int(String(f).padding(toLength: 9, withPad: "0", startingAt: 0)) }
		return cal.date(from: c)
	}

	/// 고를 수 있는 시간대 이름들 (Asia/Seoul …)
	static var choices: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
}

/// 유닉스 시간(1970-01-01 UTC 부터) 숫자의 단위
enum UnixTimeUnit: String, CaseIterable {
	case seconds = "s", millis = "ms", micros = "us"

	var label: String {
		switch self {
		case .seconds: "초 (10자리)"
		case .millis: "밀리초 (13자리)"
		case .micros: "마이크로초 (16자리)"
		}
	}
	var name: String {
		switch self {
		case .seconds: "초"
		case .millis: "밀리초"
		case .micros: "마이크로초"
		}
	}
	var perSecond: Double {
		switch self {
		case .seconds: 1
		case .millis: 1_000
		case .micros: 1_000_000
		}
	}

	/// 숫자 글자 → 날짜 글자 (숫자가 아니면 nil). 정수는 나머지를 소수 자리로 그대로 붙인다 (실수로 나누면 끝자리가 틀어진다)
	func display(_ raw: String) -> String? {
		let t = raw.trimmingCharacters(in: .whitespaces)
		let per = Int64(perSecond)
		if let n = Int64(t) {
			var secs = n / per, frac = n % per
			if frac < 0 { secs -= 1; frac += per }
			let base = DisplayTime.format(Date(timeIntervalSince1970: TimeInterval(secs)))
			return self == .seconds ? base : base + "." + String(format: self == .millis ? "%03lld" : "%06lld", frac)
		}
		guard let n = Double(t) else { return nil }
		return DisplayTime.format(Date(timeIntervalSince1970: n / perSecond), fractionDigits: self == .micros ? 6 : 3)
	}

	/// 날짜 글자 → 이 단위의 숫자 글자 (날짜가 아니면 nil)
	func raw(_ text: String) -> String? {
		guard let d = DisplayTime.parse(text) else { return nil }
		let v = d.timeIntervalSince1970 * perSecond
		return String(Int64(v.rounded()))
	}
}
