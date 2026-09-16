import Foundation

enum ImportSource: String { case videos, gpx }

struct ImportLocations {
    let defaults: UserDefaults
    let home: URL
    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults; self.home = home.standardizedFileURL
    }
    func remember(_ directory: URL, for source: ImportSource) {
        defaults.set(directory.standardizedFileURL.path, forKey: key(source))
    }
    func initialDirectory(for source: ImportSource) -> URL {
        guard let path = defaults.string(forKey: key(source)), path.hasPrefix("/") else { return home }
        return Self.nearestExistingDirectory(to: URL(fileURLWithPath: path), home: home) ?? home
    }
    private func key(_ source: ImportSource) -> String { "importDirectory.v1.\(source.rawValue)" }

    static func nearestExistingDirectory(to directory: URL, home: URL,
                                         isDirectory: (URL) -> Bool = accessibleDirectory) -> URL? {
        guard directory.isFileURL else { return nil }
        var candidate = directory.standardizedFileURL
        let parts = candidate.pathComponents
        let homeParts = home.standardizedFileURL.pathComponents
        let boundaryDepth: Int
        if parts.starts(with: homeParts) {
            boundaryDepth = homeParts.count
        } else if parts.count >= 2, ["Users", "Volumes"].contains(parts[1]) {
            // Include the individual user or volume, never its containing directory.
            boundaryDepth = min(3, parts.count)
        } else {
            boundaryDepth = 1
        }
        while true {
            if isDirectory(candidate) { return candidate }
            guard candidate.pathComponents.count > boundaryDepth else { return nil }
            candidate.deleteLastPathComponent()
        }
    }
    private static func accessibleDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path) && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
