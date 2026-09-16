import Foundation
import AVFoundation

public struct RecordingSegment: Codable, Equatable, Sendable {
    public let name: String
    public let file: FileReference
    public let duration: MediaTime
}

extension Recording {
    public var sourceSegments: [RecordingSegment] {
        segments ?? [RecordingSegment(name: name, file: file, duration: duration)]
    }
    public func playbackAsset() async throws -> AVAsset {
        if segments == nil { return AVURLAsset(url: try file.resolve()) }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CutError.invalid("連続録画の再生トラックを作れません。")
        }
        var cursor = CMTime.zero
        for part in sourceSegments {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: try part.file.resolve())
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw CutError.invalid("映像トラックがありません。") }
            let range = CMTimeRange(start: .zero, duration: part.duration.cmTime)
            try video.insertTimeRange(range, of: v, at: cursor)
            if cursor == .zero { video.preferredTransform = try await v.load(.preferredTransform) }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                let available = try await a.load(.timeRange).intersection(range)
                if available.duration > .zero { try audio.insertTimeRange(available, of: a, at: CMTimeAdd(cursor, available.start)) }
            }
            cursor = CMTimeAdd(cursor, part.duration.cmTime)
        }
        return composition
    }
}

private func splitIdentity(_ name: String) -> (String, Int)? {
    // Camera recording timestamp plus a numeric chapter, not arbitrary numbered files.
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    guard stem.range(of: #"^VID_[0-9]{8}_[0-9]{6}_[0-9]+$"#, options: .regularExpression) != nil,
          let separator = stem.lastIndex(of: "_"), let number = Int(stem[stem.index(after: separator)...]) else { return nil }
    return (String(stem[..<separator]), number)
}

extension Project {
    public mutating func combineSplitRecordings() throws {
        var groups: [String: [Recording]] = [:]
        for r in recordings {
            guard let key = splitIdentity(r.sourceSegments[0].name) else { continue }
            let folder = URL(fileURLWithPath: r.file.path).deletingLastPathComponent().standardizedFileURL.path
            groups[folder + "/" + key.0, default: []].append(r)
        }
        for members in groups.values {
            let sorted = members.sorted { splitIdentity($0.sourceSegments[0].name)!.1 < splitIdentity($1.sourceSegments[0].name)!.1 }
            var runs: [[Recording]] = []
            for r in sorted {
                if let last = runs.last?.last,
                   splitIdentity(last.sourceSegments.last!.name)!.1 + 1 == splitIdentity(r.sourceSegments[0].name)!.1,
                   last.correction == r.correction { runs[runs.count - 1].append(r) }
                else { runs.append([r]) }
            }
            for run in runs where run.count > 1 {
                var joined = run[0], offset = MediaTime.zero
                let ids = Set(run.map(\.id))
                var offsets: [UUID: MediaTime] = [:]
                for r in run { offsets[r.id] = offset; offset = try offset.adding(r.duration) }
                joined.segments = run.flatMap(\.sourceSegments); joined.duration = offset
                joined.name = splitIdentity(joined.sourceSegments[0].name)!.0 + "（\(joined.sourceSegments.count)ファイル）"
                let firstIndex = recordings.firstIndex { ids.contains($0.id) }!
                recordings.removeAll { ids.contains($0.id) }; recordings.insert(joined, at: firstIndex)
                clips = try clips.map { c in
                    guard let offset = offsets[c.recordingID] else { return c }
                    var moved = Clip(id: c.id, recordingID: joined.id, markIDs: c.markIDs,
                                     requested: try MediaRange(start: c.requested.start.adding(offset), end: c.requested.end.adding(offset)), edited: c.edited)
                    moved.videoMarkIDs = c.videoMarkIDs; moved.selected = c.selected; moved.needsReview = c.needsReview
                    return moved
                }
                videoMarks = try videoMarks?.map { m in
                    guard let offset = offsets[m.recordingID] else { return m }
                    return VideoMark(id: m.id, recordingID: joined.id, position: try m.position.adding(offset), comment: m.comment)
                }
                // A GPX mark could previously have been generated once for every chapter
                // reporting the same start date. Keep edited candidates; deduplicate automatic ones.
                var seen = Set(clips.filter { $0.recordingID == joined.id && $0.edited }.flatMap(\.markIDs))
                clips.removeAll { c in
                    guard c.recordingID == joined.id, !c.edited, c.markIDs.count == 1 else { return false }
                    return !seen.insert(c.markIDs[0]).inserted
                }
                for i in clips.indices where clips[i].recordingID == joined.id && !clips[i].edited && clips[i].markIDs.count == 1 {
                    guard let mark = marks.first(where: { $0.id == clips[i].markIDs[0] }), let t = try joined.position(of: mark), t >= .zero, t < joined.duration else { clips[i].needsReview = true; continue }
                    clips[i].requested = try MediaRange(start: max(.zero, t.adding(MediaTime(seconds: -10))), end: min(joined.duration, t.adding(MediaTime(seconds: 60))))
                }
                for r in run {
                    let prefix = r.id.uuidString + ":"
                    let keys = generatedMarkKeys.filter { $0.hasPrefix(prefix) }
                    for key in keys { generatedMarkKeys.remove(key); generatedMarkKeys.insert(joined.id.uuidString + ":" + key.dropFirst(prefix.count)) }
                    if exportDirectories?[joined.id.uuidString] == nil, let directory = exportDirectories?[r.id.uuidString] { exportDirectories?[joined.id.uuidString] = directory }
                }
            }
        }
        try generateCandidates()
    }
}
