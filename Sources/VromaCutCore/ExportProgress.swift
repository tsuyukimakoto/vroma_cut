import Foundation

public struct ExportProgress: Sendable {
    public let phase: String
    public let fraction: Double?
    public init(_ phase: String, fraction: Double? = nil) { self.phase = phase; self.fraction = fraction }
}

// In-memory only. A digest can be reused only while device/inode/size/mtime/ctime
// all still match. Archives themselves are still read back and verified.
public final class ArchiveCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (signature: [Int64], digest: String)] = [:]
    func digest(path: String, signature: [Int64]) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature else { return nil }
        return entry.digest
    }
    func remember(path: String, signature: [Int64], digest: String) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (signature, digest)
    }
    public init() {}
}
