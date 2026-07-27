import SwiftUI
import NoterCore

struct NoteListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
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
                                    .transition(reduceMotion ? .identity : .opacity)
                            }
                        } header: {
                            if !section.title.isEmpty {
                                sectionHeader(section.title)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(TokenColor.bg)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { move($0) }
            .onDeleteCommand {
                if let path = model.selectedPath { Task { await model.deleteNote(path) } }
            }
            .onChange(of: model.selectedPath) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
        .overlay { emptyState }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TokenFont.metadata)
            .foregroundStyle(TokenColor.faint)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .padding(.horizontal, 16) // aligns with the row title (8 outer + 8 inner)
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
                    .font(TokenFont.interface)
                    .foregroundStyle(TokenColor.secondary)
            } else if model.sidebarSelection != .all {
                // A sidebar filter with no matches in a non-empty vault: a
                // New Note here creates a plain note the filter excludes, so
                // it would look like the note vanished. Offer no action.
                Text(model.sidebarSelection == .meetings ? "No meetings yet." : "Nothing here yet.")
                    .font(TokenFont.interface)
                    .foregroundStyle(TokenColor.secondary)
            } else {
                VStack(spacing: 12) {
                    Text("No notes yet.")
                        .font(TokenFont.interface)
                        .foregroundStyle(TokenColor.secondary)
                    Button("New Note") { Task { await model.newNote() } }
                }
            }
        }
    }
}

private struct NoteRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let note: Note
    let selected: Bool
    @State private var hovering = false

    private var fill: Color {
        selected ? TokenColor.accentSoft : (hovering ? TokenColor.elevated : .clear)
    }

    // Read pin state live from the model so the context-menu label reflects the
    // current truth, not a value captured when the row first rendered (which
    // goes stale in a LazyVStack, leaving the label stuck on "Pin").
    private var isPinned: Bool {
        model.notes.first { $0.relativePath == note.relativePath }?.metadata.pinned
            ?? note.metadata.pinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.metadata.title.isEmpty ? "Untitled" : note.metadata.title)
                    .font(TokenFont.rowTitle)
                    .foregroundStyle(TokenColor.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if note.metadata.status == .recording {
                    Circle().fill(TokenColor.danger).frame(width: 7, height: 7)
                        .accessibilityLabel("Recording")
                }
                Text(NoteGrouping.rowDateLabel(for: note.metadata.updated, now: Date(), calendar: .current))
                    .font(TokenFont.metadata)
                    .foregroundStyle(TokenColor.faint)
            }
            if !note.snippet.isEmpty {
                Text(note.snippet)
                    .font(TokenFont.supporting)
                    .foregroundStyle(TokenColor.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Clear any stranded hover when the selection moves. SwiftUI's .onHover
        // doesn't emit `false` when rows reorder under a stationary cursor (e.g.
        // Cmd+N inserts a note at the top), so the previously hovered row would
        // keep its hover fill and read as a phantom second selection.
        .onChange(of: model.selectedPath) { hovering = false }
        .animation(reduceMotion ? nil : TokenMotion.micro, value: hovering)
        .animation(reduceMotion ? nil : TokenMotion.micro, value: selected)
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") {
                Task { await model.togglePin(note.relativePath) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await model.deleteNote(note.relativePath) }
            }
        }
    }
}
