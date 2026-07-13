import SwiftUI
import NoterCore

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPath) {
            ForEach(model.visibleNotes) { note in
                NoteRow(note: note, selected: model.selectedPath == note.relativePath)
                    .tag(note.relativePath)
                    .listRowSeparatorTint(TokenColor.border)
                    .listRowBackground(
                        model.selectedPath == note.relativePath
                            ? TokenColor.accentSoft : Color.clear)
            }
        }
        .listStyle(.plain)
        .background(TokenColor.bg)
        .overlay {
            if model.visibleNotes.isEmpty {
                // Empty state: one sentence, at most one action (design.md).
                if model.searchHits != nil {
                    Text("No notes match this search.")
                        .font(.system(size: 13))
                        .foregroundStyle(TokenColor.secondary)
                } else {
                    VStack(spacing: 12) {
                        Text("No notes yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(TokenColor.secondary)
                        Button("New Note") { Task { await model.newNote() } }
                    }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.metadata.title.isEmpty ? "Untitled" : note.metadata.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TokenColor.fg)
                    .lineLimit(1)
                Spacer()
                if note.metadata.status == .recording {
                    Circle().fill(TokenColor.danger).frame(width: 7, height: 7)
                        .accessibilityLabel("Recording")
                }
                Text(Slug.dayString(note.metadata.updated))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenColor.faint)
            }
            if !note.snippet.isEmpty {
                Text(note.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(TokenColor.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}
