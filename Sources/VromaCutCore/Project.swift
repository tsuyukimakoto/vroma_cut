import Foundation

public struct FileReference: Codable, Equatable, Sendable {
    public private(set) var path: String
    public private(set) var bookmark: Data
    public private(set) var size: Int64
    public private(set) var modified: Date
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
            throw CutError.invalid("通常のファイルを選択してください。")
        }
        path = url.path; self.size = Int64(size); self.modified = modified
        bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve() throws -> URL {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)) ?? URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(values.fileSize ?? -1) == size, values.contentModificationDate == modified else {
            throw CutError.invalid("素材が変更されたか見つかりません: \(path)")
        }
        return url
    }
}

public struct Recording: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var file: FileReference
    public var duration: MediaTime
    public var cameraStart: Date?
    public var segments: [RecordingSegment]?
    public var dateEvidence: String
    public var correction: MediaTime = .zero
    public init(id: UUID = UUID(), name: String, file: FileReference, duration: MediaTime, cameraStart: Date?, dateEvidence: String = "AVAsset.creationDate") {
        self.id = id; self.name = name; self.file = file; self.duration = duration
        self.cameraStart = cameraStart; self.dateEvidence = dateEvidence
    }
    public func position(of mark: Mark) throws -> MediaTime? {
        guard let cameraStart else { return nil }
        return try MediaTime(seconds: mark.date.timeIntervalSince(cameraStart) - correction.seconds)
    }
    public func absoluteDate(at time: MediaTime) -> Date? { cameraStart?.addingTimeInterval(correction.seconds + time.seconds) }
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public var markIDs: [String]
    public var videoMarkIDs: [String]?
    public var requested: MediaRange
    public var edited: Bool
    public var selected: Bool = true
    public var needsReview: Bool = false
    public init(id: UUID = UUID(), recordingID: UUID, markIDs: [String] = [], requested: MediaRange, edited: Bool = false) {
        self.id = id; self.recordingID = recordingID; self.markIDs = markIDs; self.requested = requested; self.edited = edited
    }
}

public struct Project: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var displayTimeZone: String
    public var recordings: [Recording]
    public var marks: [Mark]
    public var clips: [Clip]
    public var tracks: [FileReference]
    public var markFiles: [FileReference]
    public var exports: [ExportRecord]
    public var videoMarks: [VideoMark]?
    public var clockAdjustment: ClockAdjustment?
    public var exportDirectories: [String: String]?
    public var lastExportDirectory: String?
    // Tombstones also prevent deleted candidates from returning on every import.
    public var generatedMarkKeys: Set<String>
    public init(recordings: [Recording] = [], marks: [Mark] = []) {
        schemaVersion = 1; displayTimeZone = TimeZone.current.identifier
        self.recordings = recordings; self.marks = marks; clips = []; tracks = []; markFiles = []; exports = []; generatedMarkKeys = []
    }
    public var unmatchedMarks: [Mark] {
        marks.filter { mark in !recordings.contains { r in
            guard let t = try? r.position(of: mark) else { return false }
            return t >= .zero && t < r.duration
        } }
    }
    public mutating func importMarks(_ incoming: [Mark]) throws {
        var seen = Set(marks.map(\.id))
        marks += incoming.filter { seen.insert($0.id).inserted }
        try generateCandidates()
    }
    private func initialRange(at time: MediaTime, duration: MediaTime) throws -> MediaRange {
        try MediaRange(start: max(.zero, time.adding(MediaTime(seconds: -10))),
                       end: min(duration, time.adding(MediaTime(seconds: 60))))
    }
    public mutating func generateCandidates() throws {
        for r in recordings {
            for mark in marks {
                guard let t = try r.position(of: mark), t >= .zero, t < r.duration else { continue }
                let key = r.id.uuidString + ":" + mark.id
                guard generatedMarkKeys.insert(key).inserted else { continue }
                clips.append(Clip(recordingID: r.id, markIDs: [mark.id], requested: try initialRange(at: t, duration: r.duration)))
            }
        }
    }
    public mutating func addManual(recordingID: UUID, at time: MediaTime) throws {
        guard let r = recordings.first(where: { $0.id == recordingID }), time >= .zero, time < r.duration else { throw CutError.invalid("録画内の位置を選択してください。") }
        clips.append(Clip(recordingID: r.id, requested: try initialRange(at: time, duration: r.duration), edited: true))
    }
    public mutating func editRange(clipID: UUID, range: MediaRange) throws {
        guard let i = clips.firstIndex(where: { $0.id == clipID }), let r = recordings.first(where: { $0.id == clips[i].recordingID }), range.end <= r.duration else { throw CutError.invalid("範囲が録画の長さを超えています。") }
        clips[i].requested = range; clips[i].edited = true; clips[i].needsReview = false
    }
    public mutating func setCorrection(_ correction: MediaTime, recordingID: UUID) throws {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { throw CutError.invalid("録画がありません。") }
        guard recordings[i].correction != correction else { return }
        recordings[i].correction = correction
        try updateFollowingClips(recording: recordings[i])
        try generateCandidates()
    }
    mutating func updateFollowingClips(recording r: Recording) throws {
        for index in clips.indices where clips[index].recordingID == r.id {
            if clips[index].edited || clips[index].markIDs.count != 1 { clips[index].needsReview = true; continue }
            guard let mark = marks.first(where: { $0.id == clips[index].markIDs[0] }), let t = try r.position(of: mark), t >= .zero, t < r.duration else {
                clips[index].needsReview = true; continue
            }
            clips[index].requested = try initialRange(at: t, duration: r.duration); clips[index].needsReview = false
        }
    }
    public mutating func merge(_ ids: Set<UUID>) throws {
        let chosen = clips.filter { ids.contains($0.id) }
        guard chosen.count >= 2, Set(chosen.map(\.recordingID)).count == 1 else { throw CutError.invalid("同じ録画の候補を2つ以上選択してください。") }
        var merged = Clip(recordingID: chosen[0].recordingID, markIDs: Array(Set(chosen.flatMap(\.markIDs))).sorted(), requested: try MediaRange(start: chosen.map(\.requested.start).min()!, end: chosen.map(\.requested.end).max()!), edited: true)
        merged.videoMarkIDs = Array(Set(chosen.flatMap { $0.videoMarkIDs ?? [] })).sorted()
        clips.removeAll { ids.contains($0.id) }; clips.append(merged)
    }
    public func validate() throws {
        guard schemaVersion == 1, TimeZone(identifier: displayTimeZone) != nil,
              Set(recordings.map(\.id)).count == recordings.count, Set(clips.map(\.id)).count == clips.count,
              Set(marks.map(\.id)).count == marks.count else { throw CutError.invalid("未対応または不正なプロジェクトです。") }
        for r in recordings {
            guard r.duration > .zero else { throw CutError.invalid("録画の長さが不正です。") }
            if let segments = r.segments {
                guard segments.count >= 2, segments.first?.file == r.file, segments.allSatisfy({ $0.duration > .zero }),
                      try segments.reduce(MediaTime.zero, { try $0.adding($1.duration) }) == r.duration else { throw CutError.invalid("分割録画の構成または長さが不正です。") }
            }
        }
        let local = videoMarks ?? []
        guard Set(local.map(\.id)).count == local.count else { throw CutError.invalid("追加マークのIDが重複しています。") }
        for mark in local {
            guard let r = recordings.first(where: { $0.id == mark.recordingID }), mark.position >= .zero, mark.position < r.duration else { throw CutError.invalid("追加マークの位置が録画範囲外です。") }
        }
        for c in clips {
            guard (c.videoMarkIDs ?? []).allSatisfy({ id in local.contains { $0.id == id && $0.recordingID == c.recordingID } }) else { throw CutError.invalid("追加マークと候補の対応が不正です。") }

            guard let r = recordings.first(where: { $0.id == c.recordingID }), c.requested.end <= r.duration,
                  c.markIDs.allSatisfy({ id in marks.contains { $0.id == id } }) else { throw CutError.invalid("候補と素材の対応が不正です。") }
        }
    }
    public func encoded() throws -> Data { try validate(); let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(self) }
    public static func decode(_ data: Data) throws -> Self { var p = try JSONDecoder().decode(Self.self, from: data); try p.validate(); try p.combineSplitRecordings(); try p.validate(); return p }
    public func save(to url: URL) throws { try encoded().write(to: url, options: .atomic) }
}
