import Testing
import Foundation
@testable import NoterCore

@Suite struct VaultCoordinatorTests {
    func makeCoordinator(_ vault: Vault) throws -> VaultCoordinator {
        try VaultCoordinator(vault: vault, indexDatabasePath: nil,
                             watcherDebounce: 0.15, indexMdDelay: 0.2)
    }

    @Test(.timeLimit(.minutes(1)))
    func externalEditReachesUpdatesIndexAndIndexMd() async throws {
        let vault = try makeTempVault()
        let coordinator = try makeCoordinator(vault)
        let initial = await coordinator.start()
        #expect(initial.isEmpty)
        var iterator = coordinator.updates.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(500)) // let FSEvents arm

        let deadline = ContinuousClock.now
        try writeFile(vault, "external.md", sampleRaw(title: "From Claude", tags: ["agent"]))

        let snapshot = await iterator.next()
        let elapsed = ContinuousClock.now - deadline
        #expect(elapsed < .seconds(1))                     // spec 13.1 acceptance
        #expect(snapshot?.contains { $0.metadata.title == "From Claude" } == true)

        #expect(await coordinator.search("claude") == ["external.md"])

        try await Task.sleep(for: .milliseconds(600))      // indexMdDelay + write
        let indexMd = try String(
            contentsOf: vault.root.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(indexMd.contains("From Claude"))
        await coordinator.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func appOriginatedEditsIndexInlineAndSkipEcho() async throws {
        let vault = try makeTempVault()
        let coordinator = try makeCoordinator(vault)
        _ = await coordinator.start()
        try await Task.sleep(for: .milliseconds(500))

        let note = try await coordinator.createNote(title: "Mine")
        #expect(await coordinator.search("mine") == [note.relativePath])

        _ = try await coordinator.updateBody(note.relativePath, body: "hello searchable body\n")
        #expect(await coordinator.search("searchable") == [note.relativePath])

        // Let any echo batch flow through; state must remain consistent.
        try await Task.sleep(for: .seconds(1))
        let cached = await coordinator.note(at: note.relativePath)
        #expect(cached?.body == "hello searchable body\n")
        await coordinator.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func externalDeleteRemovesEverywhere() async throws {
        let vault = try makeTempVault()
        try writeFile(vault, "doomed.md", sampleRaw(title: "Doomed"))
        let coordinator = try makeCoordinator(vault)
        let initial = await coordinator.start()
        #expect(initial.count == 1)
        var iterator = coordinator.updates.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(500))

        try FileManager.default.removeItem(at: vault.noteURL("doomed.md"))
        let snapshot = await iterator.next()
        #expect(snapshot?.isEmpty == true)
        #expect(await coordinator.search("doomed") == [])
        await coordinator.stop()
    }

    @Test func startWritesAgentDocs() async throws {
        let vault = try makeTempVault()
        let coordinator = try makeCoordinator(vault)
        _ = await coordinator.start()
        #expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent("CLAUDE.md").path))
        #expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent("AGENTS.md").path))
        #expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent("INDEX.md").path))
        await coordinator.stop()
    }
}
