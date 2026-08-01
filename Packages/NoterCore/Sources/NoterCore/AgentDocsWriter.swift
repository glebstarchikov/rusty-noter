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
    /// some other directory can still reach the vault. Lives outside the vault
    /// (`~/.claude/skills/`), so the recipe excludes below still cover every
    /// generated file a vault-scoped search can see.
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
        // The generated files embed example frontmatter, so a tag/type search
        // matches them unless they are excluded.
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
        rg -il "pricing" --glob "*.md" \(excludes)\(scope)
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
