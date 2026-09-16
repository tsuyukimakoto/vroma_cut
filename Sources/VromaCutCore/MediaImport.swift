import Foundation
import AVFoundation

public enum MediaImport {
    public static func recording(url: URL) async throws -> Recording {
        let file = try FileReference(url: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = tracks.first else { throw CutError.invalid("映像トラックがありません: \(url.lastPathComponent)") }
        let range = try await video.load(.timeRange)
        guard range.start == .zero else { throw CutError.invalid("開始PTSが0以外の素材は時間対応の検証が必要です: \(url.lastPathComponent)") }
        let duration = try MediaTime(range.duration)
        guard duration > .zero else { throw CutError.invalid("映像の長さを取得できません。") }
        let metadata = try await asset.load(.creationDate)
        let date = try await metadata?.load(.dateValue)
        return Recording(name: url.lastPathComponent, file: file, duration: duration, cameraStart: date,
                         dateEvidence: date == nil ? "内部日時なし・時刻未確定" : "AVAsset.creationDate（内部日時）")
    }
}

public struct TrackPoint: Codable, Equatable, Sendable {
    public let date: Date
    public let latitude: Double
    public let longitude: Double
}
public struct GPXTrack: Sendable {
    public let points: [TrackPoint]
    public func point(at date: Date) -> TrackPoint? {
        guard let first = points.first, let last = points.last, date >= first.date, date <= last.date else { return nil }
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].date <= date { low = mid + 1 } else { high = mid } }
        return points[low - 1]
    }
    public static func parse(_ data: Data) throws -> GPXTrack {
        let reader = GPXReader(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.failure == nil, !reader.points.isEmpty else { throw CutError.invalid(reader.failure ?? parser.parserError?.localizedDescription ?? "時刻付きのGPX測位点がありません。") }
        return GPXTrack(points: reader.points.sorted { $0.date < $1.date })
    }
}
private final class GPXReader: NSObject, XMLParserDelegate {
    var points: [TrackPoint] = [], failure: String?
    private var latitude: Double?, longitude: Double?, timeText: String?, depth = 0, trackDepth: Int?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if name == "trkpt" {
            latitude = attributes["lat"].flatMap(Double.init); longitude = attributes["lon"].flatMap(Double.init); trackDepth = depth
        } else if name == "time", let trackDepth, depth == trackDepth + 1 { timeText = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if timeText != nil { timeText! += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if name == "time", let text = timeText {
            defer { timeText = nil }
            guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude), let date = try? UTCDate.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                failure = "GPXの座標または時刻が不正です。"; parser.abortParsing(); return
            }
            points.append(TrackPoint(date: date, latitude: latitude, longitude: longitude))
        } else if name == "trkpt" { latitude = nil; longitude = nil; trackDepth = nil }
    }
}
