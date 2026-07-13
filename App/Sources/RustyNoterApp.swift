import SwiftUI
import NoterCore

@main
struct RustyNoterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsWelcome {
                    Text("Vault folder not found. Settings arrive in a later task.")
                        .foregroundStyle(TokenColor.secondary)
                } else if let path = model.selectedPath ?? model.notes.first?.relativePath,
                          let note = model.notes.first(where: { $0.relativePath == path }) {
                    EditorContainerView(note: note)
                } else {
                    Text("No notes yet.")
                        .foregroundStyle(TokenColor.secondary)
                }
            }
            .frame(minWidth: 900, minHeight: 560)
            .background(TokenColor.bg)
            .task { await model.bootstrap() }
        }
        .environment(model)
    }
}
