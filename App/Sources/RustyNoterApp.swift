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
                } else {
                    Text(model.notes.isEmpty
                         ? "No notes yet."
                         : "\(model.notes.count) notes loaded from \(model.vaultPathDisplay)")
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
