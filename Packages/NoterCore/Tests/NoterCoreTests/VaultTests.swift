import Testing
import Foundation
import Darwin
@testable import NoterCore

/// Kernel-canonical form of a path via POSIX realpath (resolves /var -> /private/var).
private func kernelCanonicalPath(_ path: String) -> String? {
    guard let rp = realpath(path, nil) else { return nil }
    defer { free(rp) }
    return String(cString: rp)
}

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

    @Test func relativePathResolvesVarSymlinkMismatch() throws {
        // Vault created from the Foundation-form temp dir (/var/folders/... on macOS).
        // Built inline (not via makeTempVault) so the pre-canonicalization form survives
        // even after Vault.init canonicalizes root.
        let originalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        let vault = Vault(root: originalDir)

        // Kernel-canonical form (/private/var/...), as FSEvents reports paths.
        // "a.md" is deliberately never created: for existing files standardizedFileURL
        // happens to strip /private, masking the bug; watcher events for deleted or
        // not-yet-visible files hit the real mismatch.
        let canonicalRoot = try #require(kernelCanonicalPath(originalDir.path))
        // Precondition: the mismatch is real on this machine (/var vs /private/var).
        #expect(canonicalRoot != originalDir.standardizedFileURL.path)

        let fromCanonical = URL(fileURLWithPath: canonicalRoot).appendingPathComponent("a.md")
        let fromOriginal = originalDir.appendingPathComponent("a.md")
        #expect(vault.relativePath(of: fromCanonical) == "a.md")
        #expect(vault.relativePath(of: fromOriginal) == "a.md")
    }

    @Test func relativePathOfDeletedFileStillResolves() throws {
        let vault = try makeTempVault()
        let canonicalRoot = try #require(kernelCanonicalPath(vault.root.path))
        // Deleted-file FSEvents case: the file never exists, but its parent dir does.
        let url = URL(fileURLWithPath: canonicalRoot).appendingPathComponent("never-created.md")
        #expect(vault.relativePath(of: url) == "never-created.md")
    }

    @Test func enumerationSkipsDirectoryNamedLikeNote() throws {
        let vault = try makeTempVault()
        try writeFile(vault, "real.md", sampleRaw(title: "Real"))
        try FileManager.default.createDirectory(
            at: vault.root.appendingPathComponent("trap.md", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(try vault.enumerateNoteFiles() == ["real.md"])
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
