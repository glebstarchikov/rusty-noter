import SwiftUI
import NoterCore

@MainActor @Observable
final class AppModel {
    var notes: [Note] = []
    var selectedPath: String?
    var searchQuery: String = ""
    var searchHits: [String]? = nil   // nil = no active search
    var needsWelcome = false

    private(set) var coordinator: VaultCoordinator?

    static let vaultPathKey = "vaultPath"

    var vaultURL: URL {
        if let stored = UserDefaults.standard.string(forKey: Self.vaultPathKey) {
            return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Notes")
    }

    var vaultPathDisplay: String { vaultURL.path }

    var visibleNotes: [Note] {
        guard let hits = searchHits else { return notes }
        let order = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1, $0) })
        return notes.filter { order[$0.relativePath] != nil }
            .sorted { (order[$0.relativePath] ?? 0) < (order[$1.relativePath] ?? 0) }
    }

    func bootstrap() async {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            needsWelcome = true
            return
        }
        needsWelcome = false
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RustyNoter")
        do {
            let coordinator = try VaultCoordinator(
                vault: Vault(root: vaultURL),
                indexDatabasePath: appSupport.appendingPathComponent("index.db").path)
            self.coordinator = coordinator
            self.notes = await coordinator.start()
            let stream = coordinator.updates
            Task { [weak self] in
                for await snapshot in stream {
                    self?.notes = snapshot
                    await self?.runSearch()
                }
            }
        } catch {
            // Index cache is disposable: wipe and retry once (spec section 11).
            try? FileManager.default.removeItem(
                at: appSupport.appendingPathComponent("index.db"))
            if let retry = try? VaultCoordinator(
                vault: Vault(root: vaultURL),
                indexDatabasePath: appSupport.appendingPathComponent("index.db").path) {
                self.coordinator = retry
                self.notes = await retry.start()
            }
        }
    }

    func newNote() async {
        guard let coordinator else { return }
        if let note = try? await coordinator.createNote(title: "Untitled") {
            selectedPath = note.relativePath
        }
    }

    func select(_ path: String?) { selectedPath = path }

    func runSearch() async {
        guard let coordinator, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = nil
            return
        }
        searchHits = await coordinator.search(searchQuery)
    }
}
