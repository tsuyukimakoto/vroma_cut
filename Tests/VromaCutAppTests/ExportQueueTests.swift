import Foundation
import Testing
import VromaCutCore
@testable import VromaCutApp

private func exportFixture() throws -> (Project, UUID, UUID) {
    let ref = try FileReference(url: URL(fileURLWithPath: #filePath))
    let first = Recording(name: "A.mp4", file: ref, duration: try MediaTime(seconds: 100), cameraStart: Date())
    let second = Recording(name: "B.mp4", file: ref, duration: try MediaTime(seconds: 100), cameraStart: Date())
    var project = Project(recordings: [first, second])
    try project.addManual(recordingID: first.id, at: MediaTime(seconds: 20))
    try project.addManual(recordingID: first.id, at: MediaTime(seconds: 30))
    try project.addManual(recordingID: second.id, at: MediaTime(seconds: 40))
    project.clips[1].selected = false
    return (project, first.id, second.id)
}

@Test func exportSelectionAndDestinationBelongToEachRecording() throws {
    var (project, first, second) = try exportFixture()
    let snapshot = try RecordingExportSnapshot(project: project, recordingID: first)
    #expect(snapshot.clips.count == 2)
    #expect(snapshot.clips.allSatisfy { $0.recordingID == first })
    let original = snapshot.clips[0].requested
    try project.editRange(clipID: snapshot.clips[0].id, range: MediaRange(start: .zero, end: MediaTime(seconds: 5)))
    #expect(snapshot.clips[0].requested == original)
    project.setExportDirectory("/tmp/common", recordingID: first)
    #expect(project.exportDirectory(recordingID: second) == "/tmp/common")
    project.setExportDirectory("/tmp/second", recordingID: second)
    #expect(project.exportDirectory(recordingID: first) == "/tmp/common")
    #expect(project.exportDirectory(recordingID: second) == "/tmp/second")
    #expect(try Project.decode(project.encoded()) == project)
}

private actor QueueProbe {
    var running = 0
    var maximum = 0
    var names: [String] = []
    func perform(_ name: String) async throws {
        running += 1; maximum = max(maximum, running); names.append(name)
        defer { running -= 1 }
        try await Task.sleep(for: .milliseconds(80))
    }
}
@MainActor private func drain(_ queue: ExportQueue) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while queue.hasWork && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!queue.hasWork)
}

@Test @MainActor func nextRecordingCanBeQueuedWhileFirstExportsToSameFolder() async throws {
    var (project, first, second) = try exportFixture()
    let queue = ExportQueue(), probe = QueueProbe(), destination = URL(fileURLWithPath: "/tmp/common")
    let a = try RecordingExportSnapshot(project: project, recordingID: first)
    queue.enqueue(snapshot: a, destination: destination) { _, _ in try await probe.perform("A") }
    #expect(queue.hasWork)
    // Editing B while A is running must neither mutate A nor block enqueueing B.
    let bClip = try #require(project.clips.first { $0.recordingID == second })
    try project.editRange(clipID: bClip.id, range: MediaRange(start: MediaTime(seconds: 15), end: MediaTime(seconds: 25)))
    let b = try RecordingExportSnapshot(project: project, recordingID: second)
    queue.enqueue(snapshot: b, destination: destination) { _, _ in try await probe.perform("B") }
    #expect(queue.pendingCount == 1)
    #expect(queue.jobs[0].snapshot.clips[0].requested == a.clips[0].requested)
    #expect(queue.jobs[1].snapshot.clips[0].requested != bClip.requested)
    try await drain(queue)
    #expect(await probe.maximum == 1)
    #expect(await probe.names == ["A", "B"])
    #expect(queue.jobs.allSatisfy { $0.status == .completed })
}

@Test @MainActor func failedAndCancelledJobsDoNotBlockFollowingRecording() async throws {
    let (project, first, second) = try exportFixture()
    let a = try RecordingExportSnapshot(project: project, recordingID: first), b = try RecordingExportSnapshot(project: project, recordingID: second)
    let queue = ExportQueue(), destination = URL(fileURLWithPath: "/tmp/common")
    queue.enqueue(snapshot: a, destination: destination) { _, _ in throw CutError.invalid("test failure") }
    let pending = queue.enqueue(snapshot: b, destination: destination) { _, _ in Issue.record("A cancelled queued job must not start") }
    queue.cancel(pending)
    queue.enqueue(snapshot: b, destination: destination) { _, _ in }
    try await drain(queue)
    #expect(queue.jobs.map(\.status) == [.failed, .cancelled, .completed])
    let active = queue.enqueue(snapshot: a, destination: destination) { _, _ in try await Task.sleep(for: .seconds(30)) }
    queue.enqueue(snapshot: b, destination: destination) { _, _ in }
    queue.cancel(active)
    try await drain(queue)
    #expect(queue.jobs.suffix(2).map(\.status) == [.cancelled, .completed])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_QUEUE_SOURCE"] != nil))
@MainActor func twoQueuedRecordingsWriteDistinctFilesToSameFolder() async throws {
    let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VROMA_QUEUE_SOURCE"]!)
    let original = try await MediaImport.recording(url: source)
    let second = Recording(name: "second", file: original.file, duration: original.duration, cameraStart: original.cameraStart)
    var project = Project(recordings: [original, second])
    for r in project.recordings { project.clips.append(Clip(recordingID: r.id, requested: try MediaRange(start: .zero, end: MediaTime(seconds: 1)))) }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vroma-queue-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    let queue = ExportQueue(), cache = ArchiveCache()
    var results: [ExportRecord] = []
    queue.onRecord = { record in results.append(record) }
    for r in project.recordings {
        let snapshot = try RecordingExportSnapshot(project: project, recordingID: r.id), plans = try await snapshot.plans()
        queue.enqueue(snapshot: snapshot, destination: destination) { progress, record in
            for plan in plans { await record(try await MediaEngine.export(plan, to: destination, archiveCache: cache, progress: progress)) }
        }
    }
    try await drain(queue)
    #expect(queue.jobs.allSatisfy { $0.status == .completed })
    #expect(results.count == 2)
    #expect(Set(results.map(\.outputFile)).count == 2)
    let manifest = try JSONDecoder().decode(ExportManifest.self, from: Data(contentsOf: destination.appendingPathComponent("ExportManifest.json")))
    #expect(manifest.clips.count == 2)
    #expect(results[0].videoSHA256 == results[1].videoSHA256)
}
