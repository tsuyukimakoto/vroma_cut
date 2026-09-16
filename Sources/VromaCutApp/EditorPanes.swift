import SwiftUI
import AppKit

struct EditorPanes<Preview: View, Editing: View>: NSViewControllerRepresentable {
    let layout: WindowLayoutState?
    let preview: Preview
    let editing: Editing
    init(layout: WindowLayoutState? = nil, @ViewBuilder preview: () -> Preview, @ViewBuilder editing: () -> Editing) {
        self.layout = layout; self.preview = preview(); self.editing = editing()
    }
    func makeNSViewController(context: Context) -> EditorSplitController {
        EditorSplitController(preview: AnyView(preview), editing: AnyView(editing), layout: layout)
    }
    func updateNSViewController(_ controller: EditorSplitController, context: Context) {
        controller.preview.rootView = AnyView(preview)
        controller.editing.rootView = AnyView(editing)
        controller.applyReset(generation: layout?.resetGeneration ?? 0)
    }
}

@MainActor final class EditorSplitController: NSSplitViewController {
    private var arranged = false
    private var adjusting = false
    private var restoring = false
    private var previousHeight: CGFloat = 0
    private var preferredEditingHeight: CGFloat?
    private var resetGeneration = 0
    private let layout: WindowLayoutState?
    let preview: NSHostingController<AnyView>
    let editing: NSHostingController<AnyView>
    init(preview: AnyView, editing: AnyView, layout: WindowLayoutState? = nil) {
        self.layout = layout; self.resetGeneration = layout?.resetGeneration ?? 0
        self.preview = NSHostingController(rootView: preview)
        self.editing = NSHostingController(rootView: editing)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .paneSplitter
        for (controller, minimum) in [(self.preview, 160.0), (self.editing, 200.0)] {
            controller.sizingOptions = []
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = minimum
            item.canCollapse = false
            addSplitViewItem(item)
        }
        splitViewItems[0].holdingPriority = .init(rawValue: 249)
        splitViewItems[1].holdingPriority = .init(rawValue: 250)
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let height = splitView.bounds.height
        guard !arranged, !adjusting, height >= 360 + splitView.dividerThickness else { return }
        adjusting = true
        let initialEditing = max(200, editing.view.fittingSize.height)
        let previewHeight = layout?.saved.previewHeight ?? (height - initialEditing - splitView.dividerThickness)
        splitView.setPosition(min(height - 200 - splitView.dividerThickness, max(160, previewHeight)), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        preferredEditingHeight = editing.view.frame.height
        previousHeight = height
        arranged = true; adjusting = false
        if let savedPreview = layout?.saved.previewHeight {
            restoring = true
            let generation = layout?.resetGeneration
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.view.window != nil, self.layout?.resetGeneration == generation else { return }
                let height = self.splitView.bounds.height
                self.adjusting = true
                self.splitView.setPosition(min(height - 200 - self.splitView.dividerThickness, max(160, savedPreview)), ofDividerAt: 0)
                self.splitView.layoutSubtreeIfNeeded()
                self.preferredEditingHeight = self.editing.view.frame.height
                self.previousHeight = height
                self.adjusting = false; self.restoring = false
                self.saveSplit()
            }
        } else { saveSplit() }
    }
    @objc private func splitResized() {
        guard arranged, !adjusting, !restoring else { return }
        let height = splitView.bounds.height
        guard height >= 360 + splitView.dividerThickness else { return }
        adjusting = true
        if abs(height - previousHeight) > 0.5, let preferredEditingHeight {
            // A window resize changes the video height; divider moves change the editing height.
            let keptHeight = min(preferredEditingHeight, height - 160 - splitView.dividerThickness)
            splitView.setPosition(height - max(200, keptHeight) - splitView.dividerThickness, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        } else {
            preferredEditingHeight = editing.view.frame.height
        }
        previousHeight = height
        adjusting = false
        saveSplit()
    }
    private func saveSplit() {
        let generation = layout?.resetGeneration
        Task { @MainActor [weak self] in
            guard let self, self.view.window != nil, self.layout?.resetGeneration == generation else { return }
            self.layout?.captureSplit(preview: self.preview.view.frame.height, editing: self.editing.view.frame.height)
        }
    }
    func applyReset(generation: Int) {
        guard generation != resetGeneration else { return }
        resetGeneration = generation
        arranged = false; restoring = false; preferredEditingHeight = nil
        view.needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
