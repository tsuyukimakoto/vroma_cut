import SwiftUI
import AppKit

struct ExportQueueView: View {
    @Bindable var queue: ExportQueue
    @State private var showingJobs = false
    var body: some View {
        HStack(spacing: 16) {
            if let active = queue.active {
                VStack(alignment: .leading, spacing: 5) {
                    Text("書き出し: " + active.snapshot.recording.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(active.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                ProgressMeter(fraction: active.fraction)
                Button("キャンセル") { queue.cancel(active.id) }.disabled(active.status == .cancelling)
            } else {
                Image(systemName: queue.jobs.contains { $0.status == .failed } ? "exclamationmark.triangle" : "checkmark.circle")
                Text(queue.jobs.contains { $0.status == .failed } ? "失敗した書き出しがあります" : "書き出しの処理が終了しました").font(.callout)
                Spacer()
            }
            Button(queue.pendingCount > 0 ? "待機 \(queue.pendingCount)件 · 一覧" : "書き出し一覧") { showingJobs = true }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor))
            .popover(isPresented: $showingJobs) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("動画ごとの書き出し").font(.headline); Spacer(); Button("完了分を閉じる") { queue.clearFinished() } }
                    Text("同じ保存先への書き出しも順番に処理します。待機中も編集できます。").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(queue.jobs) { job in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(job.snapshot.recording.name).font(.headline).lineLimit(1)
                                        Spacer(); Text(job.status.rawValue)
                                    }
                                    Text("\(job.completedCount)/\(job.snapshot.clips.count)件完了 · \(job.destination.path)").font(.caption).textSelection(.enabled)
                                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                                    HStack {
                                        if [.queued, .running].contains(job.status) { Button("キャンセル") { queue.cancel(job.id) } }
                                        Button("保存先を開く") { NSWorkspace.shared.open(job.destination) }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }.padding(18).frame(width: 560, height: 350)
            }
    }
}
