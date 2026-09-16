import AppKit
import SwiftUI

struct SavedWindowLayout: Codable {
    var frame: CGRect?
    var previewHeight: CGFloat?
    var editingHeight: CGFloat?
}

enum WindowPlacement {
    static func fit(_ proposed: CGRect, screens: [CGRect], minimum: CGSize) -> CGRect {
        guard let fallback = screens.first else { return proposed }
        let valid = [proposed.minX, proposed.minY, proposed.width, proposed.height].allSatisfy(\.isFinite)
            && proposed.width > 0 && proposed.height > 0
        let requested = valid ? proposed : CGRect(x: fallback.midX - 580, y: fallback.midY - 300, width: 1160, height: 600)
        let screen = screens.max { a, b in
            let aa = a.intersection(requested), bb = b.intersection(requested)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        }.flatMap { $0.intersects(requested) ? $0 : nil } ?? fallback
        let size = CGSize(width: min(screen.width, max(minimum.width, requested.width)),
                          height: min(screen.height, max(minimum.height, requested.height)))
        return CGRect(x: min(max(requested.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(requested.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

@MainActor @Observable final class WindowLayoutState {
    private static let key = "editorWindowLayout.v1"
    private let defaults: UserDefaults
    private let screenFrames: () -> [CGRect]
    private(set) var saved: SavedWindowLayout
    private(set) var resetGeneration = 0
    private(set) var availableContentSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1160, height: 800)
    weak var window: NSWindow?
    var transitioningFullScreen = false
    private var pendingReset = false
    private var applying = false
    private var frameRevision = 0

    init(defaults: UserDefaults = .standard, screenFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.defaults = defaults; self.screenFrames = screenFrames
        if let first = screenFrames().first { availableContentSize = first.size }
        saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SavedWindowLayout.self, from: $0) }
            ?? SavedWindowLayout()
    }
    var minimumContentSize: CGSize {
        CGSize(width: min(EditorWindowSize.minimumWidth, availableContentSize.width),
               height: min(EditorWindowSize.minimumHeight, availableContentSize.height))
    }
    var needsCompactDisplay: Bool {
        availableContentSize.width < EditorWindowSize.minimumWidth || availableContentSize.height < EditorWindowSize.minimumHeight
    }
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        applyFrame(saved.frame ?? initialFrame(window))
    }
    func captureWindow() {
        guard !applying, !transitioningFullScreen, let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        guard saved.frame != window.frame else { return }
        frameRevision += 1
        saved.frame = window.frame
        persist()
    }
    func captureSplit(preview: CGFloat, editing: CGFloat) {
        guard !applying, !transitioningFullScreen, window?.styleMask.contains(.fullScreen) != true,
              preview.isFinite, editing.isFinite, preview >= 160, editing >= 200 else { return }
        guard saved.previewHeight != preview || saved.editingHeight != editing else { return }
        saved.previewHeight = preview; saved.editingHeight = editing
        persist()
    }
    func reset() {
        saved = SavedWindowLayout(); defaults.removeObject(forKey: Self.key)
        guard let window else { resetGeneration += 1; return }
        if window.styleMask.contains(.fullScreen) || transitioningFullScreen {
            pendingReset = true
            if !transitioningFullScreen { window.toggleFullScreen(nil) }
            return
        }
        applyFrame(initialFrame(window))
        resetGeneration += 1
    }
    func screenConfigurationChanged() {
        guard !applying, !transitioningFullScreen, let window, !window.styleMask.contains(.fullScreen) else { return }
        applyFrame(window.frame)
    }
    func finishedFullScreenTransition() {
        transitioningFullScreen = false
        if pendingReset, window?.styleMask.contains(.fullScreen) == false { pendingReset = false; reset() }
        else if pendingReset, window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        else if window?.styleMask.contains(.fullScreen) == false { screenConfigurationChanged() }
    }
    private func initialFrame(_ window: NSWindow) -> CGRect {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: EditorWindowSize.initialWidth, height: EditorWindowSize.initialHeight))
        frame.origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        return frame
    }
    private func applyFrame(_ proposed: CGRect) {
        guard let window else { return }
        applying = true
        frameRevision += 1
        let screens = screenFrames()
        let frameMinimum = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: EditorWindowSize.minimumWidth, height: EditorWindowSize.minimumHeight)).size
        let fitted = WindowPlacement.fit(proposed, screens: screens, minimum: frameMinimum)
        let visible = screens.max { a, b in
            let aa = a.intersection(fitted), bb = b.intersection(fitted)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        } ?? fitted
        let available = window.contentRect(forFrameRect: visible).size
        let changedAvailableSize = availableContentSize != available
        availableContentSize = available
        window.contentMinSize = minimumContentSize
        window.setFrame(fitted, display: true)
        applying = false
        captureWindow()
        if changedAvailableSize {
            let revision = frameRevision
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window, self.window === window, self.frameRevision == revision else { return }
                // Let SwiftUI adopt the smaller screen's minimum size before constraining the frame again.
                self.applying = true
                window.contentMinSize = self.minimumContentSize
                window.setFrame(fitted, display: true)
                self.applying = false
                self.captureWindow()
            }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key) }
    }
}

struct WindowLayoutBridge: NSViewRepresentable {
    let state: WindowLayoutState
    func makeNSView(context: Context) -> WindowLayoutAnchor { WindowLayoutAnchor(state: state) }
    func updateNSView(_ view: WindowLayoutAnchor, context: Context) {}
    static func dismantleNSView(_ view: WindowLayoutAnchor, coordinator: ()) { view.stop() }
}

@MainActor final class WindowLayoutAnchor: NSView {
    let state: WindowLayoutState
    init(state: WindowLayoutState) { self.state = state; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard let window else { return }
        // SwiftUI installs the toolbar and initial size during the current layout pass.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window else { return }
            self.state.attach(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(self.changed), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(self.screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            center.addObserver(self, selector: #selector(self.screensChanged), name: NSWindow.didChangeScreenNotification, object: window)
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(self.fullScreenWillChange), name: name, object: window)
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(self.fullScreenDidChange), name: name, object: window)
            }
        }
    }
    @objc private func changed() { state.captureWindow() }
    @objc private func screensChanged() { state.screenConfigurationChanged() }
    @objc private func fullScreenWillChange() { state.transitioningFullScreen = true }
    @objc private func fullScreenDidChange() { state.finishedFullScreenTransition() }
    func stop() { NotificationCenter.default.removeObserver(self) }
}
