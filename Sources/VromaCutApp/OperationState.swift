import Foundation
import Observation
import VromaCutCore

@MainActor @Observable final class OperationState {
    private(set) var isRunning = false
    private(set) var isCancelling = false
    var message = ""
    var fraction: Double?
    private var task: Task<Void, Never>?
    var error: String?

    func start(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true; isCancelling = false; self.message = message; fraction = nil; error = nil
        task = Task { @MainActor in
            defer { isRunning = false; isCancelling = false; fraction = nil; task = nil }
            do { try Task.checkCancellation(); try await work() }
            catch is CancellationError { self.message = "キャンセルしました。完了済みの書き出しは保存されています。" }
            catch { self.error = error.localizedDescription; self.message = "処理を完了できませんでした" }
        }
    }
    func update(_ progress: ExportProgress) {
        guard isRunning, !isCancelling else { return }
        message = progress.phase; fraction = progress.fraction
    }
    func cancel() {
        guard isRunning else { return }
        isCancelling = true; message = "キャンセルしています…"; task?.cancel()
    }
}
