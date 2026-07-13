import Testing
import Foundation
@testable import NoterCore

@Suite struct VaultTests {
    @Test func isNotePathRules() throws {
        let vault = try makeTempVault()
        #expect(vault.isNotePath("2026-07-13-hello.md"))
        #expect(vault.isNotePath("meetings/2026-07-13-standup.md"))
        #expect(!vault.isNotePath("INDEX.md"))
        #expect(!vault.isNotePath("CLAUDE.md"))
        #expect(!vault.isNotePath("AGENTS.md"))
        #expect(!vault.isNotePath("notes.txt"))
        #expect(!vault.isNotePath(".hidden.md"))
        #expect(!vault.isNotePath(".obsidian/config.md"))
        #expect(!vault.isNotePath("meetings/audio/x.m4a"))
        // Generated names are only special at the root:
        #expect(vault.isNotePath("subfolder/INDEX.md"))
    }

    @Test func enumerationFindsNotesRecursively() throws {
        let vault = try makeTempVault()
        try writeFile(vault, "a.md", sampleRaw(title: "A"))
        try writeFile(vault, "meetings/b.md", sampleRaw(title: "B"))
        try writeFile(vault, "INDEX.md", "# Notes Index\n")
        try writeFile(vault, ".hidden/c.md", sampleRaw(title: "C"))
        try writeFile(vault, "meetings/audio/x.m4a", "not audio really")
        let found = try vault.enumerateNoteFiles()
        #expect(found == ["a.md", "meetings/b.md"])
    }

    @Test func relativePathRoundTrip() throws {
        let vault = try makeTempVault()
        let url = vault.noteURL("meetings/b.md")
        #expect(vault.relativePath(of: url) == "meetings/b.md")
        #expect(vault.relativePath(of: URL(fileURLWithPath: "/etc/passwd")) == nil)
    }

    @Test func snippetStripsMarkdown() throws {
        let meta = NoteMetadata(
            title: "T", created: .now, updated: .now)
        let note = Note(
            relativePath: "a.md", metadata: meta,
            body: "\n\n## **Bold** heading with [link](https://x.com)\nmore\n")
        #expect(note.snippet == "Bold heading with link")
    }
}
