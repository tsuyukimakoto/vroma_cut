import Foundation
import Testing
@testable import VromaCutApp

@Test func importLocationsRemainSeparateAcrossRelaunchAndMissingDirectory() throws {
    let suite = "com.tsuyukimakoto.vroma.cut.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let videos = root.appendingPathComponent("Videos/day1"), gpx = root.appendingPathComponent("Tracks/day2")
    try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gpx, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = ImportLocations(defaults: defaults, home: root)
    locations.remember(videos, for: .videos); locations.remember(gpx, for: .gpx)
    let relaunched = ImportLocations(defaults: defaults, home: root)
    #expect(relaunched.initialDirectory(for: .videos).path == videos.path)
    #expect(relaunched.initialDirectory(for: .gpx).path == gpx.path)
    try FileManager.default.removeItem(at: videos)
    #expect(relaunched.initialDirectory(for: .videos).path == videos.deletingLastPathComponent().path)
    #expect(relaunched.initialDirectory(for: .gpx).path == gpx.path)
    try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
    #expect(relaunched.initialDirectory(for: .videos).path == videos.path)
}

@Test func missingImportDirectorySearchStopsAtUserHome() {
    let home = URL(fileURLWithPath: "/Users/alice")
    var visited: [String] = []
    let found = ImportLocations.nearestExistingDirectory(to: home.appendingPathComponent("Movies/trip/day1"), home: home) {
        visited.append($0.path); return $0.path == "/Users/alice/Movies"
    }
    #expect(found?.path == "/Users/alice/Movies")
    #expect(visited == ["/Users/alice/Movies/trip/day1", "/Users/alice/Movies/trip", "/Users/alice/Movies"])
    visited = []
    let missing = ImportLocations.nearestExistingDirectory(to: home.appendingPathComponent("missing"), home: home) {
        visited.append($0.path); return false
    }
    #expect(missing == nil)
    #expect(visited == ["/Users/alice/missing", "/Users/alice"])
}

@Test func missingVolumeNeverSearchesVolumesOrFilesystemRoot() {
    let home = URL(fileURLWithPath: "/Users/alice")
    var visited: [String] = []
    let missing = ImportLocations.nearestExistingDirectory(to: URL(fileURLWithPath: "/Volumes/Camera Card/DCIM/day1"), home: home) {
        visited.append($0.path); return $0.path == "/Volumes" || $0.path == "/"
    }
    #expect(missing == nil)
    #expect(visited == ["/Volumes/Camera Card/DCIM/day1", "/Volumes/Camera Card/DCIM", "/Volumes/Camera Card"])
    let mounted = ImportLocations.nearestExistingDirectory(to: URL(fileURLWithPath: "/Volumes/Camera Card/DCIM/day1"), home: home) {
        $0.path == "/Volumes/Camera Card"
    }
    #expect(mounted?.path == "/Volumes/Camera Card")
}

@Test func importDirectoryBoundaryUsesWholeComponentsAndCustomHome() {
    let home = URL(fileURLWithPath: "/Volumes/Storage/homes/alice")
    var visited: [String] = []
    _ = ImportLocations.nearestExistingDirectory(to: home.appendingPathComponent("Tracks/lost"), home: home) {
        visited.append($0.path); return false
    }
    #expect(visited.last == home.path)
    #expect(!visited.contains("/Volumes/Storage/homes"))
    visited = []
    _ = ImportLocations.nearestExistingDirectory(to: URL(fileURLWithPath: "/Users/alice2/missing"), home: URL(fileURLWithPath: "/Users/alice")) {
        visited.append($0.path); return false
    }
    #expect(visited == ["/Users/alice2/missing", "/Users/alice2"])
}
