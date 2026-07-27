import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Vault") {
                LabeledContent("Notes folder") {
                    Text(model.vaultPathDisplay)
                        .font(TokenFont.supporting.monospaced())
                        .foregroundStyle(TokenColor.secondary)
                        .textSelection(.enabled)
                }
                Button("Change Folder") {
                    Task {
                        if let url = AppModel.chooseVaultFolder() {
                            await model.setVault(url)
                        }
                    }
                }
                .disabled(model.isSwitchingVault)
                Text("The app generates INDEX.md, CLAUDE.md, and AGENTS.md at the folder root so AI agents can navigate your notes.")
                    .font(TokenFont.finePrint)
                    .foregroundStyle(TokenColor.faint)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
