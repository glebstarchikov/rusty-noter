# Claude Skill (Phase 2): Design

## 1. Problem summary

The vault already teaches agents how to use it. `AgentDocsWriter` generates
`CLAUDE.md` and `AGENTS.md` at the vault root, covering orientation, `rg`
recipes, the frontmatter schema, and the write rules.

Those files only work when the agent is **already inside the vault**. The case
they cannot serve is the common one: working in some other repo and asking
"what did I write about pricing?" — no `CLAUDE.md` in scope, no vault in the
working directory, no idea the vault exists.

The skill exists to close that gap. Its job is not primarily to teach
conventions — the vault docs already do that — but to make Claude **aware the
vault exists, know where it is, and reach into it correctly from anywhere.**

## 2. Goals and non-goals

**Goals**

- From any directory, in a fresh Claude Code session, "find my note about X"
  resolves via one `INDEX.md` read plus at most one `rg` (spec §13, phase 2).
- Notes created by Claude follow the write conventions: complete frontmatter,
  `updated` touched, `YYYY-MM-DD-slug.md` filename.
- One source of truth for conventions. The skill and the vault docs cannot
  drift apart as the note format grows in later phases.
- Installed and kept current by the app, with every failure visible.

**Non-goals**

- No in-app chat. Claude is the chat interface (project non-negotiable).
- No MCP server. That is Phase 5 and serves clients without filesystem access.
- No helper scripts or wrappers. `rg` recipes are sufficient; a script would be
  a moving part with no current payoff.
- The skill does not manage, repair, or index the vault. It reads and writes
  notes like any other agent.

## 3. Decisions

| Decision | Choice | Why |
|---|---|---|
| Vault path resolution | Baked into `SKILL.md` at install; rewritten when the vault moves | No runtime lookup, one owner. Same mechanism that already regenerates `CLAUDE.md` |
| Trigger scope | Explicit notes language only | Predictable; never drags the vault into unrelated work in another repo |
| Authoring | Generated from `AgentDocsWriter` | Drift between skill and vault docs becomes impossible by construction |
| Install location | `~/.claude/skills/rusty-noter/` | Namespaced, so overwriting is always safe |
| Write confirmation | None in the skill | Claude Code already prompts on file writes; a second gate is redundant |

Two deliberate deviations from the original spec (§6.1), both recorded here as
the governing decision:

1. **Generated, not hand-authored under `claude-skill/`.** The original spec
   predates `AgentDocsWriter` in its current shape. Hand-authoring would put the
   frontmatter schema, `rg` recipes, and write rules in two places; when Phase 3
   adds `audio:`/`duration:` and Phase 4 adds auto-tags, one copy would silently
   rot.
2. **`~/.claude/skills/rusty-noter/`, not `~/.claude/skills/notes/`.** `notes`
   is a generic name. If the user has their own skill there, a one-click Install
   would silently overwrite someone else's work.

## 4. Architecture

```
NoterCore (pure, testable)              App layer (I/O outside the vault)
────────────────────────────            ─────────────────────────────────
AgentDocsWriter                         SkillInstaller
  conventions(vaultPath:, mode:)          install()  → write SKILL.md
    .inVault → relative rg                status()   → notInstalled | current | stale
    .remote  → path-qualified rg          sync()     → rewrite path after a vault move
  render(vaultPath:)      → CLAUDE.md       remove()   → delete the skill directory
                            AGENTS.md
  renderSkill(vaultPath:) → SKILL.md
```

`renderSkill` lives in `NoterCore` because it is pure string generation and
belongs beside the conventions it shares. `SkillInstaller` lives in the App
layer because `~/.claude/skills/` is outside the vault, and `NoterCore`'s remit
is the vault alone.

`SkillInstaller` takes its skills directory as an injected `URL`, defaulting to
`~/.claude/skills`, so tests can point it at a temporary directory rather than
writing into the developer's real `~/.claude`. It reads the vault path from
`AppModel.vaultURL`, the same source Settings displays.

`status()` is defined by exact comparison: render the skill for the current
vault path and compare byte-for-byte against the file on disk. Equal is
`current`, different is `stale`, absent is `notInstalled`. This makes both a
moved vault and an app update that changed the conventions show as "Update
available" through one mechanism, with no version field to maintain.

### 4.1 The mode split

Today's recipes assume the working directory **is** the vault:

```bash
rg -il "pricing" --glob "*.md"
```

Run from another repo, that silently searches *that* repo — returning
plausible, wrong results rather than an error. The `.remote` mode appends the
absolute vault path so the skill cannot misfire that way:

```bash
rg -il "pricing" --glob "*.md" /Users/glebstarcikov/Notes
```

`.inVault` preserves today's behavior for `CLAUDE.md` / `AGENTS.md`, which are
read by agents already sitting in the vault.

## 5. Skill content contract

### 5.1 Frontmatter

```yaml
---
name: rusty-noter
description: >
  Search, read, and write Gleb's notes in the Rusty Noter vault at
  /Users/glebstarcikov/Notes. Use when the user refers to their own notes or
  vault — "my notes", "did I write about X", "what did I note in the standup",
  "note this down", "add to my notes" — or names a specific note or meeting.
  Not for general questions that don't concern their notes.
---
```

The vault path is substituted at generation time. The negative clause is
load-bearing: it is what keeps the skill from firing on general questions.

### 5.2 Body

The shared conventions, rendered in `.remote` mode, plus three skill-specific
additions:

1. **Location preamble.** "You are almost certainly not in this directory.
   Always use absolute paths." This is what prevents the wrong-tree failure.
2. **Lookup order**, which is what makes the efficiency bar real: read
   `INDEX.md` first — one row per note, newest first, one read gives the full
   map — and fall back to `rg` only if the index does not answer the question.
3. **Stale-vault rule.** If the vault path does not exist, say so and stop. Do
   not search the filesystem for a replacement notes folder. A skill that
   guesses at a different vault is worse than one that admits it is
   misconfigured.

Everything else — frontmatter schema, filename format, touch `updated` on edit,
never edit `INDEX.md`/`CLAUDE.md`/`AGENTS.md`, and `status: recording` means a
live meeting that is read-only and grows every few seconds — comes through
unchanged from the shared renderer.

## 6. Install, sync, and removal

Settings gains a **Claude Skill** section with three states:

| State | Shown | Action |
|---|---|---|
| Not installed | "Install to use your notes from any Claude Code session" | Install |
| Installed | The vault path the skill points at | Remove |
| Update available | Content or path differs from what the app would write | Update, Remove |

**Sync on vault move.** `AppModel.setVault` rewrites `SKILL.md` — but only when
the skill is already installed. Installing uninvited because the user changed a
folder is overreach; leaving a stale path after they opted in is worse, since
the skill would confidently point at a vault that no longer exists.

**Removal** deletes `~/.claude/skills/rusty-noter/`. Anything written into the
user's `~/.claude` must be removable from the same screen that put it there.

## 7. Failure handling

Every failure surfaces in Settings with the underlying error. No `try?`.

This is a direct lesson from the 2026-07-27 review: a swallowed
`refusingToRewriteUnparseable` made Pin and Delete look like dead UI for days.
If `~/.claude/skills/` is not writable, Install must say so — not quietly do
nothing and leave the user wondering why Claude cannot find their notes.

Specific cases:

- `~/.claude/skills/` missing → create it, then install.
- Not writable → surface the error, leave the state as Not installed.
- Vault path missing at sync time → still rewrite the skill with the configured
  path; the skill's own stale-vault rule handles it at use time.

## 8. Testing

**NoterCore — `renderSkill(vaultPath:)` is pure:**

- The frontmatter parses, and `name` and `description` are present.
- The description contains the trigger phrases and the negative clause.
- The location preamble and lookup order are present.
- Every `rg` recipe is qualified with the absolute vault path.
- **Negative test:** the skill variant contains **no unqualified `rg`**. The
  positive assertion passes even if one stale relative recipe survives, and that
  one would silently search whatever repo the user is sitting in and return
  confident, wrong answers.
- `.inVault` output is unchanged — existing `AgentDocsWriter` tests must stay
  green, proving the refactor did not alter what the vault docs say.

**App layer — `SkillInstaller` against a temporary home directory:**

- `install()` writes `SKILL.md` at the expected path.
- `status()` returns `notInstalled`, then `current`, then `stale` after the
  configured vault path changes.
- `sync()` rewrites the path, and does nothing when not installed.
- `remove()` deletes the directory.
- An unwritable skills directory surfaces an error rather than failing silently.

**Acceptance (spec §13, phase 2):** in a fresh Claude Code session, in a
directory that is not the vault, "find my note about X" resolves via one
`INDEX.md` read plus at most one `rg`; a note created by Claude carries complete
frontmatter and a correct filename. Verified by hand against a vault with real
notes.

## 9. Out of scope

Phase 5's `noter-mcp` server serves clients without filesystem access (Claude
Desktop, claude.ai) and offers structured tools over the same files. It does not
replace this skill, and this design does not anticipate it.
