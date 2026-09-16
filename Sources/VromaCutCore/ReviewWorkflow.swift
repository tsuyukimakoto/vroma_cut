import Foundation

public struct VideoMark: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recordingID: UUID
    public let position: MediaTime
    public let comment: String
}
public struct TimelineMark: Equatable, Identifiable, Sendable {
    public let id: String
    public let position: MediaTime
    public let comment: String
    public let isLocal: Bool
}
public struct ReviewSelection: Equatable, Sendable {
    public let recordingID: UUID
    public let markID: String?
    public let clipID: UUID?
    public let position: MediaTime
}
public struct TrackImport: Sendable {
    public let file: FileReference
    public let markFile: FileReference?
    public let marks: [Mark]
    public let pointCount: Int
    public let startDate: Date
    public let endDate: Date
    public static func load(gpx: URL) throws -> Self {
        let track = try GPXTrack.parse(Data(contentsOf: gpx))
        let reference = try FileReference(url: gpx)
        let expected = gpx.deletingPathExtension().lastPathComponent + ".marks.csv"
        let siblings = try FileManager.default.contentsOfDirectory(at: gpx.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let matching = siblings.first { $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame }
        let markFile = try matching.map { try FileReference(url: $0) }
        let marks = try matching.map { try MarkCSV.parse(String(contentsOf: $0, encoding: .utf8)) } ?? []
        return Self(file: reference, markFile: markFile, marks: marks, pointCount: track.points.count,
                    startDate: track.points[0].date, endDate: track.points[track.points.count - 1].date)
    }
}

extension Project {
    public func timelineMarks(recordingID: UUID) -> [TimelineMark] {
        guard let r = recordings.first(where: { $0.id == recordingID }) else { return [] }
        let imported = marks.compactMap { mark -> TimelineMark? in
            guard let t = try? r.position(of: mark), t >= .zero, t < r.duration else { return nil }
            return TimelineMark(id: mark.id, position: t, comment: mark.comment, isLocal: false)
        }
        let local = (videoMarks ?? []).filter { $0.recordingID == recordingID }.map {
            TimelineMark(id: $0.id, position: $0.position, comment: $0.comment, isLocal: true)
        }
        return (imported + local).sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
    }
    public func clip(for markID: String, recordingID: UUID) -> Clip? {
        clips.filter { $0.recordingID == recordingID && ($0.markIDs.contains(markID) || ($0.videoMarkIDs ?? []).contains(markID)) }
            .sorted { $0.requested.start < $1.requested.start }.first
    }
    public func initialReview(recordingID: UUID? = nil) -> ReviewSelection? {
        let candidates = recordings.filter { recordingID == nil || $0.id == recordingID }
        let marked = candidates.compactMap { r -> (Recording, TimelineMark)? in timelineMarks(recordingID: r.id).first.map { (r, $0) } }
        let earliest = marked.min { a, b in
            let da = a.0.absoluteDate(at: a.1.position) ?? .distantFuture
            let db = b.0.absoluteDate(at: b.1.position) ?? .distantFuture
            return da == db ? a.1.position < b.1.position : da < db
        }
        if let (r, mark) = earliest {
            let clip = clip(for: mark.id, recordingID: r.id)
            return ReviewSelection(recordingID: r.id, markID: mark.id, clipID: clip?.id, position: clip?.requested.start ?? mark.position)
        }
        guard let r = candidates.first else { return nil }
        let clip = clips.filter { $0.recordingID == r.id }.min { $0.requested.start < $1.requested.start }
        return ReviewSelection(recordingID: r.id, markID: nil, clipID: clip?.id, position: clip?.requested.start ?? .zero)
    }
    public func adjacentMark(recordingID: UUID, currentID: String?, position: MediaTime, direction: Int) -> TimelineMark? {
        let marks = timelineMarks(recordingID: recordingID)
        if let currentID, let i = marks.firstIndex(where: { $0.id == currentID }) {
            let next = i + (direction < 0 ? -1 : 1)
            return marks.indices.contains(next) ? marks[next] : nil
        }
        return direction < 0 ? marks.last { $0.position < position } : marks.first { $0.position > position }
    }
    public mutating func importTrack(_ bundle: TrackImport) throws {
        if !tracks.contains(where: { $0.path == bundle.file.path }) { tracks.append(bundle.file) }
        if let file = bundle.markFile, !markFiles.contains(where: { $0.path == file.path }) { markFiles.append(file) }
        try importMarks(bundle.marks)
    }
    public mutating func addRecordings(_ incoming: [Recording]) throws {
        var known = Set(recordings.flatMap { $0.sourceSegments.map(\.file.path) })
        for var r in incoming where known.insert(r.file.path).inserted {
            if let clockAdjustment { r.correction = clockAdjustment.correction }
            recordings.append(r)
        }
        try combineSplitRecordings()
    }
    @discardableResult
    public mutating func addVideoMark(recordingID: UUID, at position: MediaTime, comment: String = "") throws -> String {
        guard let r = recordings.first(where: { $0.id == recordingID }), position >= .zero, position < r.duration else {
            throw CutError.invalid("録画内の位置にマークを追加してください。")
        }
        let marker = VideoMark(id: UUID().uuidString, recordingID: recordingID, position: position, comment: comment)
        if videoMarks == nil { videoMarks = [] }
        videoMarks!.append(marker)
        let range = try MediaRange(start: max(.zero, position.adding(MediaTime(seconds: -10))), end: min(r.duration, position.adding(MediaTime(seconds: 60))))
        var clip = Clip(recordingID: recordingID, requested: range, edited: true)
        clip.videoMarkIDs = [marker.id]
        clips.append(clip)
        return marker.id
    }
    public mutating func applyClockShift(_ shift: ClockShift, referenceRecordingID: UUID) throws {
        guard let r = recordings.first(where: { $0.id == referenceRecordingID }), let date = r.cameraStart else {
            throw CutError.invalid("基準にする動画の撮影日時がありません。")
        }
        let correction = try shift.correction(from: date, timeZone: displayTimeZone)
        clockAdjustment = ClockAdjustment(shift: shift, referenceDate: date, timeZone: displayTimeZone, correction: correction)
        // The calendar input produces one constant camera offset, also used by later imports.
        let changed = Set(recordings.filter { $0.correction != correction }.map(\.id))
        for i in recordings.indices { recordings[i].correction = correction }
        for r in recordings where changed.contains(r.id) { try updateFollowingClips(recording: r) }
        try generateCandidates()
    }
}
