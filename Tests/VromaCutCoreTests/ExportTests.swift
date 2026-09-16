import Foundation
import Testing
@testable import VromaCutCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_EXPORT_SOURCE"] != nil && ProcessInfo.processInfo.environment["VROMA_EXPORT_ROOT"] != nil))
func realSampleExportWhenEnabled() async throws {
    guard let sourcePath = ProcessInfo.processInfo.environment["VROMA_EXPORT_SOURCE"], let destination = ProcessInfo.processInfo.environment["VROMA_EXPORT_ROOT"] else { return }
    let recording = try await MediaImport.recording(url: URL(fileURLWithPath: sourcePath))
    let clip = Clip(recordingID: recording.id, requested: try MediaRange(start: MediaTime(seconds: 771.754), end: MediaTime(seconds: 841.754)))
    let clock = ContinuousClock(), began = ContinuousClock.now
    let plan = try await MediaEngine.plan(recording: recording, clip: clip, displayTimeZone: "Asia/Tokyo")
    #expect(plan.planned.start <= clip.requested.start)
    #expect(plan.planned.end >= clip.requested.end)
    print("PLAN WALL: \(began.duration(to: clock.now)), bytes read=\(plan.sourceBytesRead)")
    #expect(plan.sourceBytesRead < 32 * 1024 * 1024)
    let cache = ArchiveCache(), exportBegan = clock.now
    let full = ProcessInfo.processInfo.environment["VROMA_FULL_DECODE"] == "1"
    let result = try await MediaEngine.export(plan, to: URL(fileURLWithPath: destination), archiveCache: cache, fullDecodeValidation: full)
    print("EXPORT INCLUDING ARCHIVE: \(exportBegan.duration(to: clock.now))")
    #expect(result.verification == (full ? "packet-hash-and-full-decode" : "packet-hash-and-timing"))
    #expect(result.videoSHA256 == "40f833ceb58883fde1d8aa8c6ce7660b8c96d8413ecdbd6afb2db85a8e12d0fc")
    #expect(result.audioSHA256 == "7071ae51a755456b48aff9bb48d9abac9ba19a1e5e12e7cd62c81c70cf2d7cc3")
    #expect(result.videoTimingSHA256 == "d987866e835df196cfcf58055758e6b650588e646c3d65c640810e123fdf3d60")
    #expect(result.audioTimingSHA256 == "4a40b7cdc415137b7d8de2c59c0b972421c717ef63d783ab68a6d563136aecad")
    #expect(result.sourceSHA256 == "817f92f70b99a3db392d3b7f2003ffb01c3a634b274f64a42c7d507447f45ca0")
    #expect((result.sourceBytesRead ?? Int64.max) < 1024 * 1024 * 1024)
    if !full {
        let again = clock.now
        _ = try await MediaEngine.export(plan, to: URL(fileURLWithPath: destination), archiveCache: cache)
        print("EXPORT REUSING SOURCE DIGEST: \(again.duration(to: clock.now))")
        let (updates, continuation) = AsyncStream<ExportProgress>.makeStream()
        let cancelledRoot = URL(fileURLWithPath: destination).appendingPathComponent("cancelled")
        let cancelled = Task {
            defer { continuation.finish() }
            return try await MediaEngine.export(plan, to: cancelledRoot, archiveCache: cache, fullDecodeValidation: true) { continuation.yield($0) }
        }
        for await update in updates where update.phase.contains("全フレーム") {
            cancelled.cancel(); break
        }
        let cancelBegan = clock.now
        do { _ = try await cancelled.value; Issue.record("Expected cancellation during media verification") }
        catch is CancellationError { }
        #expect(cancelBegan.duration(to: clock.now) < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: cancelledRoot.appendingPathComponent("ExportManifest.json").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cancelledRoot.path)
        #expect(!leftovers.contains { $0.hasPrefix(".export-") || $0.hasSuffix(".mp4") })
        for requested in [try MediaRange(start: .zero, end: MediaTime(seconds: 1)), try MediaRange(start: recording.duration.adding(MediaTime(seconds: -1)), end: recording.duration)] {
            let boundary = Clip(recordingID: recording.id, requested: requested)
            let boundaryPlan = try await MediaEngine.plan(recording: recording, clip: boundary, displayTimeZone: "Asia/Tokyo")
            let exported = try await MediaEngine.export(boundaryPlan, to: URL(fileURLWithPath: destination), archiveCache: cache, fullDecodeValidation: true)
            #expect(exported.videoPackets == exported.decodedFrames)
            #expect(exported.actual.start <= requested.start && exported.actual.end >= requested.end)
        }
    }
    #expect(result.decodedFrames == (full ? result.videoPackets : 0))
    #expect(result.videoPackets > 4000)
    #expect(result.videoSHA256.count == 64)
    print("EXPORT VERIFIED: \(result.outputFile), \(result.actual.start.seconds)...\(result.actual.end.seconds), video=\(result.videoPackets) audio=\(result.audioPackets) decoded=\(result.decodedFrames)")
}

@Test func cancelledPlanDoesNotOpenSource() async throws {
    let r = Recording(name: "test", file: try FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: 100), cameraStart: Date())
    let c = Clip(recordingID: r.id, requested: try MediaRange(start: MediaTime(seconds: 10), end: MediaTime(seconds: 20)))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await MediaEngine.plan(recording: r, clip: c, displayTimeZone: "Asia/Tokyo")
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError { }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_BOUNDARY_SOURCE"] != nil))
func rationalRecordingEndRemainsExportable() async throws {
    let source = ProcessInfo.processInfo.environment["VROMA_BOUNDARY_SOURCE"]!
    let r = try await MediaImport.recording(url: URL(fileURLWithPath: source))
    let clip = Clip(recordingID: r.id, requested: try MediaRange(start: r.duration.adding(MediaTime(seconds: -1)), end: r.duration))
    let plan = try await MediaEngine.plan(recording: r, clip: clip, displayTimeZone: "Asia/Tokyo")
    #expect(plan.planned.end == r.duration)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_VIDEO_FOLDER"] != nil && ProcessInfo.processInfo.environment["VROMA_GPX"] != nil))
func allUserCandidatesPlanWithoutReadingWholeRecordings() async throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VROMA_VIDEO_FOLDER"]!)
    var project = Project()
    try project.importTrack(TrackImport.load(gpx: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VROMA_GPX"]!)))
    let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.path < $1.path }
    for url in urls { try project.addRecordings([try await MediaImport.recording(url: url)]) }
    let began = ContinuousClock.now
    var bytes: Int64 = 0
    for clip in project.clips {
        let recording = try #require(project.recordings.first { $0.id == clip.recordingID })
        let plan = try await MediaEngine.plan(recording: recording, clip: clip, displayTimeZone: project.displayTimeZone)
        #expect(plan.planned.start <= clip.requested.start && plan.planned.end >= clip.requested.end)
        bytes += plan.sourceBytesRead
    }
    #expect(project.clips.count > 1)
    print("FOLDER PLAN: \(project.recordings.count) videos, \(project.clips.count) candidates, \(began.duration(to: .now)), bytes=\(bytes)")
}
