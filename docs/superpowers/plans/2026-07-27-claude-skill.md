# Claude Skill (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude able to find, read, and write notes in the Rusty Noter vault from any directory, via a skill the app installs and keeps current.

**Architecture:** `AgentDocsWriter` grows a recipe-mode split and a third output, `renderSkill(vaultPath:)`, so the skill and the vault's `CLAUDE.md`/`AGENTS.md` are generated from one source and cannot drift. A new App-layer `SkillInstaller` writes that output to `~/.claude/skills/rusty-noter/SKILL.md`, reports install status, and rewrites the path when the vault moves.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-27-claude-skill-design.md`

## Global Constraints

- **Deployment target:** macOS 26.0. Swift 6.0 strict concurrency. App-layer types touching UI state are `@MainActor`.
- **No new dependencies.**
- **Files are truth.** The skill is a generated artifact, never hand-edited in place.
- **No `try?` on anything a user needs to know about.** Install/remove failures surface in Settings with the underlying error. A swallowed error is what made Pin and Delete look like dead UI for days.
- **Install location:** `~/.claude/skills/rusty-noter/SKILL.md`. Namespaced so overwriting is always safe. Never write to `~/.claude/skills/notes/`.
- **`.inVault` output must keep its current meaning** — the vault docs' recipes stay relative. Only the `.remote` (skill) variant is path-qualified.
- **New files require `xcodegen generate`** before building.
- **Build:** `xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug build`
- **Core tests:** `swift test --package-path Packages/NoterCore` (80 currently green)
- **App tests:** `xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS'` (4 currently green)
- **App path** (`$APP`): `/Users/glebstarcikov/Library/Developer/Xcode/DerivedData/RustyNoter-bccdtssewntkcffozkbztbtgmgou/Build/Products/Debug/RustyNoter.app`
- **Always rebuild AND relaunch before judging behavior:** `killall RustyNoter 2>/dev/null; open -n "$APP"`
- **Never write to the developer's real `~/.claude` from a test.** `SkillInstaller` takes an injected directory; tests pass a temporary one. A test that touches the real path is a defect even if it passes.

---

## File Structure

| File | Responsibility |
|---|---|
| `Packages/NoterCore/Sources/NoterCore/AgentDocsWriter.swift` (modify) | Recipe-mode split; `renderSkill(vaultPath:)` |
| `Packages/NoterCore/Tests/NoterCoreTests/AgentDocsWriterTests.swift` (modify) | Skill content tests, including the negative path-qualification test |
| `App/Sources/SkillInstaller.swift` (create) | Install / status / sync / remove against `~/.claude/skills` |
| `App/Tests/SkillInstallerTests.swift` (create) | Installer behavior against a temp directory |
| `App/Sources/AppModel.swift` (modify) | Skill status + error state, actions, sync on vault move |
| `App/Sources/SettingsView.swift` (modify) | Claude Skill section |

---

### Task 1: Recipe-mode split and `renderSkill`

Pure string generation, so this task is real TDD.

**Files:**
- Modify: `Packages/NoterCore/Sources/NoterCore/AgentDocsWriter.swift`
- Test: `Packages/NoterCore/Tests/NoterCoreTests/AgentDocsWriterTests.swift`

**Interfaces:**
- Produces:
  - `AgentDocsWriter.RecipeMode` — `public enum { case inVault, remote }`
  - `AgentDocsWriter.renderSkill(vaultPath: String) -> String`
  - `AgentDocsWriter.render(vaultPath:)` — unchanged signature and meaning

- [ ] **Step 1: Write the failing tests**

Add to `Packages/NoterCore/Tests/NoterCoreTests/AgentDocsWriterTests.swift`, inside the existing `@Suite struct AgentDocsWriterTests`:

```swift
    /// Every `rg` recipe in the skill must carry the absolute vault path.
    /// This is the negative test that matters: an unqualified recipe run from
    /// another repo silently searches THAT repo and returns confident, wrong
    /// answers -- no error, no signal. Asserting "the path appears somewhere"
    /// would pass even with one stale relative recipe left in.
    @Test func everySkillRecipeIsPathQualified() {
        let vaultPath = "/Users/gleb/Notes"
        let skill = AgentDocsWriter.renderSkill(vaultPath: vaultPath)
        let recipes = skill
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rg ") }

        #expect(!recipes.isEmpty)
        for recipe in recipes {
            #expect(recipe.contains(vaultPath),
                    "unqualified recipe would search the wrong tree: \(recipe)")
        }
    }

    /// The in-vault docs are read by an agent already sitting in the vault,
    /// so their recipes must stay relative -- the mode split must not leak
    /// absolute paths into CLAUDE.md/AGENTS.md.
    @Test func inVaultRecipesStayRelative() {
        let vaultPath = "/Users/gleb/Notes"
        let doc = AgentDocsWriter.render(vaultPath: vaultPath)
        let recipes = doc
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rg ") }

        #expect(!recipes.isEmpty)
        for recipe in recipes {
            #expect(!recipe.contains(vaultPath),
                    "in-vault recipe should not be path-qualified: \(recipe)")
        }
    }

    @Test func skillCarriesFrontmatterAndTriggerLanguage() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        #expect(skill.hasPrefix("---\n"))
        #expect(skill.contains("name: rusty-noter"))
        #expect(skill.contains("description:"))
        // Trigger phrases the description must claim, and the negative clause
        // that keeps it from firing on unrelated questions.
        #expect(skill.contains("my notes"))
        #expect(skill.contains("note this down"))
        #expect(skill.contains("Not for general questions"))
    }

    @Test func skillTellsTheAgentItIsElsewhereAndWhatToDoIfTheVaultIsGone() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        #expect(skill.contains("not in that directory"))
        #expect(skill.contains("absolute paths"))
        #expect(skill.contains("does not exist"))
        // Orientation order is what makes one INDEX read + one rg achievable.
        #expect(skill.contains("/Users/gleb/Notes/INDEX.md"))
    }

    @Test func skillDocumentsTheSameFrontmatterContractAsTheVaultDocs() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        for key in ["title:", "type:", "created:", "updated:", "tags:"] {
            #expect(skill.contains(key))
        }
        #expect(skill.contains("status: recording"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path Packages/NoterCore 2>&1 | tail -20
```

Expected: compile error — `renderSkill` does not exist. That counts as the red state for the new tests; `inVaultRecipesStayRelative` should pass once it compiles, since today's recipes are already relative.

- [ ] **Step 3: Refactor the renderer and add `renderSkill`**

Replace the whole body of `Packages/NoterCore/Sources/NoterCore/AgentDocsWriter.swift` with:

```swift
import Foundation

public enum AgentDocsWriter {
    /// Where the agent reading these conventions is running.
    ///
    /// `.inVault` docs sit in the vault, so relative globs are correct.
    /// `.remote` (the skill) runs from an arbitrary directory, where an
    /// unqualified `rg` would silently search that directory instead and
    /// return confident, wrong answers -- so every recipe is path-qualified.
    public enum RecipeMode {
        case inVault
        case remote
    }

    public static func render(vaultPath: String) -> String {
        """
        # Notes Vault

        This folder is a notes vault managed by Rusty Noter at `\(vaultPath)`.
        It is also edited directly by humans and AI agents. Plain markdown
        files are the single source of truth.

        \(conventions(vaultPath: vaultPath, mode: .inVault))
        """
    }

    /// The same conventions, packaged as a Claude skill so an agent working in
    /// some other directory can still reach the vault.
    public static func renderSkill(vaultPath: String) -> String {
        """
        ---
        name: rusty-noter
        description: >
          Search, read, and write Gleb's notes in the Rusty Noter vault at
          \(vaultPath). Use when the user refers to their own notes or vault --
          "my notes", "did I write about X", "what did I note in the standup",
          "note this down", "add to my notes" -- or names a specific note or
          meeting. Not for general questions that don't concern their notes.
        ---

        # Rusty Noter vault

        Gleb's notes live at `\(vaultPath)`.
        You are almost certainly not in that directory -- always use absolute paths.

        If `\(vaultPath)` does not exist, say so and stop. Do not search the
        filesystem for a replacement notes folder: a wrong vault is worse than
        no vault.

        \(conventions(vaultPath: vaultPath, mode: .remote))
        """
    }

    /// Shared conventions. One source of truth for the vault docs and the
    /// skill, so the frontmatter contract cannot drift between them as the
    /// note format grows.
    static func conventions(vaultPath: String, mode: RecipeMode) -> String {
        let indexPath = mode == .remote ? "\(vaultPath)/INDEX.md" : "INDEX.md"
        // Appended to every recipe so a remote search cannot hit the wrong tree.
        let scope = mode == .remote ? " \(vaultPath)" : ""
        let excludes = "--glob '!INDEX.md' --glob '!CLAUDE.md' --glob '!AGENTS.md'"

        return """
        ## Orient instantly

        Read `\(indexPath)` first: one table row per note (updated date, title,
        type, tags, path), newest first. One read gives you the full map. Fall
        back to ripgrep only if the index does not answer the question.

        ## Find content

        Prefer ripgrep. Useful recipes:

        ~~~bash
        # notes mentioning a word
        rg -il "pricing" --glob "*.md"\(scope)
        # notes with a tag
        rg -l "^tags: .*standup" --glob "*.md" \(excludes)\(scope)
        # all meeting notes
        rg -l "^type: meeting" --glob "*.md" \(excludes)\(scope)
        # meeting happening RIGHT NOW
        rg -l "^status: recording" --glob "*.md" \(excludes)\(scope)
        ~~~

        ## Note format

        Every note is markdown with YAML frontmatter:

        ~~~yaml
        ---
        title: Standup with Anna
        type: meeting            # note | meeting
        created: 2026-07-11T09:30:00+02:00
        updated: 2026-07-11T09:55:12+02:00
        tags: [work, standup]
        ---
        ~~~

        Meeting notes add `audio:` (relative path) and `duration:`. Filenames
        are `YYYY-MM-DD-slug.md`.

        ## Writing rules

        - Include complete frontmatter when creating a note; set `updated`
          (ISO 8601 with offset) whenever you edit one.
        - A note containing `status: recording` is a LIVE meeting being
          captured right now. Treat it as read-only; its transcript grows
          every few seconds, so re-read it for the latest.
        - Never edit `INDEX.md`, `CLAUDE.md`, or `AGENTS.md`: they are
          generated and will be overwritten.
        - Do not delete notes unless the human explicitly asks.
        """
    }

    public static func writeIfMissingOrStale(to vault: Vault) throws {
        let content = render(vaultPath: vault.root.path)
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let url = vault.root.appendingPathComponent(name)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if existing != content {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
```

Note: the recipe comments moved above their commands. Inline trailing comments cannot stay aligned once a variable-length path is appended, and misaligned trailing comments are harder to read than labelled lines. `CLAUDE.md` and `AGENTS.md` will be rewritten once in every vault on next launch, which `writeIfMissingOrStale` already handles.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --package-path Packages/NoterCore 2>&1 | tail -5
```

Expected: all pass, 85 tests (80 existing + 5 new). The two pre-existing `AgentDocsWriter` tests must still pass — they assert the frontmatter keys and the write/skip behavior, both preserved.

- [ ] **Step 5: Commit**

```bash
git add Packages/NoterCore
git commit -m "feat(core): generate the Claude skill from the vault conventions

Adds a recipe mode to AgentDocsWriter: relative globs for the in-vault docs,
path-qualified for the skill, which runs from an arbitrary directory where an
unqualified rg would silently search that directory instead.

renderSkill emits the same conventions as CLAUDE.md/AGENTS.md with skill
frontmatter, a location preamble and a stale-vault rule, so the two cannot
drift as the note format grows."
```

---

### Task 2: `SkillInstaller`

**Files:**
- Create: `App/Sources/SkillInstaller.swift`
- Test: `App/Tests/SkillInstallerTests.swift`

**Interfaces:**
- Consumes: `AgentDocsWriter.renderSkill(vaultPath:)` (Task 1)
- Produces:
  - `SkillInstaller.Status` — `enum { case notInstalled, current, stale }`, `Equatable`
  - `SkillInstaller.init(skillsDirectory: URL = <~/.claude/skills>)`
  - `status(vaultPath: String) -> Status`
  - `install(vaultPath: String) throws`
  - `sync(vaultPath: String) throws`
  - `remove() throws`

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/SkillInstallerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "error:|✘|TEST FAILED" | head
```

Expected: compile failure — `SkillInstaller` does not exist.

- [ ] **Step 3: Implement `SkillInstaller`**

Create `App/Sources/SkillInstaller.swift`:

```swift
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
    /// an app update that changed the conventions both surface as "stale"
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "✔|✘|error:|TEST SUCCEEDED|TEST FAILED|Test run with" | tail -12
```

Expected: `TEST SUCCEEDED`, 9 tests (4 existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/SkillInstaller.swift App/Tests/SkillInstallerTests.swift
git commit -m "feat(app): install and track the generated Claude skill

Writes SKILL.md to ~/.claude/skills/rusty-noter/, namespaced so overwriting
cannot clobber an unrelated user skill. Status is an exact comparison against a
fresh render, so a moved vault and a changed convention both read as stale
without a version field. sync() only rewrites an already-installed skill:
changing a vault folder must not install uninvited."
```

---

### Task 3: Settings section and vault-move sync

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/SettingsView.swift`

**Interfaces:**
- Consumes: `SkillInstaller` (Task 2)
- Produces on `AppModel`:
  - `skillStatus: SkillInstaller.Status`
  - `skillError: String?`
  - `refreshSkillStatus()`, `installSkill()`, `removeSkill()`

- [ ] **Step 1: Add skill state and actions to `AppModel`**

Add these stored properties to `AppModel`, next to `isSwitchingVault`:

```swift
    private(set) var skillStatus: SkillInstaller.Status = .notInstalled
    private(set) var skillError: String?
```

Add these methods to `AppModel`:

```swift
    func refreshSkillStatus() {
        skillStatus = SkillInstaller().status(vaultPath: vaultURL.path)
    }

    func installSkill() {
        do {
            try SkillInstaller().install(vaultPath: vaultURL.path)
            skillError = nil
        } catch {
            // Surfaced in Settings: an install that silently does nothing
            // leaves the user wondering why Claude can't find their notes.
            skillError = error.localizedDescription
        }
        refreshSkillStatus()
    }

    func removeSkill() {
        do {
            try SkillInstaller().remove()
            skillError = nil
        } catch {
            skillError = error.localizedDescription
        }
        refreshSkillStatus()
    }

    /// Keeps an installed skill pointing at the current vault after a move.
    private func syncSkill() {
        do {
            try SkillInstaller().sync(vaultPath: vaultURL.path)
            skillError = nil
        } catch {
            skillError = error.localizedDescription
        }
        refreshSkillStatus()
    }
```

In `bootstrap()`, add as the last line of the method:

```swift
        refreshSkillStatus()
```

In `setVault(_:)`, add immediately after the `await bootstrap()` call:

```swift
        syncSkill()
```

- [ ] **Step 2: Add the Claude Skill section to `SettingsView`**

In `App/Sources/SettingsView.swift`, add a second `Section` inside the existing `Form`, after the `Section("Vault")` block:

```swift
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
```

Add this computed property to `SettingsView`, after `body`:

```swift
    private var skillStatusText: String {
        switch model.skillStatus {
        case .notInstalled: "Not installed"
        case .current: "Installed · \(model.vaultPathDisplay)"
        case .stale: "Update available"
        }
    }
```

Add `.onAppear { model.refreshSkillStatus() }` to the `Form`, after `.frame(width: 480)`.

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the Settings flow by hand**

```bash
killall RustyNoter 2>/dev/null; open -n "$APP"
```

Open Settings (⌘,) and check each transition:

| Check | Expected |
|---|---|
| Before installing | Status reads "Not installed", one Install button |
| Click Install | Status becomes "Installed · /Users/glebstarcikov/Notes"; Remove appears |
| `cat ~/.claude/skills/rusty-noter/SKILL.md` | Frontmatter present, vault path baked in, recipes path-qualified |
| Reopen Settings | Still "Installed" (status survives a reopen) |
| Click Remove | Status returns to "Not installed"; the directory is gone |

Then verify the sync path: install the skill, use **Change Folder** to point at a different directory, and confirm `SKILL.md` now contains the new path without you re-installing.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/AppModel.swift App/Sources/SettingsView.swift
git commit -m "feat(app): Claude Skill section in Settings

Install, update and remove the skill, with the vault path it points at shown
inline and any failure surfaced rather than swallowed. Changing the vault folder
rewrites an installed skill so it never points at a vault that moved."
```

---

### Task 4: Acceptance verification

The spec's phase-2 acceptance bar, verified against real notes. No code expected.

**Prerequisite:** the vault must contain real notes. It currently holds only `INDEX.md`, `CLAUDE.md`, and `AGENTS.md`. Restore notes from the Trash (Finder → Put Back) or create several covering distinct topics before starting.

- [ ] **Step 1: Confirm the full suite is green**

```bash
swift test --package-path Packages/NoterCore 2>&1 | tail -1
swift test --package-path Packages/NoterEditor 2>&1 | tail -1
xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED"
```

Expected: 85 NoterCore, 93 NoterEditor, 9 App, all passing.

- [ ] **Step 2: Verify the skill on disk**

```bash
head -20 ~/.claude/skills/rusty-noter/SKILL.md
grep -c "^rg " ~/.claude/skills/rusty-noter/SKILL.md
grep "^rg " ~/.claude/skills/rusty-noter/SKILL.md | grep -vc "$HOME/Notes" || echo "all recipes path-qualified"
```

Expected: frontmatter with `name: rusty-noter`; four recipes; zero unqualified.

- [ ] **Step 3: Run the acceptance test in a fresh Claude Code session**

From a directory that is **not** the vault (this repo is fine), start a new Claude Code session and ask a question naming a topic that exists in a note — for example "find my note about X".

| Check | Expected |
|---|---|
| The skill is picked up | Claude reaches for the vault without being told where it is |
| Efficiency | One `INDEX.md` read plus at most one `rg` |
| Correct answer | The right note is found and its content reported |
| Write conventions | Ask it to add a note; the file has complete frontmatter, an ISO-8601 `updated`, and a `YYYY-MM-DD-slug.md` filename |
| App picks it up | The new note appears in Rusty Noter within about a second |

- [ ] **Step 4: Verify the negative case**

In the same session, ask a general question that does **not** mention notes — for example "what's the syntax for a Swift result builder?".

Expected: Claude answers directly and does **not** read the vault. The skill firing here would mean the description is too broad.

- [ ] **Step 5: Record the outcome**

If every check passed, tag the phase:

```bash
git tag -a v0.3.0-phase2 -m "Phase 2: Claude skill -- notes reachable from any session"
```

If any check failed, stop and report which one; a failing acceptance check means the skill's description or content needs adjusting in Task 1, not a workaround here.

---

## Notes for the implementer

- **Rebuild AND relaunch before judging any behavior.** Stale builds have repeatedly caused false conclusions on this project.
- **Never point a test at the real `~/.claude`.** `SkillInstaller` takes an injected directory for exactly this reason.
- **If three fixes in a row fail on the same problem, stop and raise it** rather than continuing.
