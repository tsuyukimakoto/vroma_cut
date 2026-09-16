import Foundation
import AVFoundation
import CLibAVBridge
import Darwin

public struct ExportPlan: Sendable {
    public let recording: Recording
    public let clip: Clip
    public let planned: MediaRange
    public let creationDate: Date
    public let displayTimeZone: String
    public var sourceBytesRead: Int64 { parts.reduce(0) { $0 + $1.raw.source_bytes_read } }
    let parts: [ExportPart]
    var raw: VCPlan { parts[0].raw }
}
struct ExportPart: Sendable { let file: FileReference; let raw: VCPlan }
public struct ExportSource: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let metadata: String
    public var range: MediaRange?
}
public struct ExportRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let clipID: UUID
    public let recordingID: UUID
    public let sourceSHA256: String
    public let sourceMetadata: String
    public let requested: MediaRange
    public let planned: MediaRange
    public let actual: MediaRange
    public let creationDate: Date
    public let engineVersion: String
    public let videoPackets: Int64
    public let audioPackets: Int64
    public let decodedFrames: Int64
    public var audioBoundaryAdjustments: Int?
    public var sources: [ExportSource]?
    public var verification: String?
    public var sourceBytesRead: Int64?
    public let videoSHA256: String
    public let audioSHA256: String
    public let videoTimingSHA256: String?
    public let audioTimingSHA256: String?
    public let timecodeHandling: String
    public let outputFile: String
}
public struct ExportManifest: Codable, Sendable {
    public var schemaVersion = 1
    public var clips: [ExportRecord] = []
}
public enum MediaEngine {
    public static func plan(recording: Recording, clip: Clip, displayTimeZone: String) async throws -> ExportPlan {
        let control = try MediaControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try makePlan(recording: recording, clip: clip, displayTimeZone: displayTimeZone, control: control)
        } onCancel: { control.cancel() }
    }
    private static func makePlan(recording: Recording, clip: Clip, displayTimeZone: String, control: MediaControl) throws -> ExportPlan {
        guard clip.recordingID == recording.id, !clip.needsReview, clip.requested.end <= recording.duration, TimeZone(identifier: displayTimeZone) != nil else { throw CutError.invalid("範囲と時刻合わせを再確認してください。") }
        guard recording.cameraStart != nil else { throw CutError.invalid("録画開始日時が未確定です。") }
        var parts: [ExportPart] = [], offset = MediaTime.zero
        var globalStart: MediaTime?, globalEnd: MediaTime?
        for segment in recording.sourceSegments {
            let segmentEnd = try offset.adding(segment.duration)
            defer { offset = segmentEnd }
            let start = max(offset, clip.requested.start), end = min(segmentEnd, clip.requested.end)
            guard start < end else { continue }
            let source = try segment.file.resolve()
            var raw = VCPlan(), error = [CChar](repeating: 0, count: 1024)
            let localStart = try MediaTime(CMTimeSubtract(start.cmTime, offset.cmTime))
            let localEnd = try MediaTime(CMTimeSubtract(end.cmTime, offset.cmTime))
            let status = vc_plan(source.path, VCTime(value: localStart.value, scale: localStart.timescale), VCTime(value: localEnd.value, scale: localEnd.timescale), &raw, &error, error.count, control.pointer)
            try Task.checkCancellation()
            guard status == 0 else { throw CutError.invalid(segment.name + ": " + errorText(error)) }
            _ = try segment.file.resolve()
            let plannedStart = try MediaTime(value: raw.start.value, timescale: raw.start.scale)
            let plannedEnd = try MediaTime(value: raw.end.value, timescale: raw.end.scale)
            guard plannedStart <= localStart, plannedEnd >= localEnd,
                  (start != offset || plannedStart == .zero),
                  (end != segmentEnd || plannedEnd == segment.duration) else { throw CutError.invalid("分割境界を含む出力区間を確定できません。") }
            if globalStart == nil { globalStart = try offset.adding(plannedStart) }
            globalEnd = try offset.adding(plannedEnd)
            parts.append(ExportPart(file: segment.file, raw: raw))
        }
        guard let globalStart, let globalEnd else { throw CutError.invalid("書き出す区間がありません。") }
        let range = try MediaRange(start: globalStart, end: globalEnd)
        return ExportPlan(recording: recording, clip: clip, planned: range, creationDate: recording.absoluteDate(at: range.start)!, displayTimeZone: displayTimeZone, parts: parts)
    }
    private static func preciseDate(_ date: Date) -> String {
        let whole = floor(date.timeIntervalSince1970)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        // Rounding into the next second is handled before formatting.
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let seconds = micros / 1_000_000, fraction = micros % 1_000_000
        if fraction < 0 { return formatter.string(from: Date(timeIntervalSince1970: whole)).replacingOccurrences(of: "Z", with: String(format: ".%06dZ", Int((date.timeIntervalSince1970 - whole) * 1_000_000))) }
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds))).replacingOccurrences(of: "Z", with: String(format: ".%06lldZ", fraction))
    }
    public static func export(_ plan: ExportPlan, to root: URL, archiveCache: ArchiveCache? = nil, fullDecodeValidation: Bool = false, progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws -> ExportRecord {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lockFD = open(root.appendingPathComponent(".vroma-export.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw CutError.invalid("書き出し先のロックを作れません。") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CutError.invalid("同じ保存先への書き出しが進行中です。完了後に再試行してください。") }
        defer { flock(lockFD, LOCK_UN) }
        let manifestURL = root.appendingPathComponent("ExportManifest.json")
        var manifest = ExportManifest()
        if fm.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(ExportManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == 1 else { throw CutError.invalid("未対応の書き出しmanifestです。") }
        }
        var sources: [ExportSource] = []
        for part in plan.parts {
            let source = try part.file.resolve()
            let archive = try MetadataArchive.archive(source: source, root: root.appendingPathComponent("SourceMetadata"), cache: archiveCache, progress: progress)
            sources.append(ExportSource(path: source.path, sha256: archive.manifest.sourceSHA256, metadata: "SourceMetadata/" + archive.manifest.sourceSHA256 + "/manifest.json", range: try MediaRange(start: MediaTime(value: part.raw.start.value, timescale: part.raw.start.scale), end: MediaTime(value: part.raw.end.value, timescale: part.raw.end.scale))))
        }
        try Task.checkCancellation()
        let stage = root.appendingPathComponent(".export-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let media = stage.appendingPathComponent("clip.mp4")
        var raw = plan.parts.map(\.raw), result = VCResult(), error = [CChar](repeating: 0, count: 1024)
        let control = try MediaControl()
        vc_control_set_full_decode(control.pointer, fullDecodeValidation ? 1 : 0)
        let monitor = Task.detached {
            while !Task.isCancelled {
                let value = vc_control_progress(control.pointer)
                if value.phase != 0 {
                    progress?(ExportProgress(value.phase == 1 ? "映像と音声をコピーしています" : (fullDecodeValidation ? "圧縮データと全フレームを検証しています" : "圧縮データと時刻を照合しています"), fraction: value.total > 0 ? min(1, max(0, Double(value.completed) / Double(value.total))) : nil))
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        let status = try await withTaskCancellationHandler {
            var strings: [UnsafeMutablePointer<CChar>] = []
            defer { for string in strings { free(string) } }
            for source in sources {
                guard let string = strdup(source.path) else { throw CutError.invalid("素材パスの領域を確保できません。") }
                strings.append(string)
            }
            let pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
            return vc_export_segments(pointers, &raw, Int32(raw.count), media.path, preciseDate(plan.creationDate), &result, &error, error.count, control.pointer)
        } onCancel: { control.cancel() }
        monitor.cancel()
        guard status == 0 else { try Task.checkCancellation(); throw CutError.invalid(errorText(error)) }
        try Task.checkCancellation()
        for part in plan.parts { _ = try part.file.resolve() }
        progress?(ExportProgress("撮影日時と出力範囲を確認しています"))
        try ControlledMovieDate.finalize(stagingURL: media)
        let asset = AVURLAsset(url: media)
        guard let item = try await asset.load(.creationDate), let date = try await item.load(.dateValue), abs(date.timeIntervalSince(plan.creationDate)) <= 0.000002 else { throw CutError.invalid("AVFoundationで読み戻した撮影日時が一致しません。") }
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1 else { throw CutError.invalid("出力の映像トラック数が一致しません。") }
        let range = try await videos[0].load(.timeRange)
        guard range.start == .zero, abs(range.duration.seconds - (plan.planned.end.seconds - plan.planned.start.seconds)) < 0.000002 else { throw CutError.invalid("出力の表示範囲が計画と一致しません。start=\(range.start.seconds), duration=\(range.duration.seconds), expected=\(plan.planned.end.seconds - plan.planned.start.seconds)") }
        try fm.setAttributes([.creationDate: plan.creationDate, .modificationDate: plan.creationDate], ofItemAtPath: media.path)
        let attributes = try fm.attributesOfItem(atPath: media.path)
        guard let created = attributes[.creationDate] as? Date, let modified = attributes[.modificationDate] as? Date,
              abs(created.timeIntervalSince(plan.creationDate)) < 0.001, abs(modified.timeIntervalSince(plan.creationDate)) < 0.001 else { throw CutError.invalid("ファイルシステムの日時が一致しません。") }
        try Task.checkCancellation()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: plan.displayTimeZone); formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: plan.creationDate)
        var destination: URL?, name = ""
        for index in 0...99999 {
            name = index == 0 ? "vroma_\(stamp).mp4" : String(format: "vroma_%02d_", index) + stamp + ".mp4"
            let candidate = root.appendingPathComponent(name)
            if renamex_np(media.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { destination = candidate; break }
            guard errno == EEXIST else { throw CutError.invalid("書き出しファイルの確定に失敗しました。") }
        }
        guard let destination else { throw CutError.invalid("同名ファイルが多すぎます。") }
        func string<T>(_ tuple: T) -> String { var value = tuple; return withUnsafePointer(to: &value) { $0.withMemoryRebound(to: CChar.self, capacity: 65) { String(cString: $0) } } }
        var record = ExportRecord(id: UUID(), clipID: plan.clip.id, recordingID: plan.recording.id,
            sourceSHA256: sources[0].sha256, sourceMetadata: sources[0].metadata,
            requested: plan.clip.requested, planned: plan.planned, actual: plan.planned, creationDate: plan.creationDate,
            engineVersion: "libav " + String(cString: vc_version()) + "; Vroma Cut plan 1", videoPackets: result.video_packets, audioPackets: result.audio_packets,
            decodedFrames: result.decoded_frames, videoSHA256: string(result.video_sha256), audioSHA256: string(result.audio_sha256),
            videoTimingSHA256: string(result.video_timing_sha256), audioTimingSHA256: string(result.audio_timing_sha256),
            timecodeHandling: result.timecode_regenerated == 1 ? "Regenerated counter; not byte-identical to source tmcd" : "No source timecode track", outputFile: name)
        record.sources = sources
        record.audioBoundaryAdjustments = Int(result.audio_boundary_adjustments)
        record.verification = fullDecodeValidation ? "packet-hash-and-full-decode" : "packet-hash-and-timing"
        record.sourceBytesRead = result.source_bytes_read
        manifest.clips.append(record)
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(manifest).write(to: manifestURL, options: .atomic) }
        catch { try? fm.removeItem(at: destination); throw error }
        return record
    }
    private static func errorText(_ bytes: [CChar]) -> String { String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

// Lifetime owned by each operation; cancellation is the only concurrent mutation,
// implemented with a C11 atomic flag and libav's interrupt callback.
private final class MediaControl: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws { guard let p = vc_control_create() else { throw CutError.invalid("処理制御領域を確保できません。") }; pointer = p }
    func cancel() { vc_control_cancel(pointer) }
    deinit { vc_control_free(pointer) }
}
