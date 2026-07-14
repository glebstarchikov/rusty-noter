import SwiftUI
import NoterCore

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPath) {
            ForEach(model.noteSections) { section in
                Section {
                    ForEach(section.notes) { note in
                        NoteRow(note: note,
                                selected: model.selectedPath == note.relativePath)
                            .tag(note.relativePath)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenColor.faint)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TokenColor.bg)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.visibleNotes.isEmpty {
            if model.searchHits != nil {
                Text("No notes match this search.")
                    .font(.system(size: 13))
                    .foregroundStyle(TokenColor.secondary)
            } else if model.sidebarSelection != .all {
                Text(model.sidebarSelection == .meetings ? "No meetings yet." : "Nothing here yet.")
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

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    @State private var hovering = false

    private var fill: Color {
        selected ? TokenColor.accentSoft : (hovering ? TokenColor.elevated : .clear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.metadata.title.isEmpty ? "Untitled" : note.metadata.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TokenColor.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if note.metadata.status == .recording {
                    Circle().fill(TokenColor.danger).frame(width: 7, height: 7)
                        .accessibilityLabel("Recording")
                }
                Text(NoteGrouping.rowDateLabel(for: note.metadata.updated, now: Date(), calendar: .current))
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
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
