import SwiftUI
import NoterCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section {
                Label("All Notes", systemImage: "doc.text")
                    .tag(SidebarSelection.all)
                Label("Meetings", systemImage: "waveform")
                    .tag(SidebarSelection.meetings)
            }
            if !model.allTags.isEmpty {
                Section("Tags") {
                    ForEach(model.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "number")
                            .tag(SidebarSelection.tag(tag))
                    }
                }
            }
            if !model.topLevelFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.topLevelFolders, id: \.self) { folder in
                        Label(folder, systemImage: "folder")
                            .tag(SidebarSelection.folder(folder))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
}
