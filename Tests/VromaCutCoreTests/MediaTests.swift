import Foundation
import Testing
@testable import VromaCutCore

@Test func gpxUsesTrackPointTimesAndPreviousLocation() throws {
    let gpx = """
    <gpx xmlns="http://www.topografix.com/GPX/1/1"><metadata><time>2000-01-01T00:00:00Z</time></metadata><trk><trkseg>
    <trkpt lat="35" lon="139"><time>2026-09-11T00:00:00Z</time></trkpt>
    <trkpt lat="36" lon="140"><time>2026-09-11T00:00:02Z</time></trkpt>
    </trkseg></trk></gpx>
    """
    let track = try GPXTrack.parse(Data(gpx.utf8))
    #expect(track.points.count == 2)
    #expect(try track.point(at: UTCDate.parse("2026-09-11T00:00:01Z"))?.latitude == 35)
    #expect(try track.point(at: UTCDate.parse("2026-09-11T00:00:03Z")) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VROMA_SAMPLE_DIR"] != nil))
func realSampleImportWhenEnabled() async throws {
    guard let path = ProcessInfo.processInfo.environment["VROMA_SAMPLE_DIR"] else { return }
    let root = URL(fileURLWithPath: path)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    let movie = try #require(files.first { $0.pathExtension.lowercased() == "mp4" })
    let csv = try #require(files.first { $0.pathExtension == "csv" })
    let gpx = try #require(files.first { $0.pathExtension == "gpx" })
    let recording = try await MediaImport.recording(url: movie)
    #expect(abs(recording.duration.seconds - 1224.773550) < 0.000001)
    #expect(recording.cameraStart == (try UTCDate.parse("2026-09-11T01:54:43Z")))
    var project = Project(recordings: [recording], marks: try MarkCSV.parse(String(contentsOf: csv, encoding: .utf8)))
    try project.generateCandidates()
    #expect(project.marks.count == 48)
    #expect(project.clips.count == 1)
    #expect(abs(project.clips[0].requested.start.seconds - 771.754) < 0.000001)
    let track = try GPXTrack.parse(Data(contentsOf: gpx))
    #expect(track.points.count == 20225)
    #expect(track.point(at: project.marks.first { $0.id == project.clips[0].markIDs[0] }!.date) != nil)
}
