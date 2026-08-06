import SwiftUI
import NoterCore

/// Defers termination until the editor's debounced save has actually landed.
/// `willTerminate` is too late to await async work, so this is the only hook
/// that can keep the process alive for the write.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    @MainActor
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let task = model?.flushPendingEdits?() else { return .terminateNow }
        Task {
            await task.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RustyNoterApp: App {
    @State private var model = AppModel()
    @State private var recording: RecordingController?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsWelcome {
                    WelcomeView()
                } else {
                    MainSplitView(recording: recording)
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .task {
                if recording == nil { recording = RecordingController(model: model) }
                appDelegate.model = model
                await model.bootstrap()
            }
        }
        .environment(model)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { Task { await model.newNote() } }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Record Meeting") { recording?.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { model.togglePalette() }
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
    /// Owned by the App scene so the ⌘⇧R menu command and this toolbar button
    /// drive the same session.
    let recording: RecordingController?

    private var collectionTitle: String {
        switch model.sidebarSelection {
        case .all:
            "All Notes"
        case .meetings:
            "Meetings"
        case .tag(let tag):
            tag
        case .folder(let folder):
            folder
        }
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } content: {
                NoteListView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290)
                    .navigationTitle(collectionTitle)
            } detail: {
                if let path = model.selectedPath,
                   let note = model.notes.first(where: { $0.relativePath == path }),
                   let coordinator = model.coordinator {
                    EditorContainerView(note: note, coordinator: coordinator)
                } else {
                    Text("Select a note.")
                        .font(TokenFont.interface)
                        .foregroundStyle(TokenColor.secondary)
                }
            }
            .background(TokenColor.bg)
            // Keep the toolbar under one owner. A column-scoped search field
            // merged with split-view toolbar items can be relaid out when the
            // window changes presentation.
            .searchable(text: $model.searchQuery, placement: .toolbar,
                        prompt: "Search notes")
            .onChange(of: model.searchQuery) {
                Task { await model.runSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await model.newNote() }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .help("New Note (Cmd+N)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        recording?.toggle()
                    } label: {
                        if recording?.isRecording == true {
                            Label(recording?.elapsedText ?? "",
                                  systemImage: "stop.circle.fill")
                                .foregroundStyle(TokenColor.danger)
                        } else {
                            Label("Record Meeting", systemImage: "record.circle")
                        }
                    }
                    .help("Record Meeting (Cmd+Shift+R)")
                }
            }
            .alert("Can't record",
                   isPresented: Binding(
                    get: { recording?.error != nil },
                    set: { if !$0 { recording?.clearError() } })) {
                if let blocker = recording?.blockers.first {
                    Button("Open System Settings") { recording?.openSettings(for: blocker) }
                }
                Button("OK", role: .cancel) { recording?.clearError() }
            } message: {
                Text(recording?.error ?? "")
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .windowToolbarFullScreenVisibility(.visible)
            if model.paletteShown {
                Color.black.opacity(0.001) // click-away catcher
                    .ignoresSafeArea()
                    .onTapGesture { model.setPaletteShown(false) }
                CommandPaletteView()
                    .padding(.top, 120)
                    .transition(.opacity)
            }
        }
    }
}
