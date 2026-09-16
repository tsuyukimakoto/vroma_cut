import Foundation
import Testing
@testable import VromaCutCore

private func recording(_ start: String = "2026-09-11T00:00:00Z", duration: Double = 300) throws -> Recording {
    Recording(name: "camera.mp4", file: try FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: duration), cameraStart: try UTCDate.parse(start))
}

@Test func separateGPXImportFindsOnlyMatchingCSV() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gpx = root.appendingPathComponent("ride.gpx")
    try Data("<gpx><trk><trkseg><trkpt lat=\"35\" lon=\"139\"><time>2026-09-11T00:00:20Z</time></trkpt></trkseg></trk></gpx>".utf8).write(to: gpx)
    try Data("2026-09-11T00:00:20Z,x,one".utf8).write(to: root.appendingPathComponent("ride.marks.csv"))
    try Data("not a csv".utf8).write(to: root.appendingPathComponent("unrelated.marks.csv"))
    let bundle = try TrackImport.load(gpx: gpx)
    #expect(bundle.marks.count == 1)
    #expect(bundle.markFile?.path.hasSuffix("ride.marks.csv") == true)
    var p = Project()
    try p.importTrack(bundle)
    let r = try recording()
    try p.addRecordings([r])
    #expect(p.clips.count == 1)
    #expect(p.initialReview()?.position.seconds == 10)
    try p.importTrack(bundle)
    #expect(p.clips.count == 1)
    #expect(p.tracks.count == 1)
}

@Test func chronologicalMarksNavigateIndependentlyOfClipInsertion() throws {
    let r = try recording()
    var p = Project(recordings: [r], marks: try MarkCSV.parse("2026-09-11T00:03:00Z,x,late\n2026-09-11T00:00:20Z,x,first\n2026-09-11T00:01:00Z,x,middle"))
    try p.generateCandidates()
    let marks = p.timelineMarks(recordingID: r.id)
    #expect(marks.map(\.position.seconds) == [20, 60, 180])
    #expect(p.initialReview()?.markID == marks[0].id)
    #expect(p.initialReview()?.position.seconds == 10)
    #expect(p.adjacentMark(recordingID: r.id, currentID: marks[0].id, position: .zero, direction: 1)?.id == marks[1].id)
    #expect(p.adjacentMark(recordingID: r.id, currentID: marks[2].id, position: .zero, direction: 1) == nil)
    #expect(p.adjacentMark(recordingID: r.id, currentID: marks[0].id, position: .zero, direction: -1) == nil)
}

@Test func addedVideoMarkKeepsItsPositionAfterClockAdjustment() throws {
    let r = try recording()
    var p = Project(recordings: [r])
    let id = try p.addVideoMark(recordingID: r.id, at: MediaTime(seconds: 100), comment: "look here")
    #expect(p.timelineMarks(recordingID: r.id).first?.position.seconds == 100)
    #expect(p.clips.first?.requested.start.seconds == 90)
    try p.setCorrection(MediaTime(seconds: 20), recordingID: r.id)
    #expect(p.timelineMarks(recordingID: r.id).first?.id == id)
    #expect(p.timelineMarks(recordingID: r.id).first?.position.seconds == 100)
    #expect(p.clips.first?.requested.start.seconds == 90)
    #expect(try Project.decode(p.encoded()) == p)
}

@Test func clockShiftHandlesYearsMonthsAndOldCameraDefaults() throws {
    let anchor = try UTCDate.parse("2000-01-31T03:04:05Z")
    let shift = ClockShift(years: 26, months: 1, days: 0, hours: 2, minutes: 3, seconds: 0.25)
    let adjusted = try shift.adjustedDate(from: anchor, timeZone: "Asia/Tokyo")
    #expect(abs(adjusted.timeIntervalSince(try UTCDate.parse("2026-02-28T05:07:05.250Z"))) < 0.000001)
    let backwards = ClockShift(direction: .backward, years: 1, days: 1)
    #expect(try backwards.adjustedDate(from: UTCDate.parse("2024-03-01T00:00:00Z"), timeZone: "UTC") == UTCDate.parse("2023-02-28T00:00:00Z"))
    #expect(throws: (any Error).self) { try ClockShift(months: -1).adjustedDate(from: anchor, timeZone: "UTC") }
}

@Test func projectClockShiftAppliesConstantOffsetToLaterImports() throws {
    let r = try recording("2000-09-11T00:00:00Z")
    var p = Project(recordings: [r], marks: try MarkCSV.parse("2026-09-11T00:00:20Z,x,one"))
    try p.applyClockShift(ClockShift(years: 26), referenceRecordingID: r.id)
    #expect(p.clips.count == 1)
    #expect(p.clips[0].requested.start.seconds == 10)
    var next = try recording("2000-09-11T00:10:00Z")
    next.name = "next.mp4"
    // A different file reference is required for a second physical recording.
    next.file = try FileReference(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("EditingTests.swift"))
    try p.addRecordings([next])
    #expect(p.recordings.count == 2)
    #expect(p.recordings[0].correction == p.recordings[1].correction)
    #expect(try Project.decode(p.encoded()) == p)
}
