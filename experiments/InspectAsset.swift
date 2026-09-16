import AVFoundation
import Foundation

// Read-only inspection using the same creationDate API as Chrova.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: input)
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var result: [String: Any] = ["file": input.lastPathComponent]
let duration = try await asset.load(.duration)
result["durationSeconds"] = CMTimeGetSeconds(duration)
if let item = try await asset.load(.creationDate), let date = try await item.load(.dateValue) {
    result["creationDateUTC"] = formatter.string(from: date)
}
var metadata: [[String: String]] = []
for format in try await asset.load(.availableMetadataFormats) {
    for item in try await asset.loadMetadata(for: format) {
        var row = ["format": format.rawValue, "identifier": item.identifier?.rawValue ?? ""]
        row["key"] = String(describing: item.key)
        row["string"] = try await item.load(.stringValue)
        metadata.append(row)
    }
}
result["metadata"] = metadata
var tracks: [[String: Any]] = []
for track in try await asset.load(.tracks) {
    let range = try await track.load(.timeRange)
    let descriptions = try await track.load(.formatDescriptions)
    let subtypes = descriptions.map { description in
        let value = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
    tracks.append([
        "id": track.trackID,
        "type": track.mediaType.rawValue,
        "start": CMTimeGetSeconds(range.start),
        "duration": CMTimeGetSeconds(range.duration),
        "codec": subtypes,
        "nominalFrameRate": try await track.load(.nominalFrameRate),
        "naturalSize": String(describing: try await track.load(.naturalSize))
    ])
}
result["tracks"] = tracks
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
