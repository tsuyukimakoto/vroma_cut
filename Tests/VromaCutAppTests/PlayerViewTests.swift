import VromaCutCore
import AppKit
import SwiftUI
import AVKit
import Testing
@testable import VromaCutApp

@Test @MainActor func playerViewCanBeInstantiatedAndLaidOut() throws {
    _ = NSApplication.shared
    let player = AVPlayer()
    let hosting = NSHostingView(rootView: PlayerView(player: player))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    func players(in view: NSView) -> [AVPlayerView] {
        (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { players(in: $0) }
    }
    let view = try #require(players(in: hosting).first)
    #expect(view.player === player)
    #expect(view.videoGravity == .resizeAspect)
    window.close()
}

@Test @MainActor func editingUndoAndRedoRestoreProject() {
    let manager = UndoManager()
    let box = ProjectBox()
    let original = box.value
    box.value.displayTimeZone = "UTC"
    let edited = box.value
    let target = UndoProxy(binding: Binding(get: { box.value }, set: { box.value = $0 }), manager: manager)
    manager.beginUndoGrouping()
    target.register(original, name: "時刻合わせ")
    manager.endUndoGrouping()
    manager.undo()
    #expect(box.value == original)
    manager.redo()
    #expect(box.value == edited)
}

@MainActor private final class ProjectBox { var value = Project() }

@Test @MainActor func timelineWithMultipleMarksAndRangesRenders() throws {
    _ = NSApplication.shared
    let r = Recording(name: "test", file: try VromaCutCore.FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: 300), cameraStart: Date(), dateEvidence: "test")
    var project = Project(); project.recordings = [r]
    for second in [30.0, 100.0, 130.0] { try project.addVideoMark(recordingID: r.id, at: MediaTime(seconds: second)) }
    let view = ReviewTimeline(duration: 300, position: 20, marks: project.timelineMarks(recordingID: r.id), clips: project.clips, selected: Set(project.clips.prefix(1).map(\.id)), focus: UUID(), zoom: .constant(1), seek: { _ in }, selectMark: { _ in }, selectClip: { _ in }, edit: { _, _, _ in })
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/vroma-cut-timeline.png"))
    #expect(hosting.bounds.width == 1000)
    #expect(timeLabel(3661.125) == "01:01:01.125")
    window.close()
}
