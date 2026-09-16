import Foundation
import Testing
@testable import VromaCutCore

@Test func quotedCSVAndStableIDs() throws {
    let csv = "\u{feff}2026-09-11T02:07:44.754Z,ignored,\"a,b\n\"\"quoted\"\"\"\r\n"
    let marks = try MarkCSV.parse(csv)
    #expect(marks.count == 1)
    #expect(marks[0].comment == "a,b\n\"quoted\"")
    #expect(try MarkCSV.parse(csv)[0].id == marks[0].id)
    #expect(throws: (any Error).self) { try MarkCSV.parse("bad,ignored,comment") }
    #expect(throws: (any Error).self) { try MarkCSV.parse("\"unfinished") }
}

@Test func markMappingCorrectionAndRoundTrip() throws {
    let start = try UTCDate.parse("2026-09-11T01:54:43Z")
    let source = Recording(name: "sample", file: try FileReference(url: URL(fileURLWithPath: #filePath)),
                           duration: try MediaTime(seconds: 1224.773550), cameraStart: start)
    let marks = try MarkCSV.parse("2026-09-11T02:07:44.754Z,ignored,one\n2026-09-12T00:00:00Z,ignored,outside")
    var project = Project(recordings: [source], marks: marks)
    try project.generateCandidates()
    #expect(project.clips.count == 1)
    #expect(abs(project.clips[0].requested.start.seconds - 771.754) < 0.000001)
    try project.generateCandidates()
    #expect(project.clips.count == 1)
    try project.setCorrection(try MediaTime(seconds: 30), recordingID: source.id)
    #expect(abs(project.clips[0].requested.start.seconds - 741.754) < 0.000001)
    try project.editRange(clipID: project.clips[0].id, range: MediaRange(start: MediaTime(seconds: 740), end: MediaTime(seconds: 800)))
    try project.setCorrection(try MediaTime(seconds: -10), recordingID: source.id)
    #expect(project.clips[0].requested.start.seconds == 740)
    #expect(project.clips[0].needsReview)
    let decoded = try Project.decode(project.encoded())
    #expect(decoded == project)
}

@Test func halfOpenAndInvalidRanges() throws {
    let start = try UTCDate.parse("2026-09-11T00:00:00Z")
    let r = Recording(name: "r", file: try FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: 10), cameraStart: start)
    var p = Project(recordings: [r], marks: try MarkCSV.parse("2026-09-11T00:00:00Z,x,start\n2026-09-11T00:00:10Z,x,end"))
    try p.generateCandidates()
    #expect(p.clips.count == 1)
    #expect(p.unmatchedMarks.count == 1)
    #expect(throws: (any Error).self) { try MediaRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 1)) }
    #expect(throws: (any Error).self) { try MediaTime(seconds: .nan) }
}

@Test func duplicateIncomingMarksAndDeletedCandidate() throws {
    let file = try FileReference(url: URL(fileURLWithPath: #filePath))
    let r = Recording(name: "r", file: file, duration: try MediaTime(seconds: 100), cameraStart: try UTCDate.parse("2026-09-11T00:00:00Z"))
    let marks = try MarkCSV.parse("2026-09-11T00:00:20Z,x,mark")
    var p = Project(recordings: [r])
    try p.importMarks(marks + marks)
    try p.validate()
    #expect(p.marks.count == 1)
    #expect(p.clips.count == 1)
    p.clips = []
    try p.generateCandidates()
    #expect(p.clips.isEmpty)
}

@Test func rationalTimeAndProjectValidation() throws {
    #expect(try MediaTime(value: 1001, timescale: 60000) == MediaTime(value: 2002, timescale: 120000))
    #expect(try Set([MediaTime(value: 1001, timescale: 60000), MediaTime(value: 2002, timescale: 120000)]).count == 1)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(MediaTime.self, from: Data("{\"value\":1,\"timescale\":0}".utf8)) }
    var p = Project(); p.displayTimeZone = "not-a-time-zone"
    #expect(throws: (any Error).self) { try p.encoded() }
}

@Test func mergingPreservesMarkOrigins() throws {
    let r = Recording(name: "r", file: try FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: 100), cameraStart: try UTCDate.parse("2026-09-11T00:00:00Z"))
    var p = Project(recordings: [r], marks: try MarkCSV.parse("2026-09-11T00:00:20Z,x,one\n2026-09-11T00:00:30Z,x,two"))
    try p.generateCandidates()
    try p.merge(Set(p.clips.map(\.id)))
    #expect(p.clips.count == 1)
    #expect(p.clips[0].markIDs.count == 2)
    #expect(p.clips[0].requested.start.seconds == 10)
    #expect(p.clips[0].requested.end.seconds == 90)
    try p.generateCandidates()
    #expect(p.clips.count == 1)
}
