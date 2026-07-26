import SwiftUI
import NoterCore

@main
struct RustyNoterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsWelcome {
                    WelcomeView()
                } else {
                    MainSplitView()
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .task { await model.bootstrap() }
        }
        .environment(model)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { Task { await model.newNote() } }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { model.paletteShown.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } content: {
                NoteListView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290)
                    .searchable(text: $model.searchQuery, placement: .toolbar,
                                prompt: "Search notes")
                    .onChange(of: model.searchQuery) {
                        Task { await model.runSearch() }
                    }
            } detail: {
                if let path = model.selectedPath,
                   let note = model.notes.first(where: { $0.relativePath == path }) {
                    EditorContainerView(note: note)
                } else {
                    Text("Select a note.")
                        .font(.system(size: 13))
                        .foregroundStyle(TokenColor.secondary)
                }
            }
            .background(TokenColor.bg)
            // Drop the redundant system window title ("Rusty Noter") from the
            // content column; the crafted mono wordmark in the sidebar is now the
            // app identity. Visual-only — accessibility + Window menu keep it.
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.newNote() }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .help("New Note (Cmd+N)")
                }
            }
            if model.paletteShown {
                Color.black.opacity(0.001) // click-away catcher
                    .ignoresSafeArea()
                    .onTapGesture { model.paletteShown = false }
                CommandPaletteView()
                    .padding(.top, 120)
                    .transition(.opacity)
            }
        }
    }
}
