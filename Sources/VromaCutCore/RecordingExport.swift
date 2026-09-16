import Foundation

/// Immutable selection for one recording. Edits after confirmation do not alter it.
public struct RecordingExportSnapshot: Sendable {
    public let recording: Recording
    public let clips: [Clip]
    public let displayTimeZone: String
    public init(project: Project, recordingID: UUID) throws {
        guard let recording = project.recordings.first(where: { $0.id == recordingID }) else { throw CutError.invalid("書き出す動画を選択してください。") }
        let clips = project.clips.filter { $0.recordingID == recordingID }.sorted { $0.requested.start < $1.requested.start }
        guard !clips.isEmpty else { throw CutError.invalid("この動画に書き出す範囲を追加してください。") }
        self.recording = recording; self.clips = clips; displayTimeZone = project.displayTimeZone
    }
    public func plans(progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws -> [ExportPlan] {
        var result: [ExportPlan] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            progress?(ExportProgress("\(recording.name) · \(index + 1)/\(clips.count)件の範囲を確認", fraction: Double(index) / Double(clips.count)))
            result.append(try await MediaEngine.plan(recording: recording, clip: clip, displayTimeZone: displayTimeZone))
        }
        return result
    }
}

extension Project {
    public func exportDirectory(recordingID: UUID) -> String? { exportDirectories?[recordingID.uuidString] ?? lastExportDirectory }
    public mutating func setExportDirectory(_ path: String, recordingID: UUID) {
        if exportDirectories == nil { exportDirectories = [:] }
        exportDirectories?[recordingID.uuidString] = path
        lastExportDirectory = path
    }
}
