import Foundation

public enum AgentDocsWriter {
    public static func render(vaultPath: String) -> String {
        """
        # Notes Vault

        This folder is a notes vault managed by Rusty Noter at `\(vaultPath)`.
        It is also edited directly by humans and AI agents. Plain markdown
        files are the single source of truth.

        ## Orient instantly

        Read `INDEX.md` first: one table row per note (updated date, title,
        type, tags, path), newest first. One read gives you the full map.

        ## Find content

        Prefer ripgrep. Useful recipes:

        ~~~bash
        rg -il "pricing" --glob "*.md"                                                             # notes mentioning a word
        rg -l "^tags: .*standup" --glob "*.md" --glob '!INDEX.md' --glob '!CLAUDE.md' --glob '!AGENTS.md'    # notes with a tag
        rg -l "^type: meeting" --glob "*.md" --glob '!INDEX.md' --glob '!CLAUDE.md' --glob '!AGENTS.md'      # all meeting notes
        rg -l "^status: recording" --glob "*.md" --glob '!INDEX.md' --glob '!CLAUDE.md' --glob '!AGENTS.md'  # meeting happening RIGHT NOW
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
