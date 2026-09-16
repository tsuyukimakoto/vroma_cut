import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import VromaCutCore

@MainActor @Observable final class Playback {
    let player = AVPlayer()
    var position: Double = 0
    var isPlaying = false
    func toggle() {
        if player.rate != 0 || isPlaying { player.pause(); isPlaying = false }
        else {
            if let item = player.currentItem, item.duration.seconds.isFinite, position >= item.duration.seconds { seek(0) }
            player.play(); isPlaying = true
        }
    }
    private var observer: Any?
    private var loaded: Recording?
    private var loading: Task<Void, Never>?
    var loadError: String?
    func load(_ recording: Recording) throws {
        guard loaded != recording else { return }
        for part in recording.sourceSegments { _ = try part.file.resolve() }
        loading?.cancel(); player.pause(); player.replaceCurrentItem(with: nil)
        loaded = recording; position = 0; isPlaying = false; loadError = nil
        loading = Task { @MainActor in
            do {
                let asset = try await recording.playbackAsset()
                try Task.checkCancellation()
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset)); seek(position)
                if isPlaying { player.play() }
            } catch is CancellationError { } catch { loadError = error.localizedDescription }
        }
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { if time.seconds.isFinite && self?.player.currentItem != nil { self?.position = time.seconds; self?.isPlaying = (self?.player.rate ?? 0) != 0 } }
            }
        }
    }
    func seek(_ seconds: Double) { position = seconds; player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1_000_000), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stop() { loading?.cancel(); player.pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil } }
}

private enum EditTarget: String, CaseIterable { case playhead = "再生位置", start = "開始点", end = "終了点" }

struct EditorView: View {
    @Binding var project: Project
    private let layout: WindowLayoutState?
    private let importLocations = ImportLocations()
    @Environment(\.undoManager) private var undoManager
    @State private var playback = Playback()
    @State private var recordingID: UUID?
    @State private var selectionAnchor: UUID?
    @State private var clipIDs: Set<UUID> = []
    @State private var target: EditTarget = .playhead
    @State private var error: String?
    @State private var operation = OperationState()
    @State private var exportQueue = ExportQueue()
    @State private var pendingSnapshot: RecordingExportSnapshot?
    @State private var destinationPath = ""
    @State private var importing = false
    @State private var archiveCache = ArchiveCache()
    private var busy: Bool { importing || operation.isRunning }
    @State private var activity = ""
    @State private var showingClock = false
    @State private var showingEditingHelp = false
    @State private var markID: String?
    @State private var zoom = 1.0
    @State private var timelineFocus = UUID()
    @State private var exportPlans: [ExportPlan] = []
    @State private var showingExport = false
    @State private var undoProxy: UndoProxy?
    @FocusState private var editingText: Bool
    init(project: Binding<Project>, exportQueue: ExportQueue = ExportQueue(), layout: WindowLayoutState? = nil) {
        self.layout = layout; self._project = project; self._exportQueue = State(initialValue: exportQueue)
    }
    private var recording: Recording? { project.recordings.first { $0.id == recordingID } }
    private var clip: Clip? { clipIDs.count == 1 ? project.clips.first { clipIDs.contains($0.id) } : nil }
    private var clips: [Clip] { project.clips.filter { $0.recordingID == recordingID } }

    private var workspace: some View {
        NavigationSplitView {
            List(selection: $recordingID) {
                Section("録画 · \(project.recordings.count)") {
                    ForEach(project.recordings) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(r.name).font(.headline).lineLimit(2)
                            Text("\(r.duration.seconds.formatted(.number.precision(.fractionLength(1))))秒").font(.caption).foregroundStyle(.secondary)
                            if r.cameraStart == nil { Label("時刻未確定", systemImage: "clock.badge.questionmark").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 4).tag(r.id)
                    }
                }
                Section("読み込んだGPX") {
                    ForEach(project.tracks, id: \.path) { track in Text(URL(fileURLWithPath: track.path).lastPathComponent).font(.caption) }
                    Text("マーク \(project.marks.count)件").font(.caption)
                    Button("マークCSVを追加…") { chooseMarks() }.disabled(busy)
                }
                Section {
                    Label("対応する録画なし: \(project.unmatchedMarks.count)件", systemImage: "mappin.and.ellipse").font(.caption)
                    Text("同じ日時の連番ファイルは1本の録画として再生・編集・書き出しできます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let recording {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recording.name).font(.title3.weight(.semibold))
                            Text(recording.cameraStart.map { dateString($0.addingTimeInterval(recording.correction.seconds)) } ?? "内部日時を取得できません")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding()
                    EditorPanes(layout: layout) {
                        VStack(spacing: 0) {
                            PlayerView(player: playback.player).frame(maxWidth: .infinity, maxHeight: .infinity)
                            ZStack {
                                Text("再生 \(timeLabel(playback.position))")
                                    .font(.caption).monospacedDigit()
                                    .accessibilityLabel("現在の再生位置")
                                    .accessibilityValue(timeLabel(playback.position))
                                HStack {
                                    Button { playback.toggle() } label: { Label(playback.isPlaying ? "一時停止" : "再生", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                                    Spacer()
                                    Button { showingEditingHelp.toggle() } label: {
                                        Image(systemName: "questionmark.circle")
                                    }
                                    .accessibilityLabel("編集操作のヘルプ")
                                    .help("編集操作のヘルプ")
                                    .popover(isPresented: $showingEditingHelp) { editingHelp }
                                }
                            }.padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    } editing: {
                        VStack(spacing: 0) {
                            controls(recording)
                            timeline(recording)
                            Spacer(minLength: 0)
                        }
                    }
                    HStack {
                        Text(activity.isEmpty ? "候補 \(clips.count)件" : activity)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(activity)
                        Spacer()
                        zoomControls
                    }.padding(12)
                }
            } else {
                ContentUnavailableView {
                    Label("残したい場面から、編集を始める", systemImage: "film.stack")
                } description: {
                    Text("動画とVromaのマークを読み込むと、マークの10秒前から60秒後を候補にします。動画だけでも範囲を追加できます。")
                } actions: {
                    Button("動画フォルダを選ぶ…") { chooseVideos() }.buttonStyle(.borderedProminent)
                    Button("GPXを選ぶ…") { chooseGPX() }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if operation.isRunning { OperationBanner(operation: operation); Divider() }
            if !exportQueue.jobs.isEmpty { ExportQueueView(queue: exportQueue); Divider() }
            workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PlaybackShortcut(enabled: recording != nil && !showingClock && !showingExport, toggle: { playback.toggle() }).frame(width: 0, height: 0))
        .onChange(of: operation.isRunning) { _, running in if !running && (operation.isCancelling || operation.error != nil || operation.message.hasPrefix("キャンセル")) { activity = operation.message } }
        .onChange(of: playback.loadError) { _, value in if let value { error = value } }
        .onChange(of: operation.error) { _, value in if let value { error = value } }
        .toolbar {
            ToolbarItemGroup {
                Button { chooseVideos() } label: { Label("動画フォルダを選ぶ", systemImage: "folder.badge.plus") }.disabled(busy)
                Button { chooseGPX() } label: { Label("GPXを選ぶ", systemImage: "map") }.disabled(busy)
                Button("動画を切り出す") { prepareExport() }
                    .disabled(busy || clips.isEmpty)
            }
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("閉じる", role: .cancel) {} } message: { Text(error ?? "") }
        .sheet(isPresented: $showingExport) {
            VStack(alignment: .leading, spacing: 16) {
                Text(pendingSnapshot?.recording.name ?? "この動画を書き出す").font(.title2.bold())
                Text("この動画の \(exportPlans.count)件を書き出します。実行後の編集は、今回の書き出しに影響しません。")
                Text("映像と音声は再圧縮せずコピーします。追加データは原本ごとに別保存し、タイムコードは再生成します。")
                List(Array(exportPlans.enumerated()), id: \.offset) { _, plan in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.recording.name).font(.headline)
                        Text(String(format: "希望 %.3f〜%.3f秒 → 出力 %.3f〜%.3f秒", plan.clip.requested.start.seconds, plan.clip.requested.end.seconds, plan.planned.start.seconds, plan.planned.end.seconds)).monospacedDigit()
                        Text(String(format: "前に %.3f秒、後ろに %.3f秒追加", plan.clip.requested.start.seconds - plan.planned.start.seconds, plan.planned.end.seconds - plan.clip.requested.end.seconds)).foregroundStyle(.secondary)
                        Text("撮影日時: " + dateString(plan.creationDate))
                    }.padding(.vertical, 5)
                }
                Text("退避データは原本の復元やメーカーソフトでの再利用を保証しません。原本は自動削除しません。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("保存先").font(.caption).foregroundStyle(.secondary)
                        Text(destinationPath.isEmpty ? "未選択" : destinationPath).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    if destinationPath.isEmpty {
                        Button("選ぶ…") { chooseExportDestination() }
                            .buttonStyle(.borderedProminent).tint(.blue)
                    } else {
                        Button("変更…") { chooseExportDestination() }
                            .buttonStyle(.bordered)
                    }
                }
                Text("同名の出力があれば連番を付けます。同じフォルダへ続けて書き出せます。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("戻る") { showingExport = false }
                    Button(exportQueue.hasWork ? "書き出し待ちに追加" : "この動画を書き出す") { startExport() }
                        .buttonStyle(.borderedProminent).tint(.blue)
                        .disabled(destinationPath.isEmpty)
                }
            }.padding(24).frame(width: 700, height: 540)
        }
        .sheet(isPresented: $showingClock) {
            if let recording {
                ClockShiftView(recording: recording, timeZone: project.displayTimeZone, apply: { shift in
                    change("時刻合わせ") { try $0.applyClockShift(shift, referenceRecordingID: recording.id) }
                    selectInitial(recording.id)
                }, shift: (recording.cameraStart.map { ClockShift.describing(recording.correction, from: $0, timeZone: project.displayTimeZone) } ?? ClockShift()))
            }
        }
        .onChange(of: recordingID) { _, _ in selectInitial(recordingID) }
        .onAppear {
            let binding = $project
            exportQueue.onRecord = { record in binding.wrappedValue.exports.append(record) }
            selectInitial(recordingID)
        }
        .onDisappear { playback.stop(); operation.cancel(); exportQueue.cancelAll() }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: project.displayTimeZone); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS zzz"; return f.string(from: date)
    }
    private func timeline(_ recording: Recording) -> some View {
        let boundaries = recording.sourceSegments.dropLast().reduce(into: [Double]()) { $0.append(($0.last ?? 0) + $1.duration.seconds) }
        return ReviewTimeline(duration: recording.duration.seconds, position: playback.position,
                       marks: project.timelineMarks(recordingID: recording.id), clips: clips,
                       selected: clipIDs, focus: timelineFocus, zoom: $zoom, seek: { playback.seek($0) },
                       selectMark: { selectMark($0) }, selectClip: { selectTimelineClip($0) }, edit: { c, start, end in
            change("範囲を変更") { try $0.editRange(clipID: c.id, range: MediaRange(start: MediaTime(seconds: start), end: MediaTime(seconds: end))) }
        }, deleteSelection: { deleteClips() }, boundaries: boundaries)
    }
    private func selectInitial(_ id: UUID? = nil) {
        guard let selection = project.initialReview(recordingID: id),
              let r = project.recordings.first(where: { $0.id == selection.recordingID }) else { return }
        recordingID = r.id; markID = selection.markID; selectionAnchor = selection.clipID; clipIDs = Set(selection.clipID.map { [$0] } ?? [])
        do { try playback.load(r); playback.seek(selection.position.seconds); timelineFocus = UUID() }
        catch { self.error = error.localizedDescription }
    }
    private func selectTimelineClip(_ c: Clip) {
        var selection = TimelineSelection(ids: clipIDs, anchor: selectionAnchor)
        let flags = NSEvent.modifierFlags
        let ordered = clips.sorted { $0.requested.start == $1.requested.start ? $0.id.uuidString < $1.id.uuidString : $0.requested.start < $1.requested.start }.map(\.id)
        selection.click(c.id, ordered: ordered, toggle: flags.contains(.command), extend: flags.contains(.shift))
        clipIDs = selection.ids; selectionAnchor = selection.anchor
        if selection.ids.count == 1, selection.ids.contains(c.id) { markID = c.markIDs.first ?? c.videoMarkIDs?.first; playback.seek(c.requested.start.seconds) }
    }
    private func deleteClips() {
        guard !clipIDs.isEmpty else { return }
        change("候補を削除") { $0.clips.removeAll { clipIDs.contains($0.id) } }
        clipIDs = []; selectionAnchor = nil
    }
    private func mergeClips() {
        guard clipIDs.count > 1 else { return }
        var mergedID: UUID?
        change("候補を結合") { p in
            let previous = Set(p.clips.map(\.id))
            try p.merge(clipIDs)
            mergedID = p.clips.first { !previous.contains($0.id) }?.id
        }
        if let mergedID { clipIDs = [mergedID]; selectionAnchor = mergedID }
    }
    private func selectClip(_ c: Clip) {
        clipIDs = [c.id]; selectionAnchor = c.id; markID = c.markIDs.first ?? c.videoMarkIDs?.first
        playback.seek(c.requested.start.seconds); timelineFocus = UUID()
    }
    private func selectMark(_ mark: TimelineMark) {
        markID = mark.id
        clipIDs = Set(project.clip(for: mark.id, recordingID: recordingID!).map { [$0.id] } ?? [])
        selectionAnchor = clipIDs.first; playback.seek(mark.position.seconds); timelineFocus = UUID()
    }
    private func navigateMark(_ direction: Int) {
        guard let recording, let mark = project.adjacentMark(recordingID: recording.id, currentID: markID, position: (try? MediaTime(seconds: playback.position)) ?? .zero, direction: direction) else { return }
        selectMark(mark)
    }
    private func controls(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("操作対象", selection: $target) { ForEach(EditTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 250)
                    .onChange(of: target) { _, t in if let clip, t != .playhead { playback.seek(t == .start ? clip.requested.start.seconds : clip.requested.end.seconds) } }
                ForEach([-60, -10, -1, 1, 10, 60], id: \.self) { seconds in Button(seconds > 0 ? "+\(seconds)" : "\(seconds)") { move(seconds: Double(seconds)) }.controlSize(.small) }
                Spacer()
                Button("この位置にマークを追加") {
                    var added: String?
                    change("マークを追加") { added = try $0.addVideoMark(recordingID: recording.id, at: MediaTime(seconds: playback.position)) }
                    if let mark = project.timelineMarks(recordingID: recording.id).first(where: { $0.id == added }) { selectMark(mark) }
                }.buttonStyle(.borderedProminent)
            }
            .focusable().onKeyPress(.leftArrow) { guard !editingText else { return .ignored }; move(seconds: -1); return .handled }
            .onKeyPress(.rightArrow) { guard !editingText else { return .ignored }; move(seconds: 1); return .handled }
             HStack {
                Button("前のマーク") { navigateMark(-1) }
                let marks = project.timelineMarks(recordingID: recording.id)
                Text("\(marks.firstIndex(where: { $0.id == markID }).map { String($0 + 1) } ?? "–") / \(marks.count)").monospacedDigit()
                Button("次のマーク") { navigateMark(1) }
                Spacer()
                Button("動画とGPXの時刻を合わせる…") { showingClock = true }.disabled(recording.cameraStart == nil)
            }
            HStack(spacing: 10) {
                Text("\(clipIDs.count)件選択").font(.caption).monospacedDigit()
                Button("1つにまとめる") { mergeClips() }.disabled(clipIDs.count < 2)
                Button("削除") { deleteClips() }.disabled(clipIDs.isEmpty)
                Spacer(minLength: 0)
                if let clip {
                    Text("開始 \(timeLabel(clip.requested.start.seconds))　終了 \(timeLabel(clip.requested.end.seconds))")
                        .font(.caption).monospacedDigit()
                }
                Button("現在位置を開始に") { setBoundary(start: true) }.disabled(clip == nil)
                Button("現在位置を終了に") { setBoundary(start: false) }.disabled(clip == nil)
            }
            let unreviewed = clips.filter { clipIDs.contains($0.id) && $0.needsReview }
            if !unreviewed.isEmpty {
                HStack {
                    Label("時刻合わせ後に未確認: \(unreviewed.count)件", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("確認済みにする") {
                        change("候補を確認") { p in
                            for i in p.clips.indices where clipIDs.contains(p.clips[i].id) && p.clips[i].needsReview {
                                p.clips[i].needsReview = false; p.clips[i].edited = true
                            }
                        }
                    }
                }
            }
        }.controlSize(.small).padding(.horizontal).padding(.vertical, 8)
    }
    private var editingHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("編集操作のヘルプ").font(.headline)
            Text("Space: 再生／一時停止")
            Text("タイムラインの空いている場所や時刻目盛りをクリック: 再生位置を移動")
            Text("帯をクリック: 範囲を選択\n⌘クリック: 選択を追加・解除\nShiftクリック: 連続する範囲を選択")
            Text("Delete: 選択した範囲を削除\n選択した帯の両端をドラッグ: 開始・終了を調整")
            Text("動画と編集パネルの境界をドラッグ: 操作エリアの高さを調整\nウィンドウのサイズ変更: 動画エリアを伸縮")
            Text("配置を戻す: ウィンドウメニューの「初期サイズ・表示位置をリセット」")
        }.font(.callout).padding(20).frame(width: 360, alignment: .leading)
    }
    private var zoomControls: some View {
        HStack(spacing: 8) {
            Text("縮小").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...32).frame(width: 140)
                .accessibilityLabel("タイムラインのズーム")
            Text("拡大").foregroundStyle(.secondary)
            Button("全体") { zoom = 1 }
        }.font(.caption).controlSize(.small).fixedSize()
    }
    private func setBoundary(start: Bool) {
        guard let clip else { return }
        change("範囲を変更") { try $0.editRange(clipID: clip.id, range: MediaRange(start: start ? MediaTime(seconds: playback.position) : clip.requested.start, end: start ? clip.requested.end : MediaTime(seconds: playback.position))) }
    }
    private func move(seconds: Double) {
        guard let recording else { return }
        if target == .playhead { playback.seek(min(recording.duration.seconds, max(0, playback.position + seconds))); return }
        guard let clip else { return }
        do {
            let start = target == .start ? try clip.requested.start.adding(MediaTime(seconds: seconds)) : clip.requested.start
            let end = target == .end ? try clip.requested.end.adding(MediaTime(seconds: seconds)) : clip.requested.end
            let range = try MediaRange(start: max(.zero, start), end: min(recording.duration, end))
            change("範囲を変更") { try $0.editRange(clipID: clip.id, range: range) }
            playback.seek(target == .start ? range.start.seconds : range.end.seconds)
        } catch { self.error = error.localizedDescription }
    }
    private func replace(_ project: Project, name: String) {
        let old = self.project, binding = $project
        self.project = project
        if undoProxy == nil { undoProxy = UndoProxy(binding: binding, manager: undoManager) }
        if let undoProxy { undoManager?.registerUndo(withTarget: undoProxy) { proxy in proxy.restore(old, name: name) } }
        undoManager?.setActionName(name)
    }
    private func change(_ name: String, operation: (inout Project) throws -> Void) {
        do { var p = project; try operation(&p); try p.validate(); replace(p, name: name) }
        catch { self.error = error.localizedDescription }
    }
    private func chooseGPX() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.prompt = "GPXを読み込む"
        panel.directoryURL = importLocations.initialDirectory(for: .gpx)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLocations.remember(url.deletingLastPathComponent(), for: .gpx)
        do {
            let imported = try TrackImport.load(gpx: url)
            change("GPXとマークを読み込み") { try $0.importTrack(imported) }
            selectInitial()
            activity = "GPXと\(imported.marks.count)件のマークを読み込みました" + (imported.markFile == nil ? "。同名の .marks.csv が見つかりません。左のボタンから追加できます。" : "")
        } catch { self.error = error.localizedDescription }
    }
    private func chooseMarks() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let marks = try MarkCSV.parse(String(contentsOf: url, encoding: .utf8))
            let ref = try FileReference(url: url)
            change("マークを読み込み") { p in
                if !p.markFiles.contains(where: { $0.path == ref.path }) { p.markFiles.append(ref) }
                try p.importMarks(marks)
            }
            selectInitial()
        } catch { self.error = error.localizedDescription }
    }
    private func chooseVideos() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "動画フォルダを選ぶ"
        panel.directoryURL = importLocations.initialDirectory(for: .videos)
        guard panel.runModal() == .OK, let root = panel.url else { return }
        importLocations.remember(root, for: .videos)
        importing = true; activity = "動画を読み込んでいます…"
        Task { @MainActor in
            defer { importing = false }
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                var incoming: [Recording] = []
                for url in urls where !project.recordings.contains(where: { $0.sourceSegments.contains { $0.file.path == url.path } }) { incoming.append(try await MediaImport.recording(url: url)) }
                change("動画を読み込み") { try $0.addRecordings(incoming) }
                selectInitial()
                activity = "\(incoming.count)本の動画を読み込みました。GPXのマークと対応する候補を選択しています。"
            } catch { self.error = error.localizedDescription; activity = "動画の読込を中止しました" }
        }
    }
    private func prepareExport() {
        guard let recordingID else { return }
        do {
            let snapshot = try RecordingExportSnapshot(project: project, recordingID: recordingID)
            let state = operation
            state.start("この動画の書き出し範囲を確認しています…") {
                let worker = Task.detached { try await snapshot.plans { progress in Task { @MainActor in state.update(progress) } } }
                let plans = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                pendingSnapshot = snapshot; exportPlans = plans
                destinationPath = project.exportDirectory(recordingID: snapshot.recording.id) ?? ""
                showingExport = true
            }
        } catch { self.error = error.localizedDescription }
    }

    private func chooseExportDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "保存先にする"
        if !destinationPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: destinationPath) }
        if panel.runModal() == .OK, let url = panel.url { destinationPath = url.path }
    }

    private func startExport() {
        guard let snapshot = pendingSnapshot, !exportPlans.isEmpty else { return }
        guard !destinationPath.isEmpty else { return }
        let destination = URL(fileURLWithPath: destinationPath), plans = exportPlans, cache = archiveCache
        change("書き出し先を設定") { $0.setExportDirectory(destination.path, recordingID: snapshot.recording.id) }
        pendingSnapshot = nil; exportPlans = []; showingExport = false
        exportQueue.enqueue(snapshot: snapshot, destination: destination) { progress, record in
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                let result = try await MediaEngine.export(plan, to: destination, archiveCache: cache) { update in
                    progress(ExportProgress("\(index + 1)/\(plans.count)件: " + update.phase, fraction: update.fraction))
                }
                await record(result)
            }
        }
        activity = "\(snapshot.recording.name) の\(plans.count)件を書き出しに追加しました。次の動画を編集できます。"
    }

}
private extension String { func nonempty(or fallback: String) -> String { isEmpty ? fallback : self } }

@MainActor final class UndoProxy: NSObject {
    let binding: Binding<Project>
    weak var manager: UndoManager?
    init(binding: Binding<Project>, manager: UndoManager?) { self.binding = binding; self.manager = manager }
    func restore(_ project: Project, name: String) {
        let old = binding.wrappedValue
        var restored = project
        restored.exports = old.exports
        binding.wrappedValue = restored
        manager?.registerUndo(withTarget: self) { $0.restore(old, name: name) }
        manager?.setActionName(name)
    }
}
