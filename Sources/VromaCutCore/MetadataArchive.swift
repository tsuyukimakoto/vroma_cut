import Foundation
import CryptoKit
import Darwin

public struct ArchiveRegion: Codable, Equatable, Sendable {
    public let typeHex: String
    public let offset: UInt64
    public let originalLength: UInt64
    public let archivedLength: UInt64
    public let file: String
    public var sha256: String
}
public struct ArchiveManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let purpose: String
    public let sourceName: String
    public let sourceBytes: UInt64
    public let sourceSHA256: String
    public let archivedBytes: UInt64
    public var regions: [ArchiveRegion]
}
public struct ArchiveResult: Sendable {
    public let directory: URL
    public let manifest: ArchiveManifest
    public let reused: Bool
}

public enum MetadataArchive {
    private static let chunkSize = 8 * 1024 * 1024
    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func read(_ file: FileHandle, offset: UInt64, length: Int) throws -> Data {
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: length) ?? Data()
        guard data.count == length else { throw CutError.invalid("原本が途中で切れています。") }
        return data
    }
    private static func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func signature(_ file: FileHandle) throws -> [Int64] {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { throw CutError.invalid("通常の原本ファイルを開けません。") }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
    private static func digest(_ file: FileHandle, offset: UInt64, length: UInt64, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        var hash = SHA256(), position: UInt64 = 0
        while position < length {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunkSize), length - position))
            try autoreleasepool { hash.update(data: try read(file, offset: offset + position, length: count)) }
            position += UInt64(count)
            if position % (64 * 1024 * 1024) == 0 || position == length { progress?(Double(position) / Double(max(1, length))) }
        }
        return hex(hash.finalize())
    }
    private static func scan(_ file: FileHandle, size: UInt64) throws -> [ArchiveRegion] {
        var offset: UInt64 = 0, regions: [ArchiveRegion] = []
        while offset < size {
            guard size - offset >= 8 else { throw CutError.invalid("MP4末尾の領域を解釈できません。") }
            let header = try read(file, offset: offset, length: 8)
            var length = number(header.prefix(4)), headerLength: UInt64 = 8
            if length == 1 {
                guard size - offset >= 16 else { throw CutError.invalid("64-bit boxヘッダーが途中で切れています。") }
                length = number(try read(file, offset: offset + 8, length: 8)); headerLength = 16
            } else if length == 0 { length = size - offset }
            guard length >= headerLength, length <= size - offset else { throw CutError.invalid("MP4 boxの長さが不正です。") }
            let type = hex(header.suffix(4))
            regions.append(ArchiveRegion(typeHex: type, offset: offset, originalLength: length,
                archivedLength: type == "6d646174" ? headerLength : length,
                file: String(format: "%04d", regions.count) + "-" + type + ".bin", sha256: ""))
            offset += length
        }
        guard regions.contains(where: { $0.typeHex == "6d6f6f76" }), regions.contains(where: { $0.typeHex == "6d646174" }) else { throw CutError.invalid("moovとmdatのあるMP4が必要です。") }
        return regions
    }
    private static func checkSource(_ source: URL, handle: FileHandle, before: [Int64]) throws {
        let current = try FileHandle(forReadingFrom: source); defer { try? current.close() }
        guard try signature(handle) == before, try signature(current) == before else { throw CutError.invalid("退避中に原本が変更されました。") }
    }
    private static func verify(directory: URL, expected: ArchiveManifest, source: FileHandle) throws {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CutError.invalid("退避先が通常のフォルダではありません。") }
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest == expected else { throw CutError.invalid("退避manifestが原本と一致しません。") }
        for region in expected.regions {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(region.file)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, UInt64(values.fileSize ?? 0) == region.archivedLength else { throw CutError.invalid("退避ファイルの種類または長さが不正です: \(region.file)") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            guard try digest(handle, offset: 0, length: region.archivedLength) == region.sha256,
                  try digest(source, offset: region.offset, length: region.archivedLength) == region.sha256 else { throw CutError.invalid("退避データのSHA-256が一致しません: \(region.file)") }
        }
    }
    public static func archive(source: URL, root: URL, cache: ArchiveCache? = nil, progress: (@Sendable (ExportProgress) -> Void)? = nil) throws -> ArchiveResult {
        let file = try FileHandle(forReadingFrom: source); defer { try? file.close() }
        let before = try signature(file), size = UInt64(before[2])
        var regions = try scan(file, size: size)
        let sourceHash: String
        if let cached = cache?.digest(path: source.path, signature: before) {
            sourceHash = cached
        } else {
            progress?(ExportProgress("原本を識別しています（初回のみ全体を読み取り）", fraction: 0))
            sourceHash = try digest(file, offset: 0, length: size) { fraction in
                progress?(ExportProgress("原本を識別しています（初回のみ全体を読み取り）", fraction: fraction))
            }
            try checkSource(source, handle: file, before: before)
            cache?.remember(path: source.path, signature: before, digest: sourceHash)
        }
        progress?(ExportProgress("原本の追加データを保存・照合しています"))
        for i in regions.indices { regions[i].sha256 = try digest(file, offset: regions[i].offset, length: regions[i].archivedLength) }
        let manifest = ArchiveManifest(schemaVersion: 1,
            purpose: "Unmodified source boxes excluding mdat payload. Not a backup or a guarantee of restoration or vendor-software reuse.",
            sourceName: source.lastPathComponent, sourceBytes: size, sourceSHA256: sourceHash,
            archivedBytes: regions.reduce(0) { $0 + $1.archivedLength }, regions: regions)
        try checkSource(source, handle: file, before: before)
        let fm = FileManager.default, directory = root.appendingPathComponent(sourceHash)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: directory.path) {
            // Source filename may change; archive identity is its full content digest.
            let stored = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            let expected = ArchiveManifest(schemaVersion: manifest.schemaVersion, purpose: manifest.purpose, sourceName: stored.sourceName,
                sourceBytes: manifest.sourceBytes, sourceSHA256: manifest.sourceSHA256, archivedBytes: manifest.archivedBytes, regions: manifest.regions)
            try verify(directory: directory, expected: expected, source: file)
            try checkSource(source, handle: file, before: before)
            return ArchiveResult(directory: directory, manifest: expected, reused: true)
        }
        let staging = root.appendingPathComponent(".partial-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for region in regions {
            let destination = staging.appendingPathComponent(region.file)
            guard fm.createFile(atPath: destination.path, contents: nil) else { throw CutError.invalid("退避ファイルを作成できません。") }
            let output = try FileHandle(forWritingTo: destination)
            do {
                var position: UInt64 = 0
                while position < region.archivedLength {
                    try Task.checkCancellation()
                    let count = Int(min(UInt64(chunkSize), region.archivedLength - position))
                    try autoreleasepool { try output.write(contentsOf: read(file, offset: region.offset + position, length: count)) }; position += UInt64(count)
                }
                try output.synchronize(); try output.close()
            } catch { try? output.close(); throw error }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try verify(directory: staging, expected: manifest, source: file)
        try checkSource(source, handle: file, before: before)
        guard renamex_np(staging.path, directory.path, UInt32(RENAME_EXCL)) == 0 else { throw CutError.invalid("退避先の確定が競合または失敗しました。再試行してください。") }
        return ArchiveResult(directory: directory, manifest: manifest, reused: false)
    }
}
