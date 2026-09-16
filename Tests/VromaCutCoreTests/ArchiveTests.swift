import Foundation
import Testing
@testable import VromaCutCore

private func box(_ type: String, _ bytes: [UInt8], extended: Bool = false) -> Data {
    var data = Data()
    func number(_ n: UInt64, width: Int) { for i in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: n >> (i * 8))) } }
    number(extended ? 1 : UInt64(bytes.count + 8), width: 4)
    data.append(contentsOf: type.utf8)
    if extended { number(UInt64(bytes.count + 16), width: 8) }
    data.append(contentsOf: bytes)
    return data
}

@Test func metadataPreservesUnknownBoxesAndChecksReuse() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    let data = box("ftyp", [1, 2]) + box("mdat", Array(repeating: 7, count: 100), extended: true) + box("moov", [3]) + box("inst", [4, 5])
    try data.write(to: source)
    let archiveRoot = root.appendingPathComponent("SourceMetadata")
    let first = try MetadataArchive.archive(source: source, root: archiveRoot)
    #expect(!first.reused)
    #expect(first.manifest.regions.count == 4)
    #expect(first.manifest.regions[1].archivedLength == 16)
    #expect(first.manifest.archivedBytes == UInt64(data.count - 100))
    #expect(try Data(contentsOf: source) == data)
    #expect(try MetadataArchive.archive(source: source, root: archiveRoot).reused)
    try Data([0]).write(to: first.directory.appendingPathComponent(first.manifest.regions[3].file))
    #expect(throws: (any Error).self) { try MetadataArchive.archive(source: source, root: archiveRoot) }
}

@Test func malformedBoxIsRejectedWithoutPublishedArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try (box("moov", []) + Data([0, 0, 0, 100, 109, 100, 97, 116])).write(to: source)
    #expect(throws: (any Error).self) { try MetadataArchive.archive(source: source, root: root.appendingPathComponent("archive")) }
}

@Test func archiveCacheDetectsChangedMediaEvenWhenModificationDateIsRestored() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4"), archiveRoot = root.appendingPathComponent("archive")
    let original = box("ftyp", [1, 2]) + box("mdat", Array(repeating: 7, count: 100)) + box("moov", [3])
    try original.write(to: source)
    let cache = ArchiveCache()
    let first = try MetadataArchive.archive(source: source, root: archiveRoot, cache: cache)
    #expect(try MetadataArchive.archive(source: source, root: archiveRoot, cache: cache).manifest.sourceSHA256 == first.manifest.sourceSHA256)
    let modified = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]!
    let file = try FileHandle(forWritingTo: source)
    try file.seek(toOffset: 22); try file.write(contentsOf: Data([8])); try file.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
    let changed = try MetadataArchive.archive(source: source, root: archiveRoot, cache: cache)
    #expect(changed.manifest.sourceSHA256 != first.manifest.sourceSHA256)
    // Cached source identity never excuses a damaged archive.
    try Data([0]).write(to: changed.directory.appendingPathComponent(changed.manifest.regions[2].file))
    #expect(throws: (any Error).self) { try MetadataArchive.archive(source: source, root: archiveRoot, cache: cache) }
}
