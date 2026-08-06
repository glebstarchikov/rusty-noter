import Testing
import Foundation
@testable import NoterCore

@Suite struct NotesStoreTests {
    @Test func createWritesFileAndCaches() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.create(title: "API pricing ideas",
                                          now: Date.iso8601Local("2026-07-13T10:00:00+02:00")!)
        #expect(note.relativePath == "2026-07-13-api-pricing-ideas.md")
        #expect(note.metadata.title == "API pricing ideas")
        let onDisk = try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8)
        #expect(onDisk.hasPrefix("---\n"))
        let cached = await store.note(at: note.relativePath)
        #expect(cached == note)
    }

    @Test func createAvoidsFilenameCollision() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let now = Date.iso8601Local("2026-07-13T10:00:00+02:00")!
        let a = try await store.create(title: "Same", now: now)
        let b = try await store.create(title: "Same", now: now)
        #expect(a.relativePath != b.relativePath)
        #expect(b.relativePath.hasSuffix("-2.md"))
    }

    @Test func updateBodyBumpsUpdatedAndPersists() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let created = Date.iso8601Local("2026-07-13T10:00:00+02:00")!
        let later = Date.iso8601Local("2026-07-13T11:00:00+02:00")!
        let note = try await store.create(title: "T", now: created)
        let updated = try await store.updateBody(note.relativePath, body: "new body\n", now: later)
        #expect(updated.body == "new body\n")
        #expect(updated.metadata.updated == later)
        #expect(updated.metadata.created == created)
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.body == "new body\n")
    }

    @Test func startMeetingCreatesARecordingNote() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let now = Date.iso8601Local("2026-08-02T14:30:00+02:00")!

        let note = try await store.startMeeting(title: "Standup", now: now)

        #expect(note.metadata.type == .meeting)
        #expect(note.metadata.status == .recording)
        #expect(note.metadata.audio == nil)
        // The on-disk file must carry the marker: it is what crash recovery and
        // the Claude skill both key on.
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.metadata.status == .recording)
        #expect(reparsed.metadata.type == .meeting)
    }

    @Test func finishMeetingClearsTheRecordingMarkerAndRecordsTheAudio() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let start = Date.iso8601Local("2026-08-02T14:30:00+02:00")!
        let end = Date.iso8601Local("2026-08-02T15:05:00+02:00")!
        let note = try await store.startMeeting(title: "Standup", now: start)

        let done = try await store.finishMeeting(
            note.relativePath,
            audio: "audio/2026-08-02-standup.m4a",
            duration: "00:35:00",
            now: end)

        #expect(done.metadata.status == nil)
        #expect(done.metadata.audio == "audio/2026-08-02-standup.m4a")
        #expect(done.metadata.duration == "00:35:00")
        #expect(done.metadata.updated == end)
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.metadata.status == nil)
        #expect(reparsed.metadata.audio == "audio/2026-08-02-standup.m4a")
    }

    /// A meeting note is still a note: it must be found by enumeration, and the
    /// audio file next to it must NOT be. Guards the exclusion the whole design
    /// leans on -- a future change to isNotePath would otherwise break search
    /// and the sidebar in a way that looks unrelated to its cause.
    @Test func audioFilesAreNeverTreatedAsNotes() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.startMeeting(title: "Standup", now: .now)

        let audioDirectory = vault.root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
        try Data("not really audio".utf8).write(
            to: audioDirectory.appendingPathComponent("2026-08-02-standup.m4a"))

        let files = try vault.enumerateNoteFiles()
        #expect(files.contains(note.relativePath))
        #expect(!files.contains { $0.hasSuffix(".m4a") })
        #expect(!vault.isNotePath("audio/2026-08-02-standup.m4a"))
    }

    @Test func updateDraftPersistsTitleAndBodyInOneRevision() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let created = Date.iso8601Local("2026-07-13T10:00:00+02:00")!
        let later = Date.iso8601Local("2026-07-13T11:00:00+02:00")!
        let note = try await store.create(title: "Original", now: created)

        let updated = try await store.updateDraft(
            note.relativePath,
            title: "Combined draft",
            body: "title and body land together\n",
            now: later)

        #expect(updated.metadata.title == "Combined draft")
        #expect(updated.body == "title and body land together\n")
        #expect(updated.metadata.updated == later)
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.metadata.title == "Combined draft")
        #expect(reparsed.body == "title and body land together\n")
        #expect(reparsed.metadata.updated == later)
    }

    @Test func loadAllParsesGoodAndSalvagesBroken() async throws {
        let vault = try makeTempVault()
        try writeFile(vault, "good.md", sampleRaw(title: "Good"))
        try writeFile(vault, "broken.md", "no frontmatter at all\n")
        let store = NotesStore(vault: vault)
        let notes = await store.loadAll()
        #expect(notes.count == 2)
        let broken = notes.first { $0.relativePath == "broken.md" }!
        #expect(broken.metadata.title == "broken")
        #expect(broken.body == "no frontmatter at all\n")
        let unparseable = await store.unparseablePaths
        #expect(unparseable == ["broken.md"])
    }

    @Test func brokenFileIsNeverRewritten() async throws {
        let vault = try makeTempVault()
        let original = "no frontmatter at all\n"
        try writeFile(vault, "broken.md", original)
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        await #expect(throws: NotesStoreError.refusingToRewriteUnparseable) {
            _ = try await store.updateBody("broken.md", body: "x")
        }
        #expect(try String(contentsOf: vault.noteURL("broken.md"), encoding: .utf8) == original)
    }

    @Test func reloadFromDiskPicksUpExternalEdit() async throws {
        let vault = try makeTempVault()
        try writeFile(vault, "a.md", sampleRaw(title: "Before"))
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        try writeFile(vault, "a.md", sampleRaw(title: "After"))
        let reloaded = try await store.reloadFromDisk("a.md")
        #expect(reloaded?.metadata.title == "After")
        #expect(await store.note(at: "a.md")?.metadata.title == "After")
        // Vanished file:
        try FileManager.default.removeItem(at: vault.noteURL("a.md"))
        #expect(try await store.reloadFromDisk("a.md") == nil)
        #expect(await store.note(at: "a.md") == nil)
    }

    @Test func echoJournalTracksSelfWrites() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.create(title: "Echo")
        // Just-written: on-disk bytes equal what we wrote -> our own echo.
        #expect(await store.isSelfWriteEcho(note.relativePath))
        // No record for an unrelated path.
        #expect(await !store.isSelfWriteEcho("other.md"))
        // An EXTERNAL write of DIFFERENT content to the same path is NOT an echo,
        // even immediately (content differs), so it will be processed.
        _ = try await store.updateBody(note.relativePath, body: "ours\n")
        try writeFile(vault, note.relativePath, sampleRaw(title: "Echo", body: "theirs\n"))
        #expect(await !store.isSelfWriteEcho(note.relativePath))
    }

    @Test func nonUTF8FileIsSalvagedNotHidden() async throws {
        let vault = try makeTempVault()
        // "---\n" followed by bytes that are invalid UTF-8 (0xFF, 0xFE, 0xFA).
        let original = Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0xFA, 0x0A])
        let url = vault.noteURL("bad.md")
        try original.write(to: url)
        let store = NotesStore(vault: vault)
        let notes = await store.loadAll()
        #expect(notes.count == 1)
        #expect(notes.first?.metadata.title == "bad")
        #expect(await store.unparseablePaths == ["bad.md"])
        await #expect(throws: NotesStoreError.refusingToRewriteUnparseable) {
            _ = try await store.updateBody("bad.md", body: "x")
        }
        // Salvage contract: on-disk bytes stay untouched, byte for byte.
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func updateBodyOnMissingNoteThrowsNoteNotFound() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        await #expect(throws: NotesStoreError.noteNotFound("ghost.md")) {
            _ = try await store.updateBody("ghost.md", body: "x")
        }
    }

    @Test func salvageTitleStripsOnlyTrailingExtension() async throws {
        let vault = try makeTempVault()
        try writeFile(vault, "notes.md.bak.md", "plain text, no frontmatter\n")
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        #expect(await store.note(at: "notes.md.bak.md")?.metadata.title == "notes.md.bak")
    }

    @Test func removeClearsEchoJournal() async throws {
        // NB: does not pre-check isSelfWriteEcho before remove() — that call's own
        // "confirmed echo evicts the record" side effect would clear the journal
        // itself, making the post-remove() check pass whether or not remove() does
        // its job. Checking only once, after remove(), keeps this a faithful test:
        // the file is still on disk with matching bytes (remove() only evicts the
        // in-memory cache, it doesn't delete anything), so isSelfWriteEcho would
        // still report an echo unless remove() also pruned selfWriteContent.
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.create(title: "Echo")
        await store.remove(note.relativePath)
        #expect(await !store.isSelfWriteEcho(note.relativePath))  // journal entry gone
    }

    @Test func updateTitleRewritesFrontmatterKeepsFilename() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.create(title: "Original")
        let renamed = try await store.updateTitle(note.relativePath, title: "Better title")
        #expect(renamed.relativePath == note.relativePath) // filename stable
        #expect(renamed.metadata.title == "Better title")
        let onDisk = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(onDisk.metadata.title == "Better title")
    }
}
