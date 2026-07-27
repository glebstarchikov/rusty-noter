import SwiftUI
import NoterCore
import NoterEditor

struct EditorContainerView: View {
    @Environment(AppModel.self) private var model
    let note: Note

    @State private var draft: EditorDraftSession
    @State private var changedOnDisk = false

    init(note: Note, coordinator: VaultCoordinator) {
        self.note = note
        _draft = State(initialValue: EditorDraftSession { snapshot in
            _ = try await coordinator.updateDraft(
                snapshot.path,
                title: snapshot.title,
                body: snapshot.body)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: titleBinding)
                .textFieldStyle(.plain)
                .font(TokenFont.editorTitle)
                .tracking(-0.5) // -0.02em at 26pt, design.md display-size rule
                .foregroundStyle(TokenColor.fg)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .onSubmit { draft.flush() }

            metadataSpine
                .padding(.horizontal, 48)
                .padding(.top, 8)

            if let failure = draft.failure {
                saveFailureBanner(failure)
            }

            if changedOnDisk {
                HStack(spacing: 8) {
                    Text("This note changed on disk.")
                        .foregroundStyle(TokenColor.secondary)
                    Button("Reload") { reloadFromModel() }
                }
                .font(TokenFont.supporting)
                .padding(8)
                .background(TokenColor.accentSoft)
            }

            MarkdownTextView(text: bodyBinding, theme: .standard()) { _ in }
        }
        .background(TokenColor.bg)
        .onAppear {
            draft.load(note)
            // Let the app flush this editor's debounced edits before quitting.
            model.flushPendingEdits = { [draft] in draft.flush() }
        }
        .onDisappear {
            model.flushPendingEdits = nil
            draft.flush()
        }
        .onChange(of: note.relativePath) {
            draft.load(note)
            changedOnDisk = false
        }
        .onChange(of: note) {
            // A fresh snapshot for the note we're editing arrived from the
            // coordinator (external edit or our own echo). Compare every field,
            // not just body, so a title-only external change is also caught.
            guard note.relativePath == draft.path else { return }
            if note.body != draft.body || note.metadata.title != draft.title {
                if draft.isDirty { changedOnDisk = true } else { reloadFromModel() }
            }
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft.title },
            set: { draft.updateTitle($0) })
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { draft.body },
            set: { draft.updateBody($0) })
    }

    private var metadataSpine: some View {
        HStack(spacing: 8) {
            Text(Slug.dayString(note.metadata.updated))
            if !note.metadata.tags.isEmpty {
                Text("·")
                Text(note.metadata.tags.joined(separator: ", "))
                    .lineLimit(1)
            }
            Text("·")
            Text("\(WordCount.count(of: draft.body)) words")
        }
        .font(TokenFont.metadata)
        .foregroundStyle(TokenColor.faint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveFailureBanner(
        _ failure: EditorDraftSession.SaveFailure
    ) -> some View {
        HStack(spacing: 8) {
            Text(failure.draft.path == draft.path
                 ? "Couldn’t save changes."
                 : "Couldn’t save “\(failure.draft.title)”.")
                .foregroundStyle(TokenColor.secondary)
            Spacer(minLength: 8)
            Button("Retry") { draft.retryFailedSave() }
        }
        .font(TokenFont.supporting)
        .padding(8)
        .background(TokenColor.accentSoft)
    }

    private func reloadFromModel() {
        draft.reload(note)
        changedOnDisk = false
    }
}
