import AppKit
import SwiftUI

/// Window-local Space handling; text entry and modal panels retain their keys.
struct PlaybackShortcut: NSViewRepresentable {
    var enabled: Bool
    var toggle: () -> Void
    func makeNSView(context: Context) -> ShortcutAnchor { ShortcutAnchor() }
    func updateNSView(_ view: ShortcutAnchor, context: Context) { view.enabled = enabled; view.toggle = toggle }
    static func dismantleNSView(_ view: ShortcutAnchor, coordinator: ()) { view.stop() }
}

@MainActor final class ShortcutAnchor: NSView {
    var enabled = false
    var toggle: () -> Void = {}
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { guard let self else { return false }; return self.handle(event) == nil }
            return consumed ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard enabled, let window, event.window === window, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
        if !event.isARepeat { toggle() }
        return nil
    }
}
