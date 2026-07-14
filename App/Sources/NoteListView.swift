import SwiftUI
import NoterCore

struct NoteListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    /// Visible notes flattened in render order, so arrow keys can walk the
    /// selection across section boundaries.
    private var flatPaths: [String] {
        model.noteSections.flatMap { $0.notes.map(\.relativePath) }
    }

    var body: some View {
        // A custom scroll+stack, not `List`: SwiftUI's `List(selection:)` paints
        // its own bright system highlight on macOS that can't be suppressed in
        // `.plain` style, which stacked on top of our accent-soft pill (two
        // selections). Here each row draws the only selection background there
        // is. Keyboard nav is preserved via `.focusable()` + `.onMoveCommand`.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.noteSections) { section in
                        Section {
                            ForEach(section.notes) { note in
                                NoteRow(note: note,
                                        selected: model.selectedPath == note.relativePath)
                                    .id(note.relativePath)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.select(note.relativePath)
                                        listFocused = true
                                    }
                            }
                        } header: {
                            if !section.title.isEmpty {
                                sectionHeader(section.title)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(TokenColor.bg)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { move($0) }
            .onChange(of: model.selectedPath) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
        .overlay { emptyState }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(TokenColor.faint)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 18) // aligns with the row title (8 outer + 10 inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TokenColor.bg) // opaque so pinned headers occlude scrolling rows
    }

    /// Move the selection one row up/down through the flattened visible order.
    /// With nothing selected yet, down picks the first row and up the last.
    private func move(_ direction: MoveCommandDirection) {
        let paths = flatPaths
        guard !paths.isEmpty else { return }
        guard let current = model.selectedPath,
              let idx = paths.firstIndex(of: current) else {
            model.select(direction == .up ? paths.last : paths.first)
            return
        }
        switch direction {
        case .up where idx > 0: model.select(paths[idx - 1])
        case .down where idx < paths.count - 1: model.select(paths[idx + 1])
        default: break
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.visibleNotes.isEmpty {
            // Empty state: one sentence, at most one action (design.md).
            if model.searchHits != nil {
                Text("No notes match this search.")
                    .font(.system(size: 13))
                    .foregroundStyle(TokenColor.secondary)
            } else if model.sidebarSelection != .all {
                // A sidebar filter with no matches in a non-empty vault: a
                // New Note here creates a plain note the filter excludes, so
                // it would look like the note vanished. Offer no action.
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
