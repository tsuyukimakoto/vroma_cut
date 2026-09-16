import Foundation
import Observation
import VromaCutCore

@MainActor @Observable final class ExportQueue {
    enum Status: String { case queued = "待機中", running = "書き出し中", cancelling = "キャンセル中", completed = "完了", cancelled = "キャンセル済み", failed = "失敗" }
    struct Job: Identifiable {
        let id: UUID
        let snapshot: RecordingExportSnapshot
        let destination: URL
        var status: Status = .queued
        var message = "順番を待っています"
        var fraction: Double?
        var completedCount = 0
        var error: String?
    }
    typealias Progress = @Sendable (ExportProgress) -> Void
    typealias Record = @MainActor @Sendable (ExportRecord) -> Void
    typealias Work = @Sendable (@escaping Progress, @escaping Record) async throws -> Void
    private(set) var jobs: [Job] = []
    private(set) var activeID: UUID?
    private var workers: [UUID: Work] = [:]
    private var task: Task<Void, Never>?
    var onRecord: Record?
    var active: Job? { jobs.first { $0.id == activeID } }
    var pendingCount: Int { jobs.filter { $0.status == .queued }.count }
    var hasWork: Bool { activeID != nil || pendingCount > 0 }
    func hasPending(recordingID: UUID) -> Bool {
        jobs.contains { $0.snapshot.recording.id == recordingID && [.queued, .running, .cancelling].contains($0.status) }
    }
    @discardableResult
    func enqueue(snapshot: RecordingExportSnapshot, destination: URL, work: @escaping Work) -> UUID {
        let id = UUID()
        jobs.append(Job(id: id, snapshot: snapshot, destination: destination))
        workers[id] = work; runNext()
        return id
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].status == .queued {
            jobs[index].status = .cancelled; jobs[index].message = "キャンセルしました"; workers[id] = nil
        } else if jobs[index].status == .running {
            jobs[index].status = .cancelling; jobs[index].message = "キャンセルしています…"; task?.cancel()
        }
    }
    func cancelAll() {
        for job in jobs where job.status == .queued { cancel(job.id) }
        if let activeID { cancel(activeID) }
    }
    func clearFinished() { jobs.removeAll { [.completed, .cancelled, .failed].contains($0.status) } }
    private func update(_ id: UUID, _ progress: ExportProgress) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .running else { return }
        jobs[i].message = progress.phase; jobs[i].fraction = progress.fraction
    }
    private func record(_ id: UUID, _ record: ExportRecord) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].completedCount += 1
        onRecord?(record)
    }
    private func runNext() {
        guard activeID == nil, let i = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let id = jobs[i].id
        guard let work = workers.removeValue(forKey: id) else { return }
        jobs[i].status = .running; jobs[i].message = "書き出しを始めます…"; activeID = id
        task = Task { @MainActor in
            let worker = Task.detached {
                try Task.checkCancellation()
                try await work({ progress in Task { @MainActor in self.update(id, progress) } }, { record in self.record(id, record) })
            }
            var status = Status.completed, message = "書き出しを完了しました", failure: String?
            do { try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
            catch is CancellationError { status = .cancelled; message = "キャンセルしました。完了済みの出力は残っています。" }
            catch { status = .failed; message = "書き出しに失敗しました"; failure = error.localizedDescription }
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].status = status; jobs[index].message = message; jobs[index].error = failure
                jobs[index].fraction = status == .completed ? 1 : nil
            }
            activeID = nil; task = nil; runNext()
        }
    }
}
