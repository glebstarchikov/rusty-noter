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
    @State private var lastSavedTitle: String = ""
    @State private var changedOnDisk = false
    @State private var saveTask: Task<Void, Never>?

    private var isDirty: Bool {
        draftBody != lastSavedBody || draftTitle != lastSavedTitle
    }

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
        .onChange(of: note) {
            // A fresh snapshot for the note we're editing arrived from the
            // coordinator (external edit or our own echo). Compare every field,
            // not just body, so a title-only external change is also caught.
            guard note.relativePath == lastLoadedPath else { return }
            if note.body != draftBody || note.metadata.title != draftTitle {
                if isDirty { changedOnDisk = true } else { reloadFromModel() }
            }
        }
    }

    private func loadNote() {
        saveTask?.cancel()
        draftBody = note.body
        draftTitle = note.metadata.title
        lastSavedBody = note.body
        lastSavedTitle = note.metadata.title
        lastLoadedPath = note.relativePath
        changedOnDisk = false
    }

    private func reloadFromModel() {
        saveTask?.cancel()
        draftBody = note.body
        draftTitle = note.metadata.title
        lastSavedBody = note.body
        lastSavedTitle = note.metadata.title
        changedOnDisk = false
    }

    private func scheduleSave(_ body: String) {
        saveTask?.cancel()
        let path = note.relativePath
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if let saved = try? await model.coordinator?.updateBody(path, body: body) {
                // Guard against an A->B switch leaving A's debounced save in
                // flight: its completion must not clobber B's dirty bookkeeping.
                // The write to A's own file is correct and intended; only the
                // lastSaved bookkeeping is note-specific.
                guard path == lastLoadedPath else { return }
                lastSavedBody = saved.body
            }
        }
    }

    private func commitTitle() {
        let path = note.relativePath
        let title = draftTitle
        Task {
            if let saved = try? await model.coordinator?.updateTitle(path, title: title) {
                guard path == lastLoadedPath else { return }
                lastSavedTitle = saved.metadata.title
            }
        }
    }
}
