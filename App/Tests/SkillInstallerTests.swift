import Foundation
import Testing
@testable import RustyNoter

@Suite struct SkillInstallerTests {
    /// Every test writes into its own temp directory. Touching the developer's
    /// real ~/.claude from a test is a defect even when the test passes.
    private func makeTempSkillsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installWritesTheSkillAndStatusBecomesCurrent() throws {
        let directory = try makeTempSkillsDirectory()
        let installer = SkillInstaller(skillsDirectory: directory)

        #expect(installer.status(vaultPath: "/Users/gleb/Notes") == .notInstalled)

        try installer.install(vaultPath: "/Users/gleb/Notes")

        let written = try String(
            contentsOf: directory
                .appendingPathComponent("rusty-noter")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8)
        #expect(written.contains("name: rusty-noter"))
        #expect(written.contains("/Users/gleb/Notes"))
        #expect(installer.status(vaultPath: "/Users/gleb/Notes") == .current)
    }

    @Test func statusGoesStaleWhenTheVaultMoves() throws {
        let directory = try makeTempSkillsDirectory()
        let installer = SkillInstaller(skillsDirectory: directory)
        try installer.install(vaultPath: "/Users/gleb/Notes")

        #expect(installer.status(vaultPath: "/Users/gleb/Archive") == .stale)
    }

    @Test func syncRewritesTheStalePathButNeverInstallsUninvited() throws {
        let directory = try makeTempSkillsDirectory()
        let installer = SkillInstaller(skillsDirectory: directory)

        // Not installed: a vault change must not create the skill.
        try installer.sync(vaultPath: "/Users/gleb/Notes")
        #expect(installer.status(vaultPath: "/Users/gleb/Notes") == .notInstalled)

        // Installed: a vault change must keep it pointing at the right place.
        try installer.install(vaultPath: "/Users/gleb/Notes")
        try installer.sync(vaultPath: "/Users/gleb/Archive")
        #expect(installer.status(vaultPath: "/Users/gleb/Archive") == .current)
    }

    @Test func removeDeletesTheSkill() throws {
        let directory = try makeTempSkillsDirectory()
        let installer = SkillInstaller(skillsDirectory: directory)
        try installer.install(vaultPath: "/Users/gleb/Notes")

        try installer.remove()

        #expect(installer.status(vaultPath: "/Users/gleb/Notes") == .notInstalled)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("rusty-noter").path))
        // Removing again is a no-op, not an error.
        try installer.remove()
    }

    @Test func installSurfacesAnErrorWhenTheDirectoryCannotBeWritten() throws {
        // A file where the skills directory should be: creating a subdirectory
        // under it must fail loudly rather than silently doing nothing.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-\(UUID().uuidString)")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let installer = SkillInstaller(skillsDirectory: blocker)

        #expect(throws: (any Error).self) {
            try installer.install(vaultPath: "/Users/gleb/Notes")
        }
    }
}
