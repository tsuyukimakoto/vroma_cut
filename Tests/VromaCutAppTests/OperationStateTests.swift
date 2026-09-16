import AppKit
import SwiftUI
import Foundation
import Testing
@testable import VromaCutApp
import VromaCutCore

@MainActor private func waitForCompletion(_ state: OperationState) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while state.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!state.isRunning)
}

@Test @MainActor func controlsRecoverAfterSuccessFailureAndCancellation() async throws {
    let state = OperationState()
    state.start("確認中") { }
    #expect(state.isRunning)
    try await waitForCompletion(state)
    #expect(state.error == nil)
    state.start("確認中") { throw CutError.invalid("missing source") }
    try await waitForCompletion(state)
    #expect(state.error == "missing source")
    state.start("確認中") { try await Task.sleep(for: .seconds(30)) }
    state.cancel()
    #expect(state.isCancelling)
    try await waitForCompletion(state)
    #expect(state.error == nil)
    #expect(!state.isCancelling)
    #expect(state.message.hasPrefix("キャンセルしました"))
    state.start("再試行") { }
    try await waitForCompletion(state)
}

@Test @MainActor func repeatedClickDoesNotStartConcurrentOperation() async throws {
    let state = OperationState()
    var starts = 0
    state.start("first") { starts += 1; try await Task.sleep(for: .milliseconds(20)) }
    state.start("second") { starts += 1 }
    try await waitForCompletion(state)
    #expect(starts == 1)
}

@Test @MainActor func progressAndCancelRemainVisibleInCompactBanner() throws {
    _ = NSApplication.shared
    let state = OperationState()
    state.start("1/42件: 圧縮データと時刻を照合しています") { try await Task.sleep(for: .seconds(30)) }
    state.fraction = 0.42
    let hosting = NSHostingView(rootView: OperationBanner(operation: state).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/vroma-cut-operation-banner.png"))
    #expect(hosting.fittingSize.height <= 70)
    state.cancel(); window.close()
}
