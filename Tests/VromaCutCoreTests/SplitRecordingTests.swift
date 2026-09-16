import Foundation
import AVFoundation
import Testing
@testable import VromaCutCore

@Test func numberedFilesBecomeOneRecordingWithContinuousMarks() throws {
    let file = try FileReference(url: URL(fileURLWithPath: #filePath))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = Recording(name: "VID_20260911_080012_025.mp4", file: file, duration: try MediaTime(seconds: 100), cameraStart: date)
    let b = Recording(name: "VID_20260911_080012_026.mp4", file: file, duration: try MediaTime(seconds: 70), cameraStart: date)
    var p = Project(recordings: [b, a])
    p = try Project.decode(p.encoded())
    #expect(p.recordings.count == 1)
    #expect(p.recordings.first?.duration.seconds == 170)
    #expect(p.recordings.first?.id == a.id)
    #expect(try Project.decode(p.encoded()) == p)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_SPLIT_FOLDER"] != nil))
func realSplitRecordingPlaysAndExportsAcrossBoundary() async throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VROMA_SPLIT_FOLDER"]!)
    let a = try await MediaImport.recording(url: folder.appendingPathComponent("VID_20260911_080012_025.mp4"))
    let b = try await MediaImport.recording(url: folder.appendingPathComponent("VID_20260911_080012_026.mp4"))
    var p = Project()
    try p.addRecordings([a, b])
    let r = try #require(p.recordings.first)
    #expect(p.recordings.count == 1)
    #expect(r.duration == (try a.duration.adding(b.duration)))
    let asset = try await r.playbackAsset()
    #expect(abs(try await asset.load(.duration).seconds - r.duration.seconds) < 0.000002)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = CGSize(width: 320, height: 180)
    for second in [a.duration.seconds - 0.2, a.duration.seconds + 0.2] {
        let image = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 1_000_000))
        #expect(image.image.width > 0 && image.image.height > 0)
    }
    let clip = Clip(recordingID: r.id, requested: try MediaRange(start: a.duration.adding(MediaTime(seconds: -1)), end: a.duration.adding(MediaTime(seconds: 1))))
    let plan = try await MediaEngine.plan(recording: r, clip: clip, displayTimeZone: "Asia/Tokyo")
    #expect(plan.parts.count == 2)
    let root = URL(fileURLWithPath: "/private/tmp/vroma-split-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let began = ContinuousClock.now
    let cache = ArchiveCache()
    let result = try await MediaEngine.export(plan, to: root, archiveCache: cache, fullDecodeValidation: true)
    #expect(result.sources?.count == 2)
    #expect(result.videoPackets == result.decodedFrames)
    #expect(result.actual.start <= clip.requested.start && result.actual.end >= clip.requested.end)
    #expect(result.recordingID == r.id)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".mp4") }
    #expect(files.count == 1)
    let copiedAt = ContinuousClock.now
    let copied = try await MediaEngine.export(plan, to: root, archiveCache: cache)
    #expect(copied.videoSHA256 == result.videoSHA256 && copied.audioSHA256 == result.audioSHA256)
    #expect(copied.videoTimingSHA256 == result.videoTimingSHA256 && copied.audioTimingSHA256 == result.audioTimingSHA256)
    #expect(copied.decodedFrames == 0)
    print("SPLIT COPY WITH ARCHIVE CACHE: \(copiedAt.duration(to: .now))")
    print("SPLIT EXPORT: \(result.videoPackets) frames, \(result.audioPackets) audio packets, \(result.actual.end.seconds - result.actual.start.seconds)s, \(began.duration(to: .now))")
}

@Test func splitMigrationPreservesEditsAndLocalMarksAndDoesNotBridgeMissingChapters() throws {
    let file = try FileReference(url: URL(fileURLWithPath: #filePath))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func recording(_ number: Int, stamp: String = "080012") throws -> Recording {
        Recording(name: String(format: "VID_20260911_\(stamp)_%03d.mp4", number), file: file, duration: try MediaTime(seconds: 100), cameraStart: date)
    }
    let a = try recording(25), b = try recording(26), missing = try recording(28), other = try recording(29, stamp: "090000")
    var p = Project(recordings: [a, b, missing, other])
    let local = try p.addVideoMark(recordingID: b.id, at: MediaTime(seconds: 10))
    let clipID = p.clips[0].id
    p.clips[0].selected = false
    try p.editRange(clipID: clipID, range: MediaRange(start: MediaTime(seconds: 5), end: MediaTime(seconds: 20)))
    p.setExportDirectory("/chosen", recordingID: b.id)
    let migrated = try Project.decode(p.encoded())
    #expect(migrated.recordings.count == 3)
    #expect(migrated.clips[0].id == clipID && migrated.clips[0].recordingID == a.id)
    #expect(migrated.clips[0].requested.start.seconds == 105 && migrated.clips[0].requested.end.seconds == 120)
    #expect(!migrated.clips[0].selected && migrated.clips[0].edited)
    #expect(migrated.timelineMarks(recordingID: a.id).first?.id == local)
    #expect(migrated.timelineMarks(recordingID: a.id).first?.position.seconds == 110)
    #expect(migrated.exportDirectory(recordingID: a.id) == "/chosen")
    #expect(try Project.decode(migrated.encoded()) == migrated)
}

@Test func splitMigrationDeduplicatesAutomaticMarksAndExtendsBoundaryRange() throws {
    let file = try FileReference(url: URL(fileURLWithPath: #filePath)), date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = Recording(name: "VID_20260911_080012_025.mp4", file: file, duration: try MediaTime(seconds: 100), cameraStart: date)
    let b = Recording(name: "VID_20260911_080012_026.mp4", file: file, duration: try MediaTime(seconds: 100), cameraStart: date)
    let mark = Mark(id: "at-seam", date: date.addingTimeInterval(95), comment: "境界直前")
    var p = Project(recordings: [a, b], marks: [mark])
    try p.generateCandidates()
    #expect(p.clips.count == 2)
    let migrated = try Project.decode(p.encoded())
    #expect(migrated.clips.count == 1)
    #expect(migrated.clips[0].requested.start.seconds == 85 && migrated.clips[0].requested.end.seconds == 155)
    #expect(migrated.timelineMarks(recordingID: a.id).count == 1)
}

@Test func groupingUsesNumericSequenceAndDoesNotMixFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var recordings: [Recording] = []
    for folder in ["one", "two"] {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for number in [10, 9] {
            let url = directory.appendingPathComponent("VID_20260911_080012_\(number).mp4")
            try Data([0]).write(to: url)
            recordings.append(Recording(name: url.lastPathComponent, file: try FileReference(url: url), duration: try MediaTime(seconds: Double(number)), cameraStart: Date(timeIntervalSince1970: 0)))
        }
    }
    var p = Project()
    try p.addRecordings(recordings)
    #expect(p.recordings.count == 2)
    #expect(p.recordings.allSatisfy { $0.duration.seconds == 19 && $0.sourceSegments[0].name.hasSuffix("_9.mp4") })
    try p.addRecordings(recordings)
    #expect(p.recordings.count == 2)
}
