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
            Section("Claude Skill") {
                LabeledContent("Status") {
                    Text(skillStatusText)
                        .font(TokenFont.supporting)
                        .foregroundStyle(TokenColor.secondary)
                }
                HStack(spacing: 8) {
                    switch model.skillStatus {
                    case .notInstalled:
                        Button("Install") { model.installSkill() }
                    case .current:
                        Button("Remove", role: .destructive) { model.removeSkill() }
                    case .stale:
                        Button("Update") { model.installSkill() }
                        Button("Remove", role: .destructive) { model.removeSkill() }
                    }
                }
                if let error = model.skillError {
                    Text(error)
                        .font(TokenFont.finePrint)
                        .foregroundStyle(TokenColor.danger)
                }
                Text("Installs a skill at ~/.claude/skills/rusty-noter so Claude can find and write your notes from any session, not just inside the vault folder.")
                    .font(TokenFont.finePrint)
                    .foregroundStyle(TokenColor.faint)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { model.refreshSkillStatus() }
    }

    private var skillStatusText: String {
        switch model.skillStatus {
        case .notInstalled: "Not installed"
        case .current: "Installed · \(model.vaultPathDisplay)"
        case .stale: "Update available"
        }
    }
}
