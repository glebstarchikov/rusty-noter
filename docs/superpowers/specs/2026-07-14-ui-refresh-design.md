# Rusty Noter UI Refresh: Design

Date: 2026-07-14
Status: approved (brainstorm complete, pre-implementation)
Builds on: Phase 1 (`v0.1.0-phase1`, merged to main). Design system: [glebstar/design](file:///Users/glebstarcikov/design/design.md) (Crafted Minimal).

## 1. Summary

Phase 1 shipped a working native macOS notes app. It renders correctly but looks *unfinished* next to Apple Notes in two specific spots, and the editor reads as empty. This refresh closes those gaps while pushing our own identity harder, in one pass:

1. **Time-grouped note list** with **inset rounded rows** (borrowed from Apple, adapted to our system).
2. **Editor spine** — a mono metadata line giving each note context.
3. **Signature move: the best live-markdown editor on Mac** — real markdown rendered beautifully in the editor.
4. **An impeccable pass** — systematic spacing, hierarchy, and interaction-state polish over every surface.

Not a rewrite: we evolve the existing SwiftUI views and the `NoterEditor` package. No new app packages, no backend changes.

## 2. Goals and non-goals

Goals:

- The note list is scannable by time and feels like a considered modern macOS list.
- The editor has structure and is the nicest place to write markdown on a Mac.
- Every surface obeys one consistent spacing and type system.
- The app reads as deliberately *not* Apple Notes: quieter, keyboard-first, markdown-and-agent-native.

Non-goals (explicitly out of scope — Apple's feature-sprawl lane, which we reject):

- No thumbnails/image previews in list rows.
- No formatting toolbar, no attachment / table / checklist buttons.
- No rich-text / WYSIWYG. We stay live-styled markdown source.
- No new data model, no frontmatter changes, no coordinator/store changes beyond read-only consumption.
- No pinned-notes feature this pass (parked; would need a frontmatter key).

## 3. Design-system evolution (fold back into design.md)

design.md currently says "rows, not cards, hairline separators." This refresh deliberately updates that for **list surfaces specifically**: the modern macOS idiom (Notes, Mail, Reminders) is the **inset rounded row** — a row with internal padding and a soft rounded-rect fill on hover/selection, in an inset list, separated by rhythm rather than hairlines. This is not "cards" (no shadows, no boxes-everywhere); it is rows that breathe.

Deliverable: after implementation, update `~/design/design.md` to record two decisions — (a) the inset-rounded-row list pattern as an approved alternative to hairline rows for list-of-items surfaces, and (b) the editor metadata spine pattern. Per design.md's own rule: "decide it once, ship it, then fold the decision back." (This edits the separate `~/design` repo; tracked as the final step.)

## 4. The note list

### 4.1 Time grouping

Notes in the current sidebar-filtered set are bucketed into ordered sections by `updated` timestamp, relative to now:

| Section label (mono, uppercase) | Contains |
|---|---|
| `Today` | updated today |
| `Yesterday` | updated yesterday |
| `Previous 7 Days` | 2–7 days ago |
| `Previous 30 Days` | 8–30 days ago |
| `<Month Year>` e.g. `June 2026` | older, one bucket per calendar month |

- Sections appear only when non-empty, in the order above (recent first; month buckets descending).
- Within a section, notes sort by `updated` descending.
- When a **search** is active, grouping is suppressed — results show as a single flat relevance-ranked list (search is about relevance, not recency).
- The grouping is a **pure function** of (notes, now, calendar), so it is unit-testable and deterministic.

### 4.2 Row anatomy (inset rounded row)

- Row container: internal padding 8px vertical / 10px horizontal, `radius-md` (10px) corners.
- States: default transparent; hover fills `elevated`; selected fills `accent-soft`. Micro-transition 150ms. No hairline separators between rows; vertical rhythm (~2px gap) separates them.
- Content: title in `fg` (14px medium, single line, ellipsis); one-line snippet in `secondary` (12px); mono date in `faint` (11px) right-aligned on the title row.
- Meeting notes (`type: meeting`) show a `danger` recording dot before the title only while `status: recording`; otherwise a small `waveform` affordance is omitted (title alone) to keep rows quiet.
- Date formatting is relative-precision: `HH:mm` if today, `MMM d` if this calendar year, `yyyy-MM-dd` if older. Mono throughout.

### 4.3 List column header

Replace the current "Rusty Noter" branding in the list column with orientation: the active scope name (e.g. "All Notes", "Meetings", a tag) as a quiet title, plus a mono note count. Branding moves out of the working area.

## 5. The editor

### 5.1 Metadata spine

Directly under the note title, a single mono line in `faint` (11px):

```
2026-07-11  ·  work, pricing  ·  142 words
```

- Date = the note's `updated` (full `yyyy-MM-dd`).
- Tags = comma-joined `tags` (omitted if none).
- Word count = live count of the body (markdown-stripped), recomputed as the user types.
- Separated from the body by 16px and a single `border` hairline (the one structural rule the editor keeps).
- Word count is a **pure function** of body text → unit-testable.

### 5.2 Live-markdown rendering (the signature move)

The editor stays live-styled markdown *source* (not WYSIWYG). We elevate how the existing `MarkdownHighlighter` spans render, via `EditorTheme` attributes on the `NSTextStorage`. Per span kind:

| Span | Rendering |
|---|---|
| `heading(1/2/3)` | 22 / 19 / 17px, semibold, `fg` |
| `bold` | semibold `fg` |
| `italic` | italic `fg` |
| `inlineCode` | mono 13px, `secondary`, subtle `elevated` background chip (via `.backgroundColor` attribute) |
| `codeBlock` | mono 13px, `secondary`, `elevated` background across the block |
| `link` | `accent`, no underline |
| `listMarker` | `faint` |
| `blockquote` | `secondary`, paragraph indented (headIndent via paragraph style) |

- **Baseline (guaranteed, attribute-only):** everything above is achievable with `NSAttributedString` attributes on the text storage — no custom layout.
- **Stretch (within the impeccable pass, verified on-screen):** a drawn left rule on blockquotes and rounded corners on the inline-code chip require a custom `NSTextView`/layout-manager drawing pass. Attempt during polish; if AppKit fights it, ship the attribute-only baseline (indent + color) and note it. Do **not** block the refresh on the drawn rule.
- Editor body: 16px, line-height ~1.65, prose measure capped ~62ch / 680pt (the existing `MeasuredTextView`), generous horizontal padding (≥34px at width).
- Restyle remains attribute-only (no caret move, no undo dirtying) — the Phase 1 guarantee is preserved.

## 6. The impeccable pass

A systematic polish layer over every surface, driven by the `impeccable` skill during implementation (iterating against real screenshots — Gleb can now run and screenshot the app, so visual iteration is real this time, unlike Phase 1's headless build).

- **Spacing:** every gap/pad snaps to the 4px scale (4/8/12/16/24/32). No off-scale values.
- **Type hierarchy:** at most one mono uppercase label per view section (design.md discipline); display title 22–26px, tracking -0.02em; body 14px working / 16px reading; mono metadata 11px.
- **Sidebar:** consistent row height, icon optical alignment, `accent-soft` selection matching the list.
- **Toolbar/header:** aligned rhythm, the new-note and search affordances balanced.
- **States everywhere:** visible 2px `accent` focus rings, hover feedback, selection consistency across sidebar and list, reduced-motion honored.
- **Empty/welcome states:** one sentence + at most one action (already compliant; re-verify tone and spacing).

Acceptance for this section is visual, not automated: a before/after screenshot pass Gleb signs off, plus the impeccable skill's own checklist.

## 7. Architecture and files

No new packages. Two small pure functions go into `NoterCore` (testable); the rest is App/Editor view work (build- and screenshot-verified).

| File | Change |
|---|---|
| `Packages/NoterCore/Sources/NoterCore/NoteGrouping.swift` | NEW — pure `sections(notes:now:calendar:) -> [NoteSection]` bucketing (§4.1). `NoteSection { title: String; notes: [Note] }`. |
| `Packages/NoterCore/Sources/NoterCore/WordCount.swift` | NEW — pure `wordCount(of body: String) -> Int` (markdown-aware strip). |
| `Packages/NoterCore/Tests/NoterCoreTests/NoteGroupingTests.swift` | NEW — bucket boundaries, ordering, month buckets, empty, search-suppressed case is App-level so not here. |
| `Packages/NoterCore/Tests/NoterCoreTests/WordCountTests.swift` | NEW — plain text, markdown glyphs stripped, empty, whitespace. |
| `App/Sources/AppModel.swift` | Expose `noteSections: [NoteSection]` (grouped `visibleNotes`, grouping suppressed when `searchHits != nil`). |
| `App/Sources/NoteListView.swift` | Rewrite to render sections + inset rounded rows (§4.2); list-column header (§4.3). |
| `App/Sources/EditorContainerView.swift` | Add the metadata spine (§5.1). |
| `Packages/NoterEditor/Sources/NoterEditor/EditorTheme.swift` | Add inline-code/code-block background, blockquote color, heading sizes (§5.2). |
| `Packages/NoterEditor/Sources/NoterEditor/MarkdownTextView.swift` | Apply the new attributes in `restyle()`; optional stretch drawing pass. |
| `App/Sources/SidebarView.swift`, `App/Sources/RustyNoterApp.swift` | Impeccable spacing/state pass (§6). |
| `~/design/design.md` | Fold-back the inset-row + editor-spine decisions (§3) — separate repo, final step. |

## 8. Testing

- **Unit (NoterCore, TDD):** `NoteGrouping` — a note at each boundary lands in the right bucket (today/yesterday/7/30/month), sections omitted when empty, month buckets ordered descending, within-section sort by `updated` desc, stable given an injected `now` and `Calendar` (no `Date.now`/timezone flakiness — inject both). `WordCount` — counts words, ignores markdown glyphs (`#`, `*`, `` ` ``, `-`, `>`, link syntax), empty/whitespace → 0.
- **Build:** app builds clean (`xcodebuild ... BUILD SUCCEEDED`); both package suites green (61 + new grouping/wordcount tests, + 9 editor).
- **Visual (real this pass):** Gleb runs the app against a fixture/real vault and screenshots; the impeccable iteration works against those screenshots. Sign-off items: list grouping renders with correct buckets; inset rounded rows with hover/selection; editor spine shows date·tags·words and updates live; markdown renders per §5.2 (heading sizes, bold, code chip, blockquote, link accent, list marker); spacing reads consistent; focus/selection states correct. This closes the visual-verification gate that Phase 1 had to defer.

## 9. Open decisions (resolved)

- Word count in the spine: **yes** — useful, distinctly writerly, cheap.
- Spine tags clickable-to-filter: **no this pass** — display only; tag filtering already lives in the sidebar.
- Blockquote drawn left rule / rounded code chip: **stretch within the impeccable pass**, attribute-only baseline guaranteed.
- Pinned notes: **parked** (needs a frontmatter key; separate small feature later).
- Grouping when searching: **suppressed** — flat relevance list.

## 10. Parked (not this pass)

Pinned notes; tag-pill editor affordances; per-app meeting-app detection; the Phase-2 backlog items from the Phase 1 whole-branch review (salvaged-note read-only banner, save-conflict detection, App-layer test target) — those ride with Phase 2, not this UI refresh.
