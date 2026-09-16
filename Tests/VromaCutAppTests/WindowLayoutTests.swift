import AppKit
import SwiftUI
import Testing
@testable import VromaCutApp

@Test func windowPlacementRecoversFromRemovedAndSmallerDisplays() {
    let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let original = CGRect(x: -1800, y: 200, width: 1200, height: 700)
    let minimum = CGSize(width: 1000, height: 560)
    #expect(WindowPlacement.fit(original, screens: [main, external], minimum: minimum) == original)
    let recovered = WindowPlacement.fit(original, screens: [main], minimum: minimum)
    #expect(main.contains(recovered))
    #expect(recovered.size == original.size)
    let small = CGRect(x: 0, y: 30, width: 800, height: 500)
    #expect(WindowPlacement.fit(original, screens: [small], minimum: minimum) == small)
    let overhanging = CGRect(x: 1300, y: 800, width: 1100, height: 650)
    #expect(main.contains(WindowPlacement.fit(overhanging, screens: [main], minimum: minimum)))
    let invalid = CGRect(x: CGFloat.infinity, y: 0, width: -1, height: 700)
    #expect(main.contains(WindowPlacement.fit(invalid, screens: [main], minimum: minimum)))
}

@Test @MainActor func windowAndVideoDimensionsPersistAndResetTogether() async throws {
    _ = NSApplication.shared
    let suite = "com.tsuyukimakoto.vroma.cut.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = WindowLayoutState(defaults: defaults)
    let first = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1160, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    first.isReleasedWhenClosed = false
    defer { first.close() }
    state.attach(first)
    var changed = first.frame
    changed.origin.x += 30; changed.origin.y += 20; changed.size.height += 40
    first.setFrame(changed, display: false)
    state.captureWindow(); state.captureSplit(preview: 280, editing: 240)
    for _ in 0..<5 { await Task.yield() }
    #expect(first.frame == changed)
    let reopened = WindowLayoutState(defaults: defaults)
    #expect(reopened.saved.frame == first.frame)
    #expect(reopened.saved.previewHeight == 280)
    #expect(reopened.saved.editingHeight == 240)
    let next = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    next.isReleasedWhenClosed = false
    defer { next.close() }
    reopened.attach(next)
    let screens = NSScreen.screens.map(\.visibleFrame)
    let expected = WindowPlacement.fit(first.frame, screens: screens, minimum: next.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 1000, height: 560)).size)
    #expect(next.frame == expected)
    reopened.reset()
    #expect(reopened.saved.previewHeight == nil)
    #expect(reopened.saved.editingHeight == nil)
    #expect(reopened.resetGeneration == 1)
    #expect(screens.contains { $0.contains(next.frame) })
    let fresh = WindowLayoutState(defaults: defaults)
    #expect(fresh.saved.frame == next.frame)
    #expect(fresh.saved.previewHeight == nil)
}

@Test @MainActor func splitRestoresVideoHeightAndResetAllowsDividerDragging() async throws {
    let suite = "com.tsuyukimakoto.vroma.cut.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = WindowLayoutState(defaults: defaults)
    state.captureSplit(preview: 280, editing: 240)
    let controller = EditorSplitController(preview: AnyView(Color.black), editing: AnyView(Color.gray), layout: state)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = controller
    window.setContentSize(CGSize(width: 1000, height: 650))
    defer { window.close() }
    controller.view.layoutSubtreeIfNeeded()
    for _ in 0..<10 { await Task.yield(); controller.view.layoutSubtreeIfNeeded() }
    #expect(abs(controller.preview.view.frame.height - 280) <= 1)
    controller.splitView.setPosition(320, ofDividerAt: 0)
    controller.view.layoutSubtreeIfNeeded()
    for _ in 0..<5 { await Task.yield() }
    let persisted = WindowLayoutState(defaults: defaults)
    #expect(abs((persisted.saved.previewHeight ?? 0) - 320) <= 1)
    let editingHeight = controller.editing.view.frame.height
    window.setContentSize(CGSize(width: 1000, height: 800)); controller.view.layoutSubtreeIfNeeded()
    #expect(abs(controller.editing.view.frame.height - editingHeight) <= 1)
    state.reset(); controller.applyReset(generation: state.resetGeneration)
    controller.view.layoutSubtreeIfNeeded()
    controller.splitView.setPosition(350, ofDividerAt: 0); controller.view.layoutSubtreeIfNeeded()
    #expect(abs(controller.preview.view.frame.height - 350) <= 1)
}

@Test @MainActor func windowBridgeTracksMovesAndFitsTheActualWorkspaceOnSmallScreen() async throws {
    let suite = "com.tsuyukimakoto.vroma.cut.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let visible = CGRect(x: 0, y: 25, width: 800, height: 500)
    let state = WindowLayoutState(defaults: defaults, screenFrames: { [visible] })
    let host = NSHostingView(rootView: EditorWindowContent(project: .constant(.init()), layout: state))
    let window = NSWindow(contentRect: CGRect(x: 1200, y: 800, width: 1160, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<20 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    #expect(state.window === window)
    #expect(visible.contains(window.frame))
    #expect(state.needsCompactDisplay)
    #expect(window.contentLayoutRect.width <= 800)
    let saved = WindowLayoutState(defaults: defaults)
    #expect(saved.saved.frame == window.frame)
    window.setFrameOrigin(CGPoint(x: 40, y: 35))
    for _ in 0..<5 { await Task.yield() }
    #expect(WindowLayoutState(defaults: defaults).saved.frame == window.frame)
    state.reset()
    for _ in 0..<20 { await Task.yield(); host.layoutSubtreeIfNeeded() }
    #expect(visible.contains(window.frame))
}
