import SwiftUI
import NoterCore
import NoterEditor

struct EditorContainerView: View {
    @Environment(AppModel.self) private var model
    let note: Note

    @State private var draftBody: String = ""
    @State private var draftTitle: String = ""
    @State private var lastLoadedPath: String?
    @State private var lastSavedBody: String = ""
    @State private var changedOnDisk = false
    @State private var saveTask: Task<Void, Never>?

    private var isDirty: Bool { draftBody != lastSavedBody }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(TokenColor.fg)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .onSubmit { commitTitle() }

            if changedOnDisk {
                HStack(spacing: 8) {
                    Text("This note changed on disk.")
                        .foregroundStyle(TokenColor.secondary)
                    Button("Reload") { reloadFromModel() }
                }
                .font(.system(size: 12))
                .padding(8)
                .background(TokenColor.accentSoft)
            }

            MarkdownTextView(text: $draftBody, theme: .standard()) { newBody in
                scheduleSave(newBody)
            }
        }
        .background(TokenColor.bg)
        .onAppear { loadNote() }
        .onChange(of: note.relativePath) { loadNote() }
        .onChange(of: note.body) {
            // Snapshot arrived from the coordinator (external or echo).
            guard note.relativePath == lastLoadedPath else { return }
            if note.body != draftBody {
                if isDirty { changedOnDisk = true } else { reloadFromModel() }
            }
        }
    }

    private func loadNote() {
        saveTask?.cancel()
        draftBody = note.body
        draftTitle = note.metadata.title
        lastSavedBody = note.body
        lastLoadedPath = note.relativePath
        changedOnDisk = false
    }

    private func reloadFromModel() {
        draftBody = note.body
        lastSavedBody = note.body
        draftTitle = note.metadata.title
        changedOnDisk = false
    }

    private func scheduleSave(_ body: String) {
        saveTask?.cancel()
        let path = note.relativePath
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if let saved = try? await model.coordinator?.updateBody(path, body: body) {
                lastSavedBody = saved.body
            }
        }
    }

    private func commitTitle() {
        let path = note.relativePath
        let title = draftTitle
        Task { _ = try? await model.coordinator?.updateTitle(path, title: title) }
    }
}
