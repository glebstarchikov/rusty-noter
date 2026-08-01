import Foundation
import NoterCore

/// Installs the generated Claude skill into the user's `~/.claude/skills`.
///
/// Lives in the App layer rather than NoterCore: it writes outside the vault,
/// and NoterCore's remit is the vault alone.
struct SkillInstaller {
    enum Status: Equatable {
        case notInstalled
        case current
        case stale
    }

    /// Namespaced so overwriting is always safe. A generic `notes` directory
    /// could belong to an unrelated skill the user wrote themselves.
    static let skillName = "rusty-noter"

    /// Injected so tests never touch the developer's real ~/.claude.
    let skillsDirectory: URL

    init(skillsDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills")) {
        self.skillsDirectory = skillsDirectory
    }

    private var skillDirectory: URL {
        skillsDirectory.appendingPathComponent(Self.skillName)
    }

    private var skillURL: URL {
        skillDirectory.appendingPathComponent("SKILL.md")
    }

    /// Defined by exact comparison against a fresh render, so a moved vault and
    /// an app update that changed the conventions both surface as `.stale`
    /// through one mechanism, with no version field to maintain.
    func status(vaultPath: String) -> Status {
        guard let existing = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return .notInstalled
        }
        return existing == AgentDocsWriter.renderSkill(vaultPath: vaultPath)
            ? .current
            : .stale
    }

    func install(vaultPath: String) throws {
        try FileManager.default.createDirectory(
            at: skillDirectory, withIntermediateDirectories: true)
        try AgentDocsWriter.renderSkill(vaultPath: vaultPath)
            .write(to: skillURL, atomically: true, encoding: .utf8)
    }

    /// Keeps an already-installed skill pointing at the current vault. Does
    /// nothing when the skill is not installed: changing a folder must not
    /// install uninvited into the user's ~/.claude.
    func sync(vaultPath: String) throws {
        guard status(vaultPath: vaultPath) == .stale else { return }
        try install(vaultPath: vaultPath)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: skillDirectory.path) else { return }
        try FileManager.default.removeItem(at: skillDirectory)
    }
}
