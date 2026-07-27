import SwiftUI
import NoterCore

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private enum Row: Identifiable {
        case note(Note)
        case newNote
        var id: String {
            switch self {
            case .note(let n): return n.relativePath
            case .newNote: return "command.newNote"
            }
        }
    }

    private var rows: [Row] {
        let titles = model.notes.map(\.metadata.title)
        let ranked = FuzzyMatch.rank(query: query, candidates: titles).prefix(8)
        var result: [Row] = ranked.map { .note(model.notes[$0]) }
        result.append(.newNote)
        return result
    }

    private var resultsHeight: CGFloat {
        min(CGFloat(rows.count) * 32, 320)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to note or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(TokenFont.commandInput)
                .padding(14)
                .focused($fieldFocused)
                .onSubmit { activate(rows[min(highlighted, rows.count - 1)]) }
            Divider().overlay(TokenColor.border)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        rowView(row, isHighlighted: i == highlighted)
                            .contentShape(Rectangle())
                            .onTapGesture { activate(row) }
                    }
                }
            }
            .frame(height: resultsHeight)
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onExitCommand { model.setPaletteShown(false) }
        .onMoveCommand { direction in
            switch direction {
            case .down: highlighted = min(highlighted + 1, rows.count - 1)
            case .up: highlighted = max(highlighted - 1, 0)
            default: break
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        HStack {
            switch row {
            case .note(let note):
                Text(note.metadata.title.isEmpty ? "Untitled" : note.metadata.title)
                    .font(TokenFont.interface)
                    .foregroundStyle(TokenColor.fg)
                Spacer()
                Text(Slug.dayString(note.metadata.updated))
                    .font(TokenFont.metadata)
                    .foregroundStyle(TokenColor.faint)
            case .newNote:
                Label("New Note", systemImage: "square.and.pencil")
                    .font(TokenFont.interface)
                    .foregroundStyle(TokenColor.fg)
                Spacer()
                Text("Cmd N")
                    .font(TokenFont.metadata)
                    .foregroundStyle(TokenColor.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHighlighted ? TokenColor.accentSoft : .clear)
    }

    private func activate(_ row: Row) {
        switch row {
        case .note(let note): model.select(note.relativePath)
        case .newNote: Task { await model.newNote() }
        }
        model.setPaletteShown(false)
    }
}
