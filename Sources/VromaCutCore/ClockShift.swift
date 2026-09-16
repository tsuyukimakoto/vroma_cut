import Foundation

public struct ClockShift: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Sendable { case forward, backward }
    public var direction: Direction
    public var years: Int
    public var months: Int
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Double
    public init(direction: Direction = .forward, years: Int = 0, months: Int = 0, days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Double = 0) {
        self.direction = direction; self.years = years; self.months = months; self.days = days
        self.hours = hours; self.minutes = minutes; self.seconds = seconds
    }
    public func adjustedDate(from date: Date, timeZone: String) throws -> Date {
        guard let zone = TimeZone(identifier: timeZone),
              (0...9998).contains(years), (0...120000).contains(months), (0...3660000).contains(days),
              (0...87840000).contains(hours), (0...5270400000).contains(minutes),
              seconds.isFinite, seconds >= 0, seconds <= 316224000000 else {
            throw CutError.invalid("時刻差は0以上の数で入力し、進める／戻すで方向を選んでください。")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let sign = direction == .forward ? 1 : -1
        // Years/months/days use the recorded display timezone and Gregorian calendar.
        // The preview exposes month-end clamping and daylight-saving transitions.
        let components = DateComponents(year: sign * years, month: sign * months, day: sign * days,
                                        hour: sign * hours, minute: sign * minutes, second: sign * Int(seconds.rounded(.down)))
        guard let whole = calendar.date(byAdding: components, to: date), (1...9999).contains(calendar.component(.year, from: whole)) else {
            throw CutError.invalid("補正後の日時が扱える範囲を超えています。")
        }
        return whole.addingTimeInterval(Double(sign) * (seconds - seconds.rounded(.down)))
    }
    public func correction(from date: Date, timeZone: String) throws -> MediaTime {
        try MediaTime(seconds: adjustedDate(from: date, timeZone: timeZone).timeIntervalSince(date))
    }
    public static func describing(_ correction: MediaTime, from date: Date, timeZone: String) -> ClockShift {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let target = date.addingTimeInterval(correction.seconds)
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date, to: target)
        let candidate = ClockShift(direction: correction < .zero ? .backward : .forward,
            years: abs(fields.year ?? 0), months: abs(fields.month ?? 0), days: abs(fields.day ?? 0),
            hours: abs(fields.hour ?? 0), minutes: abs(fields.minute ?? 0),
            seconds: Double(abs(fields.second ?? 0)) + Double(abs(fields.nanosecond ?? 0)) / 1_000_000_000)
        if let reconstructed = try? candidate.correction(from: date, timeZone: timeZone), abs(reconstructed.seconds - correction.seconds) < 0.000002 { return candidate }
        // Preserve pre-existing seconds-based documents exactly if calendar decomposition is ambiguous.
        return ClockShift(direction: correction < .zero ? .backward : .forward, seconds: abs(correction.seconds))
    }
}

public struct ClockAdjustment: Codable, Equatable, Sendable {
    public let shift: ClockShift
    public let referenceDate: Date
    public let timeZone: String
    public let correction: MediaTime
}
