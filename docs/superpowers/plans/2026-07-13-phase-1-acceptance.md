# Phase 1 Acceptance: Vault + Editor (spec 13.1)

Spec: `docs/superpowers/specs/2026-07-11-rusty-noter-design.md` section 13, phase 1.
Acceptance text: "create/edit/search notes; external edit visible in app under 1s;
INDEX.md and CLAUDE.md/AGENTS.md correct; search instant on a 1k-note fixture vault."

This document is the evidence record for Task 15 (final task of Phase 1). It is
scrupulously split into two kinds of line item:

- `[x]` items verified with real, reproducible, on-disk or automated evidence,
  captured below.
- `[ ] REQUIRES MANUAL` items that are inherently visual or interactive (list
  rendering, scroll feel, live styling, glass panel appearance, keyboard focus).
  The verifying agent has **no Screen Recording / Accessibility TCC** in this
  sandboxed session and cannot click the UI or take screenshots, so these are
  **not self-certified**. Exact repro steps are in section 4 for Gleb to run
  at the screen; each takes under two minutes.

Environment: macOS 26.4.1, Xcode 26.4.1, Swift 6.3.1, this machine (the target
machine per the plan's execution note).

## 1. Fixture generator

`scripts/make_fixture_vault.swift` was created verbatim from the task brief
(diffed byte-for-byte against the brief's code block; identical).

```
$ swift scripts/make_fixture_vault.swift /tmp/noter-fixture-vault 1000
Generated 1000 notes in /tmp/noter-fixture-vault
```

- [x] Generates exactly 1000 notes — evidence: `find /tmp/noter-fixture-vault -name "*.md" | wc -l` → `1000` (900 at vault root + 100 under `meetings/`, matching the generator's `i % 10 == 0` split). Zero duplicate filenames (`find ... -exec basename | sort | uniq -d` → empty). Sample notes parse cleanly (well-formed `---` frontmatter fences, ISO 8601 timestamps with `+02:00` offset, single-element `tags: [tag]` arrays — all inside `FrontmatterCodec.parse`'s accepted grammar).

## 2. Automated evidence

### NoterCore — three consecutive runs (flake check)

```
$ cd Packages/NoterCore && for i in 1 2 3; do swift test || break; done
```

| Run | Result | Tests | Suites | Wall time |
|---|---|---|---|---|
| 1 | passed | 59 | 10 | 2.650s |
| 2 | passed | 59 | 10 | 2.638s |
| 3 | passed | 59 | 10 | 2.679s |

- [x] Three-for-three green, no flake — evidence: all three run logs show `Test run with 59 tests in 10 suites passed`; `grep -ic fail` on each log returns exactly 1 hit each, and that hit is the benign XCTest-bridge boilerplate line `Executed 0 tests, with 0 failures (0 unexpected)` (there are no XCTestCase-based tests in this target, only swift-testing `@Test`s, so the XCTest wrapper always reports 0/0). No test named `FolderWatcherTests` or `VaultCoordinatorTests` (the real-timing suites, the flake risk called out in the brief) failed or varied across runs; their durations were stable within ~0.05s run to run.

### NoterEditor

```
$ cd Packages/NoterEditor && swift test
✔ Test run with 9 tests in 1 suite passed after 0.001 seconds.
```

- [x] 9/9 green — evidence: full `MarkdownHighlighterTests` suite log, zero failures.

### Search performance (spec's <50ms-on-1k-notes criterion)

`thousandNotesSearchUnder50ms` (in `SearchIndexTests.swift`) passed in all three
NoterCore runs above. To get the actual measured number (not just the pass/fail),
the test was temporarily instrumented with one `print` line, run twice, then
**reverted via `git checkout`** before anything was staged — this is not a
committed change; `git status` on the file was clean before and after.

```
TASK15-MEASURED-ELAPSED: 0.0013655 seconds   (run A)
TASK15-MEASURED-ELAPSED: 0.001200125 seconds (run B)
```

- [x] Search over 1000 notes for a 2-term FTS query ("pricing meeting") takes
  **~1.2-1.4ms**, about 35-40x under the 50ms budget. (The `0.119s` the swift-testing
  runner reports for this test includes building all 1000 notes and running
  `index.rebuild(from:)` before the timed `search()` call — the ContinuousClock
  measurement inside the test isolates just the search, which is what's asserted
  against 50ms and what's reported above.)

### Build

```
$ xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -5
    cd /Users/glebstarcikov/rusty-noter/RustyNoter.xcodeproj
    /Applications/Xcode.app/.../clang-stat-cache ... 

** BUILD SUCCEEDED **
```

- [x] Clean build succeeded — evidence: `** BUILD SUCCEEDED **`, and the produced
  binary exists and is a valid arm64 Mach-O: `build/Build/Products/Debug/RustyNoter.app/Contents/MacOS/RustyNoter`.

## 3. On-disk acceptance against the fixture vault (spec 13.1 walkthrough)

Procedure: removed a stale, unrelated `index.db` from prior manual testing so
"gets created" evidence below is unambiguous; pointed the app at the fixture
vault (`defaults write nl.glebstarchikov.RustyNoter vaultPath /tmp/noter-fixture-vault`);
launched the real built app with `open`; let it run; inspected real files, the
real SQLite cache (via the `sqlite3` CLI, not the app's UI), and real command
output; quit; relaunched once more to check second-boot stability; quit again;
cleaned up. No UI was clicked, no screenshot was taken — every check below is a
file, a database row, or a command's stdout.

Numbering follows the brief's 9-item walkthrough.

**1. List shows 1000 notes instantly; scrolling is smooth; sidebar shows
Meetings, five tags, `meetings` folder.**
- [x] *Data underneath is correct* — evidence: FTS index held exactly 1000 rows
  right after launch (`sqlite3 index.db "SELECT count(*) FROM notes_fts"` → `1000`);
  fixture has exactly 5 distinct tags (`work, product, personal, urgent, later`,
  each appearing 200x by construction) and exactly 100 `type: meeting` notes
  under `meetings/` — the exact inputs `SidebarView`'s `allTags` and
  `topLevelFolders` derive from.
- [ ] REQUIRES MANUAL — instant rendering and scroll smoothness are a live
  perception judgment; see section 4.1.

**2. Search-as-you-type for "pricing metrics" narrows the list with no
perceptible lag.**
- [x] *Engine speed is proven* — see section 2's search perf evidence (~1.2ms/query).
- [ ] REQUIRES MANUAL — "no perceptible lag" is a UI/typing-feel judgment the
  fast engine makes likely but does not prove; see section 4.2.

**3. Create (Cmd+N), type heading + bold + code, watch live styling; search
finds the new note by a body word.**
- [x] *Mechanics are proven* — app-originated notes are indexed inline with no
  debounce (`appOriginatedEditsIndexInlineAndSkipEcho`, green); the markdown
  span engine is fully unit-tested for headings/bold/code (`MarkdownHighlighterTests`,
  9/9 green).
- [ ] REQUIRES MANUAL — actually watching live restyle and caret behavior while
  typing, and seeing the new note surface in a real search, is interactive;
  see section 4.3.

**4. External edit visible in under 1 second.**
- [x] VERIFIED — wrote the brief's literal command:
  `printf -- '---\ntitle: Agent wrote this\n...' > /tmp/noter-fixture-vault/2026-07-13-agent-wrote-this.md`
  while the app was running, then polled the live `index.db` FTS table directly.
  Coarse poll (0.5s granularity): present between t=0.5s and t=1.0s. A second
  probe file with 0.1s polling measured it precisely: **the FTS index (the
  data the in-app list/search reads) reflected the external write at t=0.59s**
  — under the spec's 1s target, and consistent with the code's own timing
  budget (`FolderWatcher` 0.2s FSEvents latency + 0.3s debounce = 0.5s floor,
  plus reload/parse/upsert overhead).

**5. `head -8 INDEX.md` shows the header block and newest-first; the external
note from item 4 is present after its debounce.**
- [x] VERIFIED — header block byte-matches spec 5.4's format exactly:
  ```
  # Notes Index

  Generated by Rusty Noter. Do not edit; changes are overwritten.

  | Updated | Title | Type | Tags | Path |
  |---|---|---|---|---|
  ```
  Row count was exactly 1000 immediately after first launch, growing to 1003
  after the two external-edit probes and the broken-frontmatter note (item 8).
  Sort order was verified **programmatically across all 1000+ rows** (not just
  eyeballing head/tail): a small script compared every row's date against the
  previous row and found **zero descending-order violations**. `INDEX.md`
  reflected the item-4 external note at **t=3.2s** (between the 2.6s and 3.2s
  polls) — consistent with the coordinator's explicit 2.0s `indexMdDelay` on
  top of the ~0.5s FSEvents floor, separate from (and slower than, by design)
  the sub-1s in-memory/search update in item 4.

**6. CLAUDE.md and AGENTS.md exist, are identical, contain the vault path,
and every rg recipe in them returns sensible results.**
- [x] VERIFIED, with two honest caveats below —
  - `diff CLAUDE.md AGENTS.md` → empty (byte-identical).
  - Both contain the vault path as `` `/private/tmp/noter-fixture-vault` ``,
    not the literal `/tmp/noter-fixture-vault`. This is expected: `/tmp` is a
    symlink to `/private/tmp` on macOS, and `Vault` deliberately canonicalizes
    the root via `realpath` (comment in `Vault.swift`: "so paths reported by
    the kernel (FSEvents) compare equal to vault-derived paths"). The literal
    substring `/tmp/noter-fixture-vault` **is** present inside
    `/private/tmp/noter-fixture-vault`, so the checklist item's literal wording
    is satisfied, but the displayed path is the canonicalized form. Worth
    knowing, not a bug.
  - rg recipes, run for real with cwd = the fixture vault:

    | Recipe | Result | Assessment |
    |---|---|---|
    | `rg -il "pricing" --glob "*.md"` | 170 files | Sensible — real notes whose title/body mention "pricing" (word appears in ~1/6 of the 12-word rotation twice per note-slot). |
    | `rg -l "^tags: .*standup" --glob "*.md"` | 2 files: `CLAUDE.md`, `AGENTS.md` | **Both hits are the generated docs matching their own embedded YAML example** (`tags: [work, standup]` inside the "Note format" sample block). Zero real notes match, because the fixture's tag vocabulary is `{work, product, personal, urgent, later}` — no note is tagged "standup". Not a bug: the pattern works correctly; it's a coincidence of the illustrative example text living in a `.md` file that ripgrep's `*.md` glob doesn't know to exclude (only the app's own `Vault.isNotePath` excludes generated files, and rg has no such awareness). |
    | `rg -l "^type: meeting" --glob "*.md"` | 102 files | 100 are genuine meeting notes under `meetings/`; the other 2 are again `CLAUDE.md`/`AGENTS.md` self-matching their embedded `type: meeting` example line (the comment `# note or meeting` on that same line). Same root cause as above. |
    | `rg -l "^status: recording" --glob "*.md"` | 0 files | Correct — the fixture is static, no note has a live `status: recording` marker. |

  Net: all four recipes execute correctly and demonstrate the intended
  mechanism; two of the four have a minor, harmless self-match against the
  generated docs' own illustrative frontmatter block, worth being aware of but
  not worth fixing as part of this verification-only task.

**7. Cmd+K palette (glass panel, fuzzy jump, Escape closes); Cmd+, opens
Settings; editor Cmd+F opens the find bar.**
- [ ] REQUIRES MANUAL — entirely visual/interactive; see section 4.4. Includes
  the explicitly tracked open item from Task 13's review: Escape-restores-focus
  relies on AppKit's default responder chain and was never confirmed on a real
  screen.

**8. Broken-frontmatter note: appears titled "broken"; selecting shows raw
content; file never modified.**
- [x] *Salvage mechanics verified on disk* — wrote
  `echo "no frontmatter" > /tmp/noter-fixture-vault/broken.md` while the app
  ran, then queried the live index directly:
  `sqlite3 index.db "SELECT path,title,body FROM notes_fts WHERE path='broken.md'"`
  → `broken.md|broken|no frontmatter` — exactly `NotesStore`'s salvage path
  (filename stem as title, raw bytes as body, default type `note`). File `md5`
  before and after the app's automatic FSEvents processing pass was
  **byte-identical** (`122ea57e31bcb8466b3695fdbf140bba`, 15 bytes, both times).
  `INDEX.md` later showed it as the single newest row (`| 2026-07-14 | broken |
  note |  | broken.md |`) since its mtime is "today", newer than every
  timestamped fixture note.
- [ ] REQUIRES MANUAL — this proves the app's automatic background processing
  never rewrites the file, and that the salvaged title is correct data. It does
  **not** prove what the sidebar/list actually renders, or that clicking into
  and around the note in the UI leaves the file untouched (a stronger claim
  than "automatic processing doesn't touch it"). See section 4.5.

**9. Quit the app; `defaults delete`.**
- [x] Done for this verification pass — app quit cleanly via
  `osascript -e 'tell application "RustyNoter" to quit'` (confirmed via `pgrep`),
  twice (once after the initial walkthrough, once after a relaunch stability
  check below). All cleanup from this pass is in section 6. Gleb's manual pass
  in section 4 needs its own quit + `defaults delete` at the end (repeated
  there for convenience).

### Bonus: relaunch stability (not in the brief, added for confidence)

After the item 4/5/6/8 tests left the vault with 1003 notes (1000 fixture +
2 external-edit probes + 1 salvaged broken note), the app was quit and
relaunched cold against the same vault:

- [x] No crash; `INDEX.md` and the FTS index both stable at 1003 rows after
  the relaunch's own rebuild.
- [x] `CLAUDE.md`'s mtime was unchanged by the relaunch (content was already
  identical, so `AgentDocsWriter.writeIfMissingOrStale`'s "skip when fresh"
  path took over) — confirms the `writesBothFilesOnceAndSkipsWhenFresh` unit
  test's behavior holds against real on-disk data, not just the test fixture.

### Application Support cache

- [x] `~/Library/Application Support/RustyNoter/index.db` did not exist at the
  start of this vault's test (a stale one from unrelated prior manual testing
  was removed first for a clean signal) and was freshly created within
  seconds of launch (425984 bytes, GRDB/FTS5 schema, 1000 rows). Removed again
  during cleanup (section 6) since it's explicitly documented as disposable
  (spec 5.7) and self-rebuilds on next launch against any vault.

## 4. Requires manual verification at the screen

None of these were run — no Screen Recording/Accessibility TCC in this
sandboxed session, and the task explicitly forbids self-certifying visual or
interactive behavior. Each takes well under two minutes. Regenerate the
fixture first (it was deleted in cleanup, section 6):

```bash
cd /Users/glebstarcikov/rusty-noter
swift scripts/make_fixture_vault.swift /tmp/noter-fixture-vault 1000
defaults write nl.glebstarchikov.RustyNoter vaultPath /tmp/noter-fixture-vault
open build/Build/Products/Debug/RustyNoter.app
```

**4.1 List rendering + scroll smoothness + sidebar (brief item 1)**
Look at the note list on launch: 1000 rows should be there with no spinner or
blank flash. Scroll through it (trackpad or wheel): should feel smooth, no
stutter. Look at the sidebar: "All Notes", "Meetings", a "Tags" section with
exactly 5 tags (work, product, personal, urgent, later), a "Folders" section
with a `meetings` entry.

**4.2 Search-as-you-type (brief item 2)**
Click the toolbar search field. Type "pricing metrics" one character at a
time. Watch the list narrow after each keystroke — should feel instant, no
visible lag or flicker.

**4.3 Create + live styling + caret behavior (brief item 3)**
Cmd+N. Type a body with a heading (`# Heading`), **bold** text, and `inline
code`. Watch styling apply live as you type — heading larger, bold rendered
bold, code monospaced, syntax marker characters (`#`, `**`, `` ` ``) faintly
visible rather than hidden. Type a distinctive word (e.g. `zzzverify`) in the
body. Search for `zzzverify` in the toolbar field; confirm the new note shows
up in the narrowed list.

**4.4 Cmd+K palette, Settings, editor find bar, Escape-restores-focus (brief
item 7 + Task 13's tracked open item)**
Cmd+K: a glass/translucent panel should appear near the top, centered. Type a
few letters of an existing note's title; confirm fuzzy narrowing. Press
Down/Up; confirm the highlighted row moves. Press Return on a highlighted row;
confirm the palette closes and that note opens. Reopen (Cmd+K) and press
Escape instead; confirm the panel closes, **and specifically check where
keyboard focus lands afterward** — this relies on AppKit's default responder
chain (no explicit restoration code) and was flagged in Task 13's review as
unverified on a real screen; a focus landing nowhere useful (e.g. on no
control at all) would be the failure mode to watch for. Press Cmd+, — Settings
should open showing the vault path and a "Change Folder" button. Close
Settings, click into the editor body, press Cmd+F — the native NSTextView find
bar should appear at the top of the editor.

**4.5 Broken-frontmatter note in the actual list (brief item 8, UI half)**
In a terminal: `echo "no frontmatter" > /tmp/noter-fixture-vault/broken2.md`.
Within a couple seconds, find a note titled "broken2" in the list (it will be
the single newest item, since its file's mtime is "now"). Click it; confirm
the editor shows the raw content `no frontmatter`, not a parsed title/body
split. Click into a couple of other notes and back; then run
`cat /tmp/noter-fixture-vault/broken2.md` in the terminal and confirm it still
reads exactly `no frontmatter` — the app must never rewrite it, even after
being selected and viewed in the UI (this verifies more than the automated
pass above, which only exercised the automatic background processing path,
not UI selection).

**Cleanup after the manual pass:**
```bash
# Cmd+Q the app first
defaults delete nl.glebstarchikov.RustyNoter vaultPath
rm -rf /tmp/noter-fixture-vault
```

## 5. Known intentional deferrals within Phase 1

Carried over from the plan's self-review, reported here rather than silently
expanded or silently dropped: faint-rendering of markdown marker glyphs (the
highlighter spans style whole ranges rather than dimming just the marker
characters); Cmd+Shift+F programmatic search-focus was reverted in Task 13
(`.searchFocused` fought the framework; Cmd+K palette covers keyboard-driven
jump-to-note instead); per-paragraph incremental restyling is not implemented
(full-document restyle on every keystroke, which is fine at note-sized
documents but would not scale to very large single notes).

## 6. Cleanup performed by this verification pass

- [x] `defaults delete nl.glebstarchikov.RustyNoter vaultPath` — confirmed gone
  (`defaults read` errors "does not exist").
- [x] `/tmp/noter-fixture-vault` removed.
- [x] Test-run `index.db` removed from `~/Library/Application Support/RustyNoter/`
  (disposable cache; rebuilds automatically on next launch against any vault).
- [x] No RustyNoter process left running (`pgrep` empty).
- [x] Working tree left clean apart from the two files this task adds
  (`scripts/make_fixture_vault.swift`, this document); the one temporary test
  edit to `SearchIndexTests.swift` (an added `print` line) was reverted via
  `git checkout` before staging anything, confirmed via `git status`.

## Verdict

Everything checkable without a screen is verified with real, reproducible
on-disk/automated evidence above: fixture generation, 3x NoterCore + NoterEditor
green, build succeeded, search performance (~1.2ms at 1k notes, 35-40x under
budget), INDEX.md correctness (content, header, sort order across all rows),
CLAUDE.md/AGENTS.md correctness (identical, path present, recipes functional
with two documented self-match caveats), sub-1-second external-edit propagation
(measured at 0.59s), broken-frontmatter salvage semantics and the
never-rewrite guarantee (at the automatic-processing layer), and relaunch
stability. Five categories of inherently visual/interactive behavior are
explicitly deferred to a human at the screen (section 4) rather than
self-certified, per the task's binding constraint.
