# Rusty Noter UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the working-but-plain Phase 1 UI into a considered one: time-grouped inset-rounded note list, an editor with a metadata spine, beautifully rendered live markdown, and a systematic spacing pass.

**Architecture:** No new packages. Two pure, unit-tested functions go into `NoterCore` (date grouping + word count). The rest evolves existing SwiftUI views (`NoteListView`, `EditorContainerView`, `SidebarView`, `RustyNoterApp`) and the `NoterEditor` rendering (`EditorTheme`, `MarkdownTextView`). Views are build-verified by the implementer and pixel-verified by Gleb (he can now run and screenshot the app).

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSTextView), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-14-ui-refresh-design.md`

## Global Constraints

- Deployment target macOS 26.0; Swift language mode 6.
- Semantic token colors only (`TokenColor.*` in the app; `EditorTheme` named-asset lookups in the package). No raw hex in views.
- SF Mono (`.monospaced` / `NSFont.monospacedSystemFont`) for dates, metadata, section labels. No em-dashes in any UI string (use `·`, commas, periods).
- Pure functions inject `now: Date` and `calendar: Calendar` — never call `Date.now`/`Date()` inside them, so tests are deterministic and timezone-independent.
- Editor restyle stays attribute-only: never move the caret or dirty the undo stack (preserve the Phase 1 guarantee).
- Glass stays on the Cmd+K palette only. List and editor stay on opaque `bg`.
- Grouping is suppressed during search (flat relevance list).
- Both package suites stay green; the app builds clean; commit after every green cycle. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

```
Packages/NoterCore/Sources/NoterCore/
  NoteGrouping.swift      NEW — NoteSection + sections(...) + rowDateLabel(...)  (pure, tested)
  WordCount.swift         NEW — count(of:) (pure, tested)
Packages/NoterCore/Tests/NoterCoreTests/
  NoteGroupingTests.swift NEW
  WordCountTests.swift    NEW
App/Sources/
  AppModel.swift          MODIFY — add noteSections computed property
  NoteListView.swift      MODIFY — sections + inset rounded rows + hover
  EditorContainerView.swift MODIFY — metadata spine
  SidebarView.swift       MODIFY — impeccable spacing/state pass
  RustyNoterApp.swift     MODIFY — impeccable spacing, list-column header
Packages/NoterEditor/Sources/NoterEditor/
  EditorTheme.swift       MODIFY — heading sizes 22/19/17, codeBackground
  MarkdownTextView.swift  MODIFY — code chip bg, blockquote indent
~/design/design.md        MODIFY — fold back inset-row + spine decisions (final task, separate repo)
```

---

### Task 1: NoteGrouping (date bucketing + row date label)

**Files:**
- Create: `Packages/NoterCore/Sources/NoterCore/NoteGrouping.swift`
- Create: `Packages/NoterCore/Tests/NoterCoreTests/NoteGroupingTests.swift`

**Interfaces:**
- Consumes: `Note` (existing)
- Produces:
  - `struct NoteSection: Identifiable, Equatable, Sendable { let title: String; let notes: [Note]; var id: String { title } }` — `title == ""` means render no header (the search/flat case).
  - `enum NoteGrouping` with:
    - `static func sections(notes: [Note], now: Date, calendar: Calendar) -> [NoteSection]` — buckets by `updated` into Today / Yesterday / Previous 7 Days / Previous 30 Days / `<Month Year>`, recent first, month buckets descending; within a bucket sorted by `updated` desc; empty buckets omitted.
    - `static func rowDateLabel(for date: Date, now: Date, calendar: Calendar) -> String` — `HH:mm` if same day as `now`, `MMM d` if same calendar year, else `yyyy-MM-dd`.

- [ ] **Step 1: Write the failing tests**

`Packages/NoterCore/Tests/NoterCoreTests/NoteGroupingTests.swift`:

```swift
import Testing
import Foundation
@testable import NoterCore

@Suite struct NoteGroupingTests {
    // Fixed reference "now": 2026-07-14 12:00 UTC.
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var now: Date { Date.iso8601Local("2026-07-14T12:00:00+00:00")! }

    func note(_ path: String, updated: String, title: String = "N") -> Note {
        Note(relativePath: path,
             metadata: NoteMetadata(title: title,
                                    created: Date.iso8601Local(updated)!,
                                    updated: Date.iso8601Local(updated)!),
             body: "")
    }

    @Test func bucketsByRelativeDay() {
        let notes = [
            note("t.md",  updated: "2026-07-14T09:00:00+00:00"), // today
            note("y.md",  updated: "2026-07-13T09:00:00+00:00"), // yesterday
            note("w.md",  updated: "2026-07-10T09:00:00+00:00"), // 4 days -> prev 7
            note("m.md",  updated: "2026-06-30T09:00:00+00:00"), // 14 days -> prev 30
            note("o.md",  updated: "2026-05-02T09:00:00+00:00"), // older -> May 2026
        ]
        let titles = NoteGrouping.sections(notes: notes, now: now, calendar: utc).map(\.title)
        #expect(titles == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "May 2026"])
    }

    @Test func boundaryDays() {
        // exactly 7 days ago -> Previous 7 Days; exactly 8 -> Previous 30 Days
        let seven = note("7.md", updated: "2026-07-07T09:00:00+00:00")
        let eight = note("8.md", updated: "2026-07-06T09:00:00+00:00")
        let thirty = note("30.md", updated: "2026-06-14T09:00:00+00:00")
        let thirtyOne = note("31.md", updated: "2026-06-13T09:00:00+00:00")
        let s = NoteGrouping.sections(notes: [seven, eight, thirty, thirtyOne], now: now, calendar: utc)
        let map = Dictionary(uniqueKeysWithValues: s.map { ($0.title, $0.notes.map(\.relativePath)) })
        #expect(map["Previous 7 Days"] == ["7.md"])
        #expect(map["Previous 30 Days"]?.sorted() == ["30.md", "8.md"])
        #expect(map["June 2026"] == ["31.md"])
    }

    @Test func withinBucketSortedByUpdatedDesc() {
        let a = note("a.md", updated: "2026-07-14T08:00:00+00:00")
        let b = note("b.md", updated: "2026-07-14T11:00:00+00:00")
        let s = NoteGrouping.sections(notes: [a, b], now: now, calendar: utc)
        #expect(s.first?.notes.map(\.relativePath) == ["b.md", "a.md"])
    }

    @Test func monthBucketsDescending() {
        let may = note("may.md", updated: "2026-05-10T09:00:00+00:00")
        let apr = note("apr.md", updated: "2026-04-10T09:00:00+00:00")
        let titles = NoteGrouping.sections(notes: [apr, may], now: now, calendar: utc).map(\.title)
        #expect(titles == ["May 2026", "April 2026"])
    }

    @Test func emptyBucketsOmittedAndEmptyInput() {
        #expect(NoteGrouping.sections(notes: [], now: now, calendar: utc).isEmpty)
        let onlyToday = NoteGrouping.sections(
            notes: [note("t.md", updated: "2026-07-14T09:00:00+00:00")], now: now, calendar: utc)
        #expect(onlyToday.map(\.title) == ["Today"])
    }

    @Test func futureDatedNoteFallsInToday() {
        let future = note("f.md", updated: "2026-07-20T09:00:00+00:00")
        let s = NoteGrouping.sections(notes: [future], now: now, calendar: utc)
        #expect(s.map(\.title) == ["Today"])
    }

    @Test func rowDateLabelFormats() {
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2026-07-14T09:05:00+00:00")!, now: now, calendar: utc) == "09:05")
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2026-07-10T09:00:00+00:00")!, now: now, calendar: utc) == "Jul 10")
        #expect(NoteGrouping.rowDateLabel(
            for: Date.iso8601Local("2025-12-30T09:00:00+00:00")!, now: now, calendar: utc) == "2025-12-30")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/NoterCore && swift test --filter NoteGroupingTests`
Expected: compile FAILURE ("cannot find 'NoteGrouping'").

- [ ] **Step 3: Implement NoteGrouping**

`Packages/NoterCore/Sources/NoterCore/NoteGrouping.swift`:

```swift
import Foundation

public struct NoteSection: Identifiable, Equatable, Sendable {
    public let title: String
    public let notes: [Note]
    public var id: String { title }
    public init(title: String, notes: [Note]) {
        self.title = title
        self.notes = notes
    }
}

/// Pure, deterministic date bucketing for the note list. Inject `now`/`calendar`.
public enum NoteGrouping {
    private enum Bucket: Hashable {
        case today, yesterday, prev7, prev30
        case month(Int, Int) // year, month
    }

    public static func sections(notes: [Note], now: Date, calendar: Calendar) -> [NoteSection] {
        let startOfToday = calendar.startOfDay(for: now)
        var buckets: [Bucket: [Note]] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.metadata.updated)
            let daysAgo = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 99999
            let bucket: Bucket
            if daysAgo <= 0 { bucket = .today }
            else if daysAgo == 1 { bucket = .yesterday }
            else if daysAgo <= 7 { bucket = .prev7 }
            else if daysAgo <= 30 { bucket = .prev30 }
            else {
                let c = calendar.dateComponents([.year, .month], from: note.metadata.updated)
                bucket = .month(c.year ?? 0, c.month ?? 0)
            }
            buckets[bucket, default: []].append(note)
        }

        func sorted(_ notes: [Note]) -> [Note] {
            notes.sorted { $0.metadata.updated > $1.metadata.updated }
        }

        var result: [NoteSection] = []
        for (bucket, title) in [(Bucket.today, "Today"), (.yesterday, "Yesterday"),
                                (.prev7, "Previous 7 Days"), (.prev30, "Previous 30 Days")] {
            if let notes = buckets[bucket], !notes.isEmpty {
                result.append(NoteSection(title: title, notes: sorted(notes)))
            }
        }
        // Month buckets, newest first.
        let months = buckets.keys.compactMap { key -> (Int, Int)? in
            if case let .month(y, m) = key { return (y, m) } else { return nil }
        }.sorted { ($0.0, $0.1) > ($1.0, $1.1) }
        for (y, m) in months {
            let notes = buckets[.month(y, m)] ?? []
            result.append(NoteSection(title: monthTitle(year: y, month: m, calendar: calendar),
                                      notes: sorted(notes)))
        }
        return result
    }

    public static func rowDateLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: date)
    }

    private static func monthTitle(year: Int, month: Int, calendar: Calendar) -> String {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        let date = calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/NoterCore && swift test --filter NoteGroupingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/NoterCore
git commit -m "feat(core): date grouping and row date labels for the note list

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: WordCount

**Files:**
- Create: `Packages/NoterCore/Sources/NoterCore/WordCount.swift`
- Create: `Packages/NoterCore/Tests/NoterCoreTests/WordCountTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `enum WordCount { static func count(of body: String) -> Int }` — counts prose words, stripping markdown glyphs and reducing links to their visible text. Hyphenated words count as one (pinned by test).

- [ ] **Step 1: Write the failing tests**

`Packages/NoterCore/Tests/NoterCoreTests/WordCountTests.swift`:

```swift
import Testing
@testable import NoterCore

@Suite struct WordCountTests {
    @Test func plainText() {
        #expect(WordCount.count(of: "hello world") == 2)
        #expect(WordCount.count(of: "one two three four") == 4)
    }

    @Test func stripsMarkdownGlyphs() {
        #expect(WordCount.count(of: "# Heading\n\nsome **bold** text") == 4) // Heading some bold text
        #expect(WordCount.count(of: "- item one\n- item two") == 4)
        #expect(WordCount.count(of: "> a quoted line") == 3)
    }

    @Test func linksCountVisibleTextNotURL() {
        #expect(WordCount.count(of: "see [the spec](https://x.com/a/b) now") == 4) // see the spec now
        #expect(WordCount.count(of: "bare https://example.com/path url") == 2)     // bare url
    }

    @Test func inlineCodeCountsAsOneWord() {
        #expect(WordCount.count(of: "the `value_metric` field") == 3)
    }

    @Test func hyphenatedIsOneWord() {
        #expect(WordCount.count(of: "a value-add proposition") == 3)
    }

    @Test func emptyAndWhitespace() {
        #expect(WordCount.count(of: "") == 0)
        #expect(WordCount.count(of: "   \n\t  ") == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/NoterCore && swift test --filter WordCountTests`
Expected: compile FAILURE ("cannot find 'WordCount'").

- [ ] **Step 3: Implement WordCount**

`Packages/NoterCore/Sources/NoterCore/WordCount.swift`:

```swift
import Foundation

/// Word count of markdown prose: links reduce to visible text, structural and
/// emphasis glyphs are dropped, bare URLs removed. Hyphenated tokens count once.
public enum WordCount {
    public static func count(of body: String) -> Int {
        var s = body
        // [text](url) -> text
        s = s.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // bare URLs -> removed
        s = s.replacingOccurrences(
            of: #"https?://\S+"#, with: " ", options: .regularExpression)
        // leading list markers per line -> removed
        s = s.replacingOccurrences(
            of: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#, with: " ", options: .regularExpression)
        // inline/structural glyphs -> spaces (hyphen intentionally kept)
        s = s.replacingOccurrences(
            of: #"[#*_`>~\[\]()]"#, with: " ", options: .regularExpression)
        return s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/NoterCore && swift test --filter WordCountTests`
Expected: PASS. Then full suite: `swift test` still green.

- [ ] **Step 5: Commit**

```bash
git add Packages/NoterCore
git commit -m "feat(core): markdown-aware word count

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: AppModel grouped sections

**Files:**
- Modify: `App/Sources/AppModel.swift`

**Interfaces:**
- Consumes: `NoteGrouping`, `NoteSection` (Task 1), existing `visibleNotes`, `searchHits`
- Produces: `var noteSections: [NoteSection]` on `AppModel` — grouped when browsing, a single empty-titled section (flat, relevance order) when a search is active.

- [ ] **Step 1: Add the computed property**

In `App/Sources/AppModel.swift`, add this computed property to `AppModel` (next to `visibleNotes`). `Date()` here is the live wall clock — correct for the running app; the pure grouping function stays testable because tests call `NoteGrouping.sections` directly with an injected `now`.

```swift
    /// The visible notes grouped for display. When a search is active, grouping
    /// is suppressed: results come back as one unlabeled, relevance-ordered
    /// section (search is about relevance, not recency).
    var noteSections: [NoteSection] {
        if searchHits != nil {
            return visibleNotes.isEmpty ? [] : [NoteSection(title: "", notes: visibleNotes)]
        }
        return NoteGrouping.sections(notes: visibleNotes, now: Date(), calendar: .current)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/glebstarcikov/rusty-noter && xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (`NoteListView` still uses `visibleNotes`; it moves to `noteSections` in Task 4. Nothing consumes `noteSections` yet, so this just proves the property compiles.)

- [ ] **Step 3: Commit**

```bash
git add App/Sources/AppModel.swift
git commit -m "feat(app): expose grouped note sections on AppModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: NoteListView — time-grouped inset rounded rows

**Files:**
- Modify: `App/Sources/NoteListView.swift` (full replacement)

**Interfaces:**
- Consumes: `AppModel.noteSections` (Task 3), `NoteGrouping.rowDateLabel` (Task 1), `TokenColor.*`, `Note`
- Produces: the redesigned list. Keyboard selection is preserved via `List(selection:)` + `.tag`.

Design notes: rows keep `List`'s built-in keyboard navigation, but draw their own inset rounded background inside the row content (so hover and selection both live there); `listRowBackground` stays clear and separators are hidden. Selection = `accent-soft`, hover = `elevated`, else clear.

- [ ] **Step 1: Replace NoteListView.swift**

`App/Sources/NoteListView.swift`:

```swift
import SwiftUI
import NoterCore

struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPath) {
            ForEach(model.noteSections) { section in
                Section {
                    ForEach(section.notes) { note in
                        NoteRow(note: note,
                                selected: model.selectedPath == note.relativePath)
                            .tag(note.relativePath)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenColor.faint)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TokenColor.bg)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.visibleNotes.isEmpty {
            if model.searchHits != nil {
                Text("No notes match this search.")
                    .font(.system(size: 13))
                    .foregroundStyle(TokenColor.secondary)
            } else if model.sidebarSelection != .all {
                Text(model.sidebarSelection == .meetings ? "No meetings yet." : "Nothing here yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(TokenColor.secondary)
            } else {
                VStack(spacing: 12) {
                    Text("No notes yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(TokenColor.secondary)
                    Button("New Note") { Task { await model.newNote() } }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    @State private var hovering = false

    private var fill: Color {
        selected ? TokenColor.accentSoft : (hovering ? TokenColor.elevated : .clear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.metadata.title.isEmpty ? "Untitled" : note.metadata.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TokenColor.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if note.metadata.status == .recording {
                    Circle().fill(TokenColor.danger).frame(width: 7, height: 7)
                        .accessibilityLabel("Recording")
                }
                Text(NoteGrouping.rowDateLabel(for: note.metadata.updated, now: Date(), calendar: .current))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenColor.faint)
            }
            if !note.snippet.isEmpty {
                Text(note.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(TokenColor.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
```

- [ ] **Step 2: Build**

Run: `cd /Users/glebstarcikov/rusty-noter && xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Visual smoke on a scratch multi-note vault**

Generate a fixture with notes across time so grouping shows (reuse the Phase 1 generator):
```bash
swift scripts/make_fixture_vault.swift /tmp/noter-refresh-vault 40
defaults write nl.glebstarchikov.RustyNoter vaultPath /tmp/noter-refresh-vault
open build/Build/Products/Debug/RustyNoter.app
```
Report what you can verify headlessly (build succeeded, launches, no crash, INDEX.md generated). Flag for Gleb's visual check: time-section headers in mono, inset rounded rows, hover fill, selected row in accent-soft, no hairline separators. Then clean up: `defaults delete nl.glebstarchikov.RustyNoter vaultPath` and `rm -rf /tmp/noter-refresh-vault`.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/NoteListView.swift
git commit -m "feat(app): time-grouped inset rounded note list

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: EditorContainerView — metadata spine

**Files:**
- Modify: `App/Sources/EditorContainerView.swift`

**Interfaces:**
- Consumes: `WordCount.count` (Task 2), `Slug.dayString`, `TokenColor.*`, existing `draftBody`/`note`
- Produces: a mono metadata line (`date · tags · N words`) between the title field and the editor, with a hairline divider. Word count is live off `draftBody`.

- [ ] **Step 1: Add the spine to the view body**

In `App/Sources/EditorContainerView.swift`, insert the spine + divider immediately after the `TextField(...)` block (after its `.onSubmit { commitTitle() }` modifier, before the `if changedOnDisk` block):

```swift
            metadataSpine
                .padding(.horizontal, 48)
                .padding(.top, 8)

            Divider()
                .overlay(TokenColor.border)
                .padding(.horizontal, 48)
                .padding(.top, 16)
```

And add this computed property to the struct (after `body`):

```swift
    private var metadataSpine: some View {
        HStack(spacing: 8) {
            Text(Slug.dayString(note.metadata.updated))
            if !note.metadata.tags.isEmpty {
                Text("·")
                Text(note.metadata.tags.joined(separator: ", "))
                    .lineLimit(1)
            }
            Text("·")
            Text("\(WordCount.count(of: draftBody)) words")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(TokenColor.faint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

(`import NoterCore` is already present, so `WordCount` and `Slug` resolve.)

- [ ] **Step 2: Build**

Run: `cd /Users/glebstarcikov/rusty-noter && xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Visual smoke**

Launch against a scratch vault with a tagged note that has a few paragraphs; confirm (for Gleb's check) the spine shows `YYYY-MM-DD · tag1, tag2 · N words` in mono faint under the title, a hairline below it, and the word count changes as you type. Clean up defaults/vault after.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/EditorContainerView.swift
git commit -m "feat(app): editor metadata spine (date, tags, live word count)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Live-markdown rendering — code chips, blockquote, heading sizes

**Files:**
- Modify: `Packages/NoterEditor/Sources/NoterEditor/EditorTheme.swift`
- Modify: `Packages/NoterEditor/Sources/NoterEditor/MarkdownTextView.swift`

**Interfaces:**
- Consumes: `MarkdownHighlighter.spans` (existing), the theme
- Produces: richer per-span rendering. Heading sizes drop to 22/19/17 (so a body H1 sits below the 24px note title); inline code and code blocks get an `elevated` background chip; blockquotes get a paragraph indent.

- [ ] **Step 1: Add codeBackground to EditorTheme and retune headings**

In `Packages/NoterEditor/Sources/NoterEditor/EditorTheme.swift`:

Add the stored property after `bg`:
```swift
    public let codeBackground: NSColor
```

Change the `headingFonts` dictionary in `standard()` to:
```swift
            headingFonts: [
                1: NSFont.systemFont(ofSize: 22, weight: .semibold),
                2: NSFont.systemFont(ofSize: 19, weight: .semibold),
                3: NSFont.systemFont(ofSize: 17, weight: .semibold)
            ],
```

And add the `codeBackground` argument to the `EditorTheme(...)` initializer call, after `bg:`:
```swift
            bg: named("bg", fallback: .textBackgroundColor),
            codeBackground: named("elevated", fallback: NSColor.textBackgroundColor.blended(withFraction: 0.06, of: .white) ?? .textBackgroundColor)
```

- [ ] **Step 2: Apply the new attributes in restyle()**

In `Packages/NoterEditor/Sources/NoterEditor/MarkdownTextView.swift`, replace the `switch span.kind` block's `inlineCode`/`codeBlock` and `blockquote` cases:

```swift
                case .inlineCode, .codeBlock:
                    storage.addAttributes([
                        .font: theme.monoFont,
                        .foregroundColor: theme.secondary,
                        .backgroundColor: theme.codeBackground
                    ], range: span.range)
                case .link:
                    storage.addAttribute(.foregroundColor, value: theme.accent, range: span.range)
                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: span.range)
                case .blockquote:
                    let quoteStyle = NSMutableParagraphStyle()
                    quoteStyle.firstLineHeadIndent = 16
                    quoteStyle.headIndent = 16
                    storage.addAttributes([
                        .foregroundColor: theme.secondary,
                        .paragraphStyle: quoteStyle
                    ], range: span.range)
```

Note: the base `setAttributes` at the top of `restyle()` resets `.paragraphStyle`/`.backgroundColor` implicitly only for `.font`/`.foregroundColor` — it does NOT clear a stale `.backgroundColor` or `.paragraphStyle` from a previous pass. Add these two lines to the base `setAttributes` dictionary so every restyle starts clean:

```swift
            storage.setAttributes([
                .font: theme.bodyFont,
                .foregroundColor: theme.fg,
                .backgroundColor: NSColor.clear,
                .paragraphStyle: NSParagraphStyle.default
            ], range: full)
```

- [ ] **Step 3: Build and confirm the highlighter suite still passes**

Run: `cd Packages/NoterEditor && swift test`
Expected: 9/9 PASS (these test `MarkdownHighlighter`, which is untouched — this proves no regression).

Run: `cd /Users/glebstarcikov/rusty-noter && xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. If `NSColor.blended(withFraction:of:)` returns optional and the initializer complains, the `?? .textBackgroundColor` fallback already handles it; if the whole expression is rejected, replace the `codeBackground:` argument with `named("elevated", fallback: .underPageBackgroundColor)`.

- [ ] **Step 4: Visual smoke**

Launch against a scratch vault holding a note with a heading, bold, inline `code`, a fenced code block, a `> blockquote`, a list, and a `[link](url)`. For Gleb's check: heading sized below the title, bold semibold, inline code in a subtle chip, code block shaded, blockquote indented in secondary, link in accent, list marker faint. Confirm typing still restyles live with no caret jump. Clean up after.

- [ ] **Step 5: Commit**

```bash
git add Packages/NoterEditor
git commit -m "feat(editor): code chips, blockquote indent, tuned heading sizes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Impeccable spacing and interaction-state pass

**Files:**
- Modify: `App/Sources/SidebarView.swift`, `App/Sources/RustyNoterApp.swift`, and any of `NoteListView.swift` / `EditorContainerView.swift` needing spacing touch-ups.

This is the systematic polish task — judgment-driven, verified on-screen, not by unit tests. It is the one task where the implementer should invoke the `impeccable` skill to drive the pass rather than eyeballing.

**Interfaces:**
- Consumes: everything built so far
- Produces: consistent spacing, hierarchy, and states across every surface. No new behavior.

- [ ] **Step 1: Invoke the impeccable skill and run its pass over the app surfaces**

Announce and invoke `impeccable`. Apply its guidance to `SidebarView`, `NoteListView`, `EditorContainerView`, and the `RustyNoterApp` toolbar/split view, against the checklist below. Keep changes to spacing, alignment, typography, and states — no behavior changes, no new features.

Checklist (the acceptance bar):
- Every gap/pad is on the 4px scale (4/8/12/16/24/32). No off-scale values remain.
- At most one mono uppercase label per view section (design.md discipline).
- Sidebar: consistent row height, icon optical alignment, `accent-soft` selection matching the list's selection exactly.
- List-column header (in `RustyNoterApp`'s content column): replace the "Rusty Noter" navigation title with the active scope name plus a mono note count (e.g. "All Notes · 66"), so branding leaves the working area. Use `model.sidebarSelection` for the scope name and `model.visibleNotes.count`.
- Editor: title, spine, and body share one left margin (48px), body prose measure ~62ch preserved.
- Visible 2px `accent` focus rings on focusable controls; hover feedback on rows and sidebar items; reduced-motion honored (gate any added animation on `accessibilityReduceMotion`).
- No em-dashes introduced in any string.

- [ ] **Step 2: Build**

Run: `cd /Users/glebstarcikov/rusty-noter && xcodegen generate && xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. Both package suites still green.

- [ ] **Step 3: Gleb's visual sign-off checkpoint**

This task's acceptance is Gleb's eyes, not automation. Launch against a fixture vault, and hand Gleb the before/after: the whole app should read as consistent and considered — even spacing rhythm, aligned margins, coherent selection/hover, orientation header. Record his sign-off (or the specific tweaks he wants) before committing. If he wants tweaks, apply them and re-check.

- [ ] **Step 4: Commit**

```bash
git add App/Sources
git commit -m "polish(app): impeccable spacing, alignment, and state pass

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Fold decisions back into design.md, acceptance record, tag

**Files:**
- Modify: `~/design/design.md` (separate repo)
- Create: `docs/superpowers/plans/2026-07-14-ui-refresh-acceptance.md`

**Interfaces:**
- Consumes: the shipped refresh
- Produces: the design-system fold-back (spec §3) and a short acceptance record; tag `v0.2.0`.

- [ ] **Step 1: Update design.md with the two decisions**

In `~/design/design.md`, under the components/surfaces area, add two short entries (matching the file's existing prose voice):
- **Inset rounded row** (list-of-items surfaces): rows with internal padding and a soft rounded-rect fill on hover (`elevated`) and selection (`accent-soft`), in an inset list, separated by rhythm rather than hairlines. An approved alternative to hairline rows for lists like a note list, mail list, or file list. Hairline rows remain correct for dense tables.
- **Editor metadata spine**: under a document title, a single mono line of `faint` metadata (date · tags · word count), separated from the body by one hairline. Gives a writing surface context without chrome.

Commit in the design repo:
```bash
cd ~/design && git add design.md && git commit -m "Add inset-rounded-row and editor-spine patterns

Folded back from rusty-noter UI refresh (2026-07-14).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && cd /Users/glebstarcikov/rusty-noter
```

- [ ] **Step 2: Write the acceptance record**

`docs/superpowers/plans/2026-07-14-ui-refresh-acceptance.md`: a short checklist of what shipped and Gleb's visual sign-off, in the honest verified/human-confirmed split style of the Phase 1 acceptance doc. Record: NoteGrouping + WordCount test counts; build succeeded; and Gleb's confirmation of the visual items (grouped list, inset rounded rows + hover/selection, editor spine + live word count, markdown rendering, spacing consistency).

- [ ] **Step 3: Commit and tag**

```bash
git add docs/superpowers/plans/2026-07-14-ui-refresh-acceptance.md
git commit -m "test: UI refresh acceptance record

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git tag v0.2.0
```

---

## Spec coverage map (plan self-review)

| Spec section | Task |
|---|---|
| §4.1 time grouping (buckets, order, search-suppressed) | Task 1 (pure) + Task 3 (AppModel wiring) |
| §4.2 inset rounded rows (hover/selection, no separators, relative date) | Task 4 + Task 1 rowDateLabel |
| §4.3 list-column header (scope + count) | Task 7 |
| §5.1 editor metadata spine (date · tags · live word count) | Task 2 (word count) + Task 5 |
| §5.2 live-markdown rendering (heading sizes, code chip, code block, blockquote, link, list marker) | Task 6 |
| §5.2 blockquote drawn rule / rounded chip (stretch) | Task 7 (attempt during polish; attribute baseline shipped in Task 6) |
| §6 impeccable spacing/hierarchy/state pass | Task 7 |
| §3 design.md fold-back | Task 8 |
| §8 testing (unit + build + Gleb visual) | Tasks 1–2 unit; 3–7 build + Gleb; Task 8 acceptance record |

Known intentional properties (report, don't expand): the blockquote left rule and rounded code-chip corners are attribute-only-baseline in Task 6 and only attempted as a drawn pass in Task 7 — do not block on them. Visual tasks (4–7) are build-verified by the implementer and pixel-verified by Gleb; this refresh deliberately puts a human in the loop for visual acceptance rather than deferring it as Phase 1 did.

Execution note: this machine has the toolchain (macOS 26.4, Xcode 26.4). If a SwiftUI/AppKit API in a task fails to compile (List section styling, `scrollContentBackground`, `NSColor.blended`), verify current usage via Context7 before improvising, per the global documentation rule.


