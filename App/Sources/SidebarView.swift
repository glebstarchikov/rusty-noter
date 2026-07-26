import SwiftUI
import NoterCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Custom rows, not `List(selection:)`: the system sidebar highlight
        // can't be suppressed or restyled on macOS (same reason the note list
        // is custom), so each row draws its own accent-soft pill and animates
        // it, matching NoteRow for a consistent selected state across panes.
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: "All Notes", systemImage: "doc.text",
                           selected: model.sidebarSelection == .all) {
                    model.sidebarSelection = .all
                }
                SidebarRow(title: "Meetings", systemImage: "waveform",
                           selected: model.sidebarSelection == .meetings) {
                    model.sidebarSelection = .meetings
                }

                if !model.allTags.isEmpty {
                    sectionLabel("Tags")
                    ForEach(model.allTags, id: \.self) { tag in
                        SidebarRow(title: tag, systemImage: "number",
                                   selected: model.sidebarSelection == .tag(tag)) {
                            model.sidebarSelection = .tag(tag)
                        }
                    }
                }

                if !model.topLevelFolders.isEmpty {
                    sectionLabel("Folders")
                    ForEach(model.topLevelFolders, id: \.self) { folder in
                        SidebarRow(title: folder, systemImage: "folder",
                                   selected: model.sidebarSelection == .folder(folder)) {
                            model.sidebarSelection = .folder(folder)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Crafted mono wordmark as the app identity, top of the sidebar.
            // Mono is "the texture of the system" (design.md); lowercase, quiet.
            HStack {
                Text("rusty noter")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .tracking(-0.3)
                    .foregroundStyle(TokenColor.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(TokenColor.faint)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var fill: Color {
        selected ? TokenColor.accentSoft : (hovering ? TokenColor.elevated : .clear)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(selected ? TokenColor.accent : TokenColor.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(TokenColor.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovering = $0 }
        // Mirror NoteRow: clear a stranded hover when selection moves.
        .onChange(of: selected) { _, nowSelected in if !nowSelected { hovering = false } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
