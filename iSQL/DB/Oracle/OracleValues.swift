import Foundation

/// 서버가 보낸 값 바이트를 글자로 바꾼다 (python-oracledb buffer.pyx · oracle-nio OracleNumeric 을 옮김).
/// 모르는 형식이어도 앱이 죽지 않게: 해석하지 못하면 nil (호출한 쪽이 16진수 등으로 보여 준다)
enum OracleValues {
	/// NUMBER: 첫 바이트가 지수(양수면 0x80 이 켜짐, 음수면 비트를 뒤집음), 나머지는 100진수 자리(양수 +1, 음수 101 -).
	/// 음수는 끝에 102 가 붙을 수 있다. 자릿수를 잃지 않게 글자로 만든다
	static func number(_ b: [UInt8]) -> String? {
		guard let first = b.first else { return nil }
		let positive = first & 0x80 != 0
		var exp = positive ? first : ~first
		exp &-= 193
		var length = b.count
		if length == 1 { return positive ? "0" : "-1e126" }
		if !positive && b[length - 1] == 102 { length -= 1 }
		var decimalPoint = Int(Int8(bitPattern: exp)) * 2 + 2

		var digits = [UInt8]()
		for i in 1..<length {
			var v = b[i]
			if positive { guard v >= 1 else { return nil }; v -= 1 } else { guard v <= 101 else { return nil }; v = 101 - v }
			guard v <= 99 else { return nil }
			let d1 = v / 10, d2 = v % 10
			if d1 == 0 && digits.isEmpty { decimalPoint -= 1 } else { digits.append(d1) }
			if d2 != 0 || i < length - 1 { digits.append(d2) }
		}
		// 끝의 0 은 소수점 뒤에서만 지운다
		while digits.count > max(decimalPoint, 0), digits.last == 0 { digits.removeLast() }
		if digits.isEmpty { return "0" }

		var s = positive ? "" : "-"
		if decimalPoint <= 0 {
			s += "0." + String(repeating: "0", count: -decimalPoint)
			s += digits.map { String($0) }.joined()
		} else if decimalPoint >= digits.count {
			s += digits.map { String($0) }.joined() + String(repeating: "0", count: decimalPoint - digits.count)
		} else {
			s += digits[0..<decimalPoint].map { String($0) }.joined() + "." + digits[decimalPoint...].map { String($0) }.joined()
		}
		return s
	}

	/// DATE(7) · TIMESTAMP(11) · TIMESTAMP WITH TIME ZONE(13). 년(100 단위 + 100, 나머지 + 100) 월 일 시+1 분+1 초+1 [나노초 4바이트] [시간대 시+20 분+60]
	static func dateTime(_ b: [UInt8], type: UInt8) -> String? {
		guard b.count >= 7 else { return nil }
		var year = (Int(b[0]) - 100) * 100 + Int(b[1]) - 100
		var month = Int(b[2]), day = Int(b[3]), hour = Int(b[4]) - 1, minute = Int(b[5]) - 1
		let second = Int(b[6]) - 1
		var zone = ""
		if b.count >= 13 && type == TNS.typeTimestampTZ {
			// 시간대가 붙은 값은 UTC 시각으로 온다 → 숫자 시간대(+09:00)는 그 값의 시간대 시각으로,
			// 지역 이름 시간대(첫 바이트 0x80: Asia/Seoul …)는 이름 표를 풀지 않고 앱 설정의 표시 시간대로 바꿔 보여 준다
			var offset = 0
			if b[11] & 0x80 == 0 {
				offset = (Int(b[11]) - 20) * 60 + Int(b[12]) - 60
			} else {
				var cal = Calendar(identifier: .gregorian)
				cal.timeZone = TimeZone(secondsFromGMT: 0)!
				if let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) {
					offset = DisplayTime.zone.secondsFromGMT(for: d) / 60
				}
			}
			zone = String(format: " %@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
			shift(offset)
		} else if type == TNS.typeTimestampLTZ {
			// 지역 시간대 시각(LOCAL TIME ZONE)도 UTC 로 온다 → 앱 설정의 표시 시간대로 (세션 시간대도 접속 때 그것에 맞춘다)
			var cal = Calendar(identifier: .gregorian)
			cal.timeZone = TimeZone(secondsFromGMT: 0)!
			if let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) {
				shift(DisplayTime.zone.secondsFromGMT(for: d) / 60)
			}
		}

		/// UTC 시각을 offset 분만큼 옮긴다 (날짜가 넘어가도 맞게)
		func shift(_ offset: Int) {
			guard offset != 0 else { return }
			var cal = Calendar(identifier: .gregorian)
			cal.timeZone = TimeZone(secondsFromGMT: 0)!
			if let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
			   let l = cal.date(byAdding: .minute, value: offset, to: d) {
				let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: l)
				year = c.year ?? year; month = c.month ?? month; day = c.day ?? day
				hour = c.hour ?? hour; minute = c.minute ?? minute
			}
		}
		var s = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
		if b.count >= 11 {
			let ns = UInt32(b[7]) << 24 | UInt32(b[8]) << 16 | UInt32(b[9]) << 8 | UInt32(b[10])
			if ns > 0 {
				var frac = String(format: "%09u", ns)
				while frac.hasSuffix("0") { frac.removeLast() }
				s += "." + frac
			}
		}
		return s + zone
	}

	/// BINARY_FLOAT · BINARY_DOUBLE: 첫 비트가 켜져 있으면 그 비트만 끄고, 아니면 모두 뒤집은 IEEE 754
	static func binaryFloat(_ b: [UInt8]) -> String? {
		guard b.count == 4 else { return nil }
		var x = b
		if x[0] & 0x80 != 0 { x[0] &= 0x7F } else { x = x.map { ~$0 } }
		let bits = UInt32(x[0]) << 24 | UInt32(x[1]) << 16 | UInt32(x[2]) << 8 | UInt32(x[3])
		return "\(Float(bitPattern: bits))"
	}

	static func binaryDouble(_ b: [UInt8]) -> String? {
		guard b.count == 8 else { return nil }
		var x = b
		if x[0] & 0x80 != 0 { x[0] &= 0x7F } else { x = x.map { ~$0 } }
		var bits: UInt64 = 0
		for v in x { bits = bits << 8 | UInt64(v) }
		return "\(Double(bitPattern: bits))"
	}

	/// INTERVAL DAY TO SECOND (11바이트): 일(4, +2^31) 시·분·초(+60) 나노초(4, +2^31)
	static func intervalDS(_ b: [UInt8]) -> String? {
		guard b.count >= 11 else { return nil }
		func i32(_ o: Int) -> Int { Int(UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])) - 0x8000_0000 }
		let days = i32(0), h = Int(b[4]) - 60, m = Int(b[5]) - 60, sec = Int(b[6]) - 60, ns = i32(7)
		let neg = days < 0 || h < 0 || m < 0 || sec < 0 || ns < 0
		var s = (neg ? "-" : "+") + String(format: "%d %02d:%02d:%02d", abs(days), abs(h), abs(m), abs(sec))
		if ns != 0 { s += String(format: ".%09d", abs(ns)) }
		return s
	}

	/// INTERVAL YEAR TO MONTH (5바이트): 년(4, +2^31) 월(+60)
	static func intervalYM(_ b: [UInt8]) -> String? {
		guard b.count >= 5 else { return nil }
		let years = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) - 0x8000_0000
		let months = Int(b[4]) - 60
		return (years < 0 || months < 0 ? "-" : "+") + "\(abs(years))-\(abs(months))"
	}

	/// ROWID 를 Oracle 이 보여 주는 18 글자(64진수)로
	static func rowID(rba: UInt32, partition: UInt16, block: UInt32, slot: UInt16) -> String? {
		if rba == 0 && partition == 0 && block == 0 && slot == 0 { return nil }
		let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
		func enc(_ value: UInt64, _ size: Int) -> String {
			var v = value
			var out = [Character](repeating: "A", count: size)
			for i in 0..<size { out[size - i - 1] = alphabet[Int(v & 0x3F)]; v >>= 6 }
			return String(out)
		}
		return enc(UInt64(rba), 6) + enc(UInt64(partition), 3) + enc(UInt64(block), 6) + enc(UInt64(slot), 3)
	}
}
