import VromaCutCore
import AppKit
import SwiftUI
import Testing
@testable import VromaCutApp

@Test @MainActor func previewAndEditingPanesCanBeResized() throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: EditorPanes(preview: { Color.black }, editing: { Color.gray }))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; host.layoutSubtreeIfNeeded()
    func splits(_ view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits) }
    let split = try #require(splits(host).first)
    #expect(!split.isVertical)
    #expect(split.arrangedSubviews.count == 2)
    split.setPosition(200, ofDividerAt: 0); host.layoutSubtreeIfNeeded()
    let smaller = split.arrangedSubviews[0].frame.height
    split.setPosition(380, ofDividerAt: 0); host.layoutSubtreeIfNeeded()
    #expect(split.arrangedSubviews[0].frame.height > smaller + 100)
    #expect(split.arrangedSubviews.allSatisfy { $0.frame.height > 0 })
    window.close()
}

@Test @MainActor func spaceWorksBeforePlayerHoverAndDoesNotInterceptTextOrOtherWindows() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let anchor = ShortcutAnchor(); window.contentView = anchor
    anchor.enabled = true
    var toggles = 0; anchor.toggle = { toggles += 1 }
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    #expect(anchor.handle(space) == nil)
    #expect(toggles == 1)
    let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40)); anchor.addSubview(text); window.makeFirstResponder(text)
    #expect(anchor.handle(space) != nil)
    #expect(toggles == 1)
    window.makeFirstResponder(nil); anchor.enabled = false
    #expect(anchor.handle(space) != nil)
    anchor.enabled = true
    let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    #expect(anchor.handle(other) != nil)
    anchor.stop(); window.close()
}

@MainActor private final class WorkspaceState { var value = Project() }

@Test @MainActor func workspaceWithExportingVideoAndEditableNextVideoFitsWindow() async throws {
    let document = WorkspaceState()
    let ref = try FileReference(url: URL(fileURLWithPath: #filePath))
    let first = Recording(name: "Video A.mp4", file: ref, duration: try MediaTime(seconds: 300), cameraStart: Date().addingTimeInterval(1000))
    let next = Recording(name: "Video B.mp4", file: ref, duration: try MediaTime(seconds: 300), cameraStart: Date())
    document.value.recordings = [next, first]
    for r in [first, next] { for t in [30.0, 100.0, 130.0] { try document.value.addVideoMark(recordingID: r.id, at: MediaTime(seconds: t)) } }
    let queue = ExportQueue(), snapshot = try RecordingExportSnapshot(project: document.value, recordingID: first.id)
    queue.enqueue(snapshot: snapshot, destination: URL(fileURLWithPath: "/tmp/output")) { progress, _ in
        progress(ExportProgress("1/3件: 映像と音声をコピーしています", fraction: 0.42))
        try await Task.sleep(for: .seconds(30))
    }
    let host = NSHostingView(rootView: EditorView(project: Binding(get: { document.value }, set: { document.value = $0 }), exportQueue: queue))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.layoutSubtreeIfNeeded()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while queue.active?.fraction != 0.42 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(queue.active?.fraction == 0.42)
    host.layoutSubtreeIfNeeded()
    func splits(_ view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits) }
    while !splits(host).contains(where: { !$0.isVertical && $0.arrangedSubviews.count == 2 }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded()
    }
    let split = try #require(splits(host).first { !$0.isVertical && $0.arrangedSubviews.count == 2 })
    split.setPosition(split.bounds.height - 100, ofDividerAt: 1)
    split.setPosition(180, ofDividerAt: 0); host.layoutSubtreeIfNeeded()
    let before = split.arrangedSubviews[0].frame.height
    split.setPosition(340, ofDividerAt: 0); host.layoutSubtreeIfNeeded()
    #expect(split.arrangedSubviews[0].frame.height >= before + 100)
    #expect(host.fittingSize.height <= 720)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/vroma-cut-workspace.png"))
    queue.cancelAll(); window.close()
}

@Test @MainActor func compactWorkspaceShowsTimelineWithoutVerticalScrolling() async throws {
    let state = WorkspaceState()
    let recording = Recording(name: "Video.mp4", file: try FileReference(url: URL(fileURLWithPath: #filePath)), duration: try MediaTime(seconds: 300), cameraStart: Date())
    state.value.recordings = [recording]
    for time in [30.0, 100.0, 130.0] { try state.value.addVideoMark(recordingID: recording.id, at: MediaTime(seconds: time)) }
    let host = NSHostingView(rootView: EditorView(project: Binding(get: { state.value }, set: { state.value = $0 })).frame(minWidth: EditorWindowSize.minimumWidth, minHeight: EditorWindowSize.minimumHeight))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !descendants(host, of: NSSplitView.self).contains(where: { !$0.isVertical }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded()
    }
    host.layoutSubtreeIfNeeded()
    window.setContentSize(NSSize(width: 1160, height: 600))
    host.layoutSubtreeIfNeeded()
    let split = try #require(descendants(host, of: NSSplitView.self).first { !$0.isVertical })
    let editing = try #require(split.arrangedSubviews.last)
    let scroll = try #require(descendants(editing, of: NSScrollView.self).first)
    let content = try #require(scroll.documentView)
    #expect(content.frame.height <= scroll.contentSize.height + 1)
    #expect(window.contentLayoutRect.height <= 600)
    let initialEditingHeight = editing.frame.height
    window.setContentSize(NSSize(width: 1260, height: 800)); host.layoutSubtreeIfNeeded()
    #expect(abs(editing.frame.height - initialEditingHeight) <= 1)
    window.setContentSize(NSSize(width: 1160, height: 600)); host.layoutSubtreeIfNeeded()
    split.setPosition(240, ofDividerAt: 0); host.layoutSubtreeIfNeeded()
    let editingHeight = editing.frame.height
    let previewHeight = split.arrangedSubviews[0].frame.height
    window.setContentSize(NSSize(width: 1260, height: 800)); host.layoutSubtreeIfNeeded()
    #expect(abs(editing.frame.height - editingHeight) <= 1)
    #expect(split.arrangedSubviews[0].frame.height >= previewHeight + 199)
    window.setContentSize(NSSize(width: 1160, height: 600)); host.layoutSubtreeIfNeeded()
    #expect(abs(editing.frame.height - editingHeight) <= 1)

    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/vroma-cut-compact.png"))
}
