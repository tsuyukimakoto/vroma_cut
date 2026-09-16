import Foundation
import CoreMedia

public enum CutError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

public struct MediaTime: Codable, Hashable, Comparable, Sendable {
    public let value: Int64
    public let timescale: Int32
    public var seconds: Double { Double(value) / Double(timescale) }
    public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    public static let zero = try! MediaTime(value: 0, timescale: 1)
    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else { throw CutError.invalid("時間のtimescaleが不正です。") }
        self.value = value; self.timescale = timescale
    }
    public init(seconds: Double) throws {
        guard seconds.isFinite, abs(seconds) < Double(Int64.max) / 1_000_000 else {
            throw CutError.invalid("時間が範囲外です。")
        }
        try self.init(value: Int64((seconds * 1_000_000).rounded()), timescale: 1_000_000)
    }
    public init(_ time: CMTime) throws {
        guard time.isNumeric, time.epoch == 0 else { throw CutError.invalid("動画の時間を解釈できません。") }
        try self.init(value: time.value, timescale: time.timescale)
    }
    public func adding(_ other: Self) throws -> Self { try Self(CMTimeAdd(cmTime, other.cmTime)) }
    public static func < (lhs: Self, rhs: Self) -> Bool { CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0 }
    public static func == (lhs: Self, rhs: Self) -> Bool { CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0 }
    public func hash(into hasher: inout Hasher) {
        var a = value.magnitude, b = UInt64(timescale)
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(a, 1)
        hasher.combine(value / Int64(divisor)); hasher.combine(Int64(timescale) / Int64(divisor))
    }
    enum CodingKeys: CodingKey { case value, timescale }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: c.decode(Int64.self, forKey: .value), timescale: c.decode(Int32.self, forKey: .timescale))
    }
}

public struct MediaRange: Codable, Equatable, Sendable {
    public let start: MediaTime
    public let end: MediaTime
    public init(start: MediaTime, end: MediaTime) throws {
        guard start >= .zero, end > start else { throw CutError.invalid("開始点は0以上、終了点は開始点より後にしてください。") }
        self.start = start; self.end = end
    }
    public func contains(_ time: MediaTime) -> Bool { start <= time && time < end }
    enum CodingKeys: CodingKey { case start, end }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(MediaTime.self, forKey: .start), end: c.decode(MediaTime.self, forKey: .end))
    }
}

public enum UTCDate {
    public static func parse(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw CutError.invalid("日時を解釈できません: \(string)") }
        return date
    }
}
