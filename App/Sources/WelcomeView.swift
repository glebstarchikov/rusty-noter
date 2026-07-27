import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text("Rusty Noter keeps your notes as plain markdown files in a folder you own.")
                .font(TokenFont.interface)
                .foregroundStyle(TokenColor.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 12) {
                Button("Create ~/Notes") {
                    Task {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Notes")
                        try? FileManager.default.createDirectory(
                            at: url, withIntermediateDirectories: true)
                        await model.setVault(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSwitchingVault)
                Button("Choose Folder") {
                    Task {
                        if let url = AppModel.chooseVaultFolder() {
                            await model.setVault(url)
                        }
                    }
                }
                .disabled(model.isSwitchingVault)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TokenColor.bg)
    }
}
