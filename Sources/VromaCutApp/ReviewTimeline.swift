import SwiftUI
import AppKit
import VromaCutCore

func timeLabel(_ seconds: Double) -> String {
    let ms = Int((max(0, seconds) * 1000).rounded())
    return String(format: "%02d:%02d:%02d.%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
}

struct ReviewTimeline: View {
    let duration: Double
    let position: Double
    let marks: [TimelineMark]
    let clips: [Clip]
    let selected: Set<UUID>
    let focus: UUID
    @Binding var zoom: Double
    let seek: (Double) -> Void
    let selectMark: (TimelineMark) -> Void
    let selectClip: (Clip) -> Void
    let edit: (Clip, Double, Double) -> Void
    var deleteSelection: () -> Void = {}
    @FocusState private var focused: Bool
    var boundaries: [Double] = []
    @State private var preview: Double?

    var body: some View {
        let layout = TimelineLayout(clips: clips)
        let height = CGFloat(max(118, 75 + layout.rowCount * 34))
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width * zoom)
                let scale = width / max(0.001, duration)
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.black.opacity(0.10))
                                .onTapGesture { location in seek(min(duration, max(0, location.x / scale))) }
                            Rectangle().fill(.secondary.opacity(0.08))
                                .frame(height: 32).allowsHitTesting(false)
                            Rectangle().fill(.secondary.opacity(0.5))
                                .frame(height: 1).offset(y: 32).allowsHitTesting(false)
                            let tickCount = max(2, Int(width / 115))
                            ForEach(0..<tickCount, id: \.self) { i in
                                let t = duration * Double(i) / Double(tickCount)
                                Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: height).offset(x: t * scale).allowsHitTesting(false)
                                Text(timeLabel(t)).font(.system(size: 10).monospacedDigit())
                                    .offset(x: min(width - 82, max(0, t * scale + 3))).allowsHitTesting(false)
                            }
                            ForEach(Array(boundaries.enumerated()), id: \.offset) { index, boundary in
                                Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: Int(height))) }
                                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .offset(x: boundary * scale).allowsHitTesting(false)
                                Text("\(index + 2)ファイル目").font(.system(size: 9)).foregroundStyle(.secondary)
                                    .offset(x: boundary * scale + 3, y: 16).allowsHitTesting(false)
                            }
                            ForEach(clips) { clip in
                                let active = selected.contains(clip.id)
                                let y = CGFloat(72 + (layout.rows[clip.id] ?? 0) * 34)
                                band(clip, active: active, scale: scale).offset(x: clip.requested.start.seconds * scale, y: y)
                            }
                            if selected.count == 1, let clip = clips.first(where: { selected.contains($0.id) }) {
                                let y = CGFloat(72 + (layout.rows[clip.id] ?? 0) * 34)
                                handle(clip, start: true, scale: scale).offset(x: clip.requested.start.seconds * scale - 6, y: y - 3)
                                handle(clip, start: false, scale: scale).offset(x: clip.requested.end.seconds * scale - 6, y: y - 3)
                            }
                            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                                Button { selectMark(mark) } label: {
                                    VStack(spacing: 0) { Text("\(index + 1)").font(.system(size: 10).bold()); Image(systemName: "mappin").font(.system(size: 17)) }
                                        .foregroundStyle(.orange)
                                }.buttonStyle(.plain).help(mark.comment.isEmpty ? "マーク \(index + 1)" : mark.comment)
                                    .offset(x: mark.position.seconds * scale - 6, y: 35)
                            }
                            Rectangle().fill(.primary).frame(width: 2)
                                .offset(x: min(width - 2, max(0, (preview ?? position) * scale)))
                                .allowsHitTesting(false)
                            HStack(spacing: 0) { Color.clear.frame(width: max(0, position * scale), height: 1); Color.clear.frame(width: 1, height: 1).id("playhead") }.allowsHitTesting(false)
                        }.frame(width: width, height: height)
                    }
                    .onChange(of: focus) { _, _ in proxy.scrollTo("playhead", anchor: .center) }
                    .onChange(of: zoom) { _, _ in proxy.scrollTo("playhead", anchor: .center) }
                }
            }.frame(minHeight: 80, idealHeight: min(210, height + 17), maxHeight: min(210, height + 17))
        }.padding(.horizontal).padding(.vertical, 8)
            .focusable().focused($focused).focusEffectDisabled()
            .onDeleteCommand { deleteSelection() }
    }

    private func band(_ clip: Clip, active: Bool, scale: Double) -> some View {
        let color = Color.teal.opacity(active ? 0.8 : 0.35)
        let border = clip.needsReview ? Color.orange : active ? Color.teal : Color.gray.opacity(0.4)
        let width: Double = max(3, (clip.requested.end.seconds - clip.requested.start.seconds) * scale)
        return RoundedRectangle(cornerRadius: 4).fill(color)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: active ? 2 : 1))
            .frame(width: width, height: 26).onTapGesture { focused = true; selectClip(clip) }
            .help((clip.needsReview ? "要確認 · " : "") + timeLabel(clip.requested.start.seconds) + " → " + timeLabel(clip.requested.end.seconds))
    }

    private func handle(_ clip: Clip, start: Bool, scale: Double) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.teal)
            .overlay(Text(start ? "始" : "終").font(.system(size: 9)).foregroundStyle(.white))
            .frame(width: 12, height: 32)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let t = bounded(clip, start: start, translation: value.translation.width / scale)
                    preview = t; seek(t)
                }
                .onEnded { value in
                    let t = bounded(clip, start: start, translation: value.translation.width / scale)
                    edit(clip, start ? t : clip.requested.start.seconds, start ? clip.requested.end.seconds : t)
                    preview = nil
                })
    }
    private func bounded(_ clip: Clip, start: Bool, translation: Double) -> Double {
        start ? min(clip.requested.end.seconds - 0.001, max(0, clip.requested.start.seconds + translation)) : min(duration, max(clip.requested.start.seconds + 0.001, clip.requested.end.seconds + translation))
    }
}
