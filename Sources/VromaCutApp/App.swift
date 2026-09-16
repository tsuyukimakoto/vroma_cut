import SwiftUI
import VromaCutCore

enum EditorWindowSize {
    static let minimumWidth: CGFloat = 1000
    static let minimumHeight: CGFloat = 560
    static let initialWidth: CGFloat = 1160
    static let initialHeight: CGFloat = 600
}

@main struct VromaCutApp: App {
    @State private var project = Project()
    @State private var layout = WindowLayoutState()

    var body: some Scene {
        Window("Vroma Cut", id: "editor") {
            EditorWindowContent(project: $project, layout: layout)
        }
        .defaultSize(width: EditorWindowSize.initialWidth, height: EditorWindowSize.initialHeight)
        .restorationBehavior(.disabled)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("初期サイズ・表示位置をリセット") { layout.reset() }
            }
        }
    }
}

struct EditorWindowContent: View {
    @Binding var project: Project
    let layout: WindowLayoutState

    var body: some View {
        Group {
            if layout.needsCompactDisplay {
                ScrollView([.horizontal, .vertical]) {
                    EditorView(project: $project, layout: layout)
                        .frame(width: EditorWindowSize.minimumWidth, height: EditorWindowSize.minimumHeight)
                }
            } else {
                EditorView(project: $project, layout: layout)
            }
        }
        .frame(minWidth: layout.minimumContentSize.width, minHeight: layout.minimumContentSize.height)
        .background(WindowLayoutBridge(state: layout).frame(width: 0, height: 0))
    }
}
