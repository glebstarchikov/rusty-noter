# Rusty Noter: Design

Date: 2026-07-11
Status: approved (brainstorm complete, pre-implementation)
Design system: [glebstar/design](file:///Users/glebstarcikov/design/design.md) (Crafted Minimal, native theme)

## 1. Product summary

Rusty Noter (working name; pure Swift, the name is ironic) is a native macOS AI note-taking app. Notes are plain markdown files on disk. The app captures meetings from microphone and system audio, transcribes them locally with Whisper, and summarizes them locally with Apple Foundation Models. Quiet AI keeps notes titled, tagged, and linked. AI agents (Claude Code, Codex, Claude Desktop) are first-class consumers of the notes via three access doors. Nothing ever leaves the Mac.

There is deliberately no chat UI in the app: Claude is the chat interface. The app is the capture and editing surface.

## 2. Goals and non-goals

Goals:

- Notes as plain `.md` files that any agent or tool can read and write directly.
- Fully local AI: transcription, summaries, and organization run on device.
- Meeting capture with both microphone and system audio, usable for online meetings.
- Live transcript on disk during a meeting so Claude can answer questions mid-call.
- Interface follows the Crafted Minimal design system with native Liquid Glass chrome.
- Instant agent orientation: one file read gives an agent the full map of the vault.

Non-goals (v1):

- No in-app chat or RAG pipeline (agents handle retrieval; embeddings are a parked addition).
- No sync, no cloud, no accounts, no collaboration.
- No iOS/iPadOS.
- No Mac App Store distribution (sandbox conflicts with system audio capture).
- No full WYSIWYG editor (live-styled markdown source instead).
- No speaker diarization beyond the mic/system channel split.

## 3. Hard requirements

1. Files are the single source of truth. Every derived structure (search index, INDEX.md, in-app list) is a rebuildable cache. Deleting all caches loses nothing.
2. Fully local. No network calls for AI features. The only downloads are Whisper model files, fetched explicitly with user consent.
3. Agent-native. File conventions are designed to be discovered and used by agents; the app never holds notes hostage to proprietary state.
4. Native macOS. SwiftUI, Liquid Glass chrome, system conventions, keyboard-first.

## 4. Decision log

| Decision | Choice | Why | Rejected |
|---|---|---|---|
| Stack | Pure Swift / SwiftUI, macOS 26 minimum | Native Liquid Glass, Foundation Models, smallest codebase | Rust core + FFI (no benefit for a file-based app), Tauri (glass would be fake) |
| Storage architecture | Files + FTS5 cache + MCP server ("approach C") | Files stay the truth; instant search at any scale; MCP serves non-filesystem clients | DB-first (files become stale projections), files-only (user chose the fuller build) |
| Transcription | WhisperKit (CoreML), `large-v3-turbo` default | Best multilingual quality (RU/NL/EN/mixed); RAM used only while recording | Apple SpeechTranscriber (limited locales), whisper.cpp via daemon |
| Text intelligence | Apple Foundation Models behind a `TextIntelligence` protocol | OS-managed lifecycle, zero resident RAM, zero install | Ollama (resident daemon; kept as a future provider if FM summary quality disappoints) |
| System audio capture | Core Audio process tap | Modern API purpose-built for audio-only capture; clean TCC prompt | ScreenCaptureKit audio (screen-capture permission context) |
| Distribution | Direct (notarized Developer ID; local builds until then) | Sandbox makes system audio capture miserable | Mac App Store |
| Meeting file shape | One file: summary on top, transcript below | One `rg` hit finds everything; no orphan transcript files | Separate transcript files |
| Speaker labels | Channel split: mic = `Me:`, system = `Them:` | 80% of diarization value for 5% of the complexity | Local diarization models (parked) |

## 5. Data model

### 5.1 Folder layout

Default vault: `~/Notes` (changeable in Settings; path stored in UserDefaults, no sandbox).

```
~/Notes/
  INDEX.md          generated map, one table row per note
  CLAUDE.md         generated agent conventions
  AGENTS.md         generated, same content for Codex and friends
  <notes>.md        flat by default; user may create any subfolders
  meetings/
    <meeting notes>.md
    audio/<recordings>.m4a
```

Every `.md` under the vault root is a note, except the three generated files and hidden files/folders. Subfolders are mirrored in the sidebar.

### 5.2 Frontmatter schema

```yaml
---
title: Standup with Anna
type: meeting            # note | meeting; default note
created: 2026-07-11T09:30:00+02:00
updated: 2026-07-11T09:55:12+02:00
tags: [work, standup]    # lowercase kebab-case
# meeting-only keys:
audio: audio/2026-07-11-standup-with-anna.m4a
duration: 47m
status: recording        # present ONLY while capture is live; removed on finalize
---
```

Rules:

- Timestamps are ISO 8601 with local offset.
- `status: recording` marks a live meeting. Agents treat such notes as read-only and re-read them for the latest transcript. `grep -l "status: recording"` finds any live meeting.
- A note whose frontmatter fails to parse is still listed (filename as title, quiet warning in UI). The app never rewrites a body it could not parse.

### 5.3 Filenames

`YYYY-MM-DD-slug.md`. Slug: lowercase, ASCII-transliterated, hyphens, max 60 chars, `-2` suffix on collision. New notes start as `YYYY-MM-DD-untitled.md`; auto-title renames the file once (within the grace period, see 9.2). After that, filenames are stable; title changes live in frontmatter only. Rename is available as an explicit user action.

### 5.4 INDEX.md

Regenerated (debounced ~2s) on any vault change. Sorted by `updated` descending.

```markdown
# Notes Index

Generated by Rusty Noter. Do not edit; changes are overwritten.

| Updated | Title | Type | Tags | Path |
|---|---|---|---|---|
| 2026-07-11 | Standup with Anna | meeting (recording) | work, standup | meetings/2026-07-11-standup-with-anna.md |
| 2026-07-10 | API pricing ideas | note | product | 2026-07-10-api-pricing-ideas.md |
```

### 5.5 Live meeting notes

The meeting note is created the moment recording starts. Finalized Whisper segments are appended (atomic write, debounced ~5s), each line as `- **HH:MM:SS Me:** text` or `- **HH:MM:SS Them:** text` under `## Transcript`. On stop: summary sections are written above the transcript, `status` is removed, `duration` is set. This one mechanism is simultaneously the mid-meeting Claude feature and crash recovery.

### 5.6 Audio

Stereo m4a, mic on left channel, system audio on right, written incrementally via AVAssetWriter. Retention setting: keep forever (default) / delete after transcription / keep 30 days.

### 5.7 Caches (Application Support)

`~/Library/Application Support/RustyNoter/`: `index.db` (SQLite FTS5 via GRDB), `models/` (WhisperKit), `recovery/` (in-flight recording state). All disposable; the app rebuilds `index.db` from the vault when missing or corrupt.

## 6. Agent access

### 6.1 Claude skill

Authored in-repo under `claude-skill/`, installed by the app to `~/.claude/skills/notes/` (one click in Settings). Teaches: read `INDEX.md` first (one read = full map); frontmatter schema; `rg` recipes for content search; write conventions (frontmatter required, touch `updated`, respect `status: recording` as read-only); live-meeting awareness.

### 6.2 Generated CLAUDE.md / AGENTS.md

Same conventions, placed in the vault root, for any agent that lands in the folder without the skill. Regenerated with the vault path baked in whenever the vault moves.

### 6.3 MCP server

`noter-mcp`, a stdio executable inside the app bundle, for clients without filesystem access (Claude Desktop, claude.ai). Reads the same files and the same FTS index (read-only on `index.db`, falls back to a filesystem scan when the index is missing).

Tools: `search_notes(query, limit?, tags?, type?)` (FTS + recency ranking), `read_note(path)`, `list_recent(limit?)`, `create_note(title, body, tags?)`, `get_live_transcript()` (returns the current `status: recording` note or null). Deliberately no delete tool: agents cannot destroy notes. Settings shows the registration one-liner (`claude mcp add ...` and Claude Desktop config snippet).

## 7. Architecture

One Xcode workspace, SPM packages:

| Module | Responsibility | Depends on |
|---|---|---|
| `NoterCore` | Note model, NotesStore (CRUD, frontmatter codec, atomic writes), FolderWatcher (FSEvents), SearchIndex (GRDB/FTS5), IndexWriter (INDEX.md, CLAUDE.md, AGENTS.md) | GRDB, Yams |
| `NoterAI` | `TextIntelligence` protocol + FoundationModelsProvider; `Transcriber` protocol + WhisperKitTranscriber; map-reduce chunker | FoundationModels, WhisperKit |
| `NoterCapture` | AudioCaptureService (AVAudioEngine mic + Core Audio process tap), stereo m4a writer, level metering, recording state machine | AVFoundation, CoreAudio |
| `NoterMCP` | stdio MCP server executable | NoterCore, MCP Swift SDK |
| `RustyNoter` (app) | SwiftUI app, view models, settings, onboarding, menu bar extra | all of the above |

Principles:

- Swift 6 strict concurrency. `NotesStore` and `SearchIndex` are actors. View models are `@Observable`.
- Write path: app edits go through NotesStore (atomic temp+rename). The watcher suppresses echo events for self-writes (path + content-hash window) so self-edits are not re-processed as external.
- External edits (Claude, vim, anything) flow: FSEvents -> re-parse changed files -> update SearchIndex + INDEX.md + UI. Target under 1s from external write to UI/list refresh.
- The MCP binary never writes `index.db`; only the app maintains caches. `create_note` writes the md file; the app's watcher (if running) picks it up, and the index catch-up scan at next app launch covers the app-closed case.

## 8. Meeting capture pipeline

1. Start (toolbar button, menu bar extra, or Cmd+Shift+R). First run prompts: microphone TCC, then system audio TCC (NSAudioCaptureUsageDescription). Denials get a guidance screen deep-linking to the exact System Settings pane.
2. Capture mic via AVAudioEngine input; system audio via a Core Audio process tap on the default output (system-wide, v1; per-app selection parked). Both feed the stereo m4a writer immediately.
3. Voice-activity-gated chunks go to WhisperKit per channel. Segments land a few seconds behind realtime, labeled by source channel, and stream into the live note file (5.5). Live transcript is also shown in the app.
4. Stop: assemble final transcript (interleaved by timestamp), run summarization (9.1), write summary above transcript, finalize frontmatter, move on. If Foundation Models is unavailable, keep the transcript-only note with a "Summarize" banner for later.
5. Recovery: on launch, orphaned recovery state (audio without finalized note) offers one-click "transcribe and finalize". Transcription lag never drops audio: if WhisperKit falls behind, remaining audio is transcribed after stop.

## 9. Intelligence features

All text tasks go through `TextIntelligence` (summarize, title, tags, rewrite, continue, fix). v1 provider: Foundation Models with guided generation (`@Generable`) for structured outputs. A future OllamaProvider slots in via Settings if FM summary quality disappoints; no feature code changes.

### 9.1 Meeting summaries

Sections: TL;DR, Action items, Decisions, Topics. Foundation Models context is small (~4k tokens), so long transcripts are map-reduced: summarize windows, merge summaries. The chunker lives behind the protocol; a large-context provider skips it. Prompt changes must pass the eval checklist (12).

### 9.2 Auto-title

When an untitled note reaches ~50 words, FM proposes a title; file renamed once per 5.3. No further automatic renames.

### 9.3 Auto-tags

FM suggests up to 3 tags constrained to the existing tag vocabulary (plus at most 1 new tag proposal, visually distinct). Shown as accept/dismiss chips near the title; never silently applied.

### 9.4 Related notes

v1: FTS term-overlap ranking, shown in the inspector. Embeddings are the parked upgrade (15).

### 9.5 Inline tools

Selection toolbar: Summarize / Rewrite / Fix / Continue. Results appear as accept/reject preview, never auto-replacing text.

## 10. UI design

### 10.1 Structure

Three-pane `NavigationSplitView`: sidebar (All Notes, Meetings, tags, folders) / note list / editor. Note list rows: title in `fg`, snippet in `secondary`, mono date in `faint`, hairline separators. Rows, not cards. Inspector panel (toggleable): metadata, tags, related notes. Menu bar extra: quick capture, start/stop recording. Command palette on Cmd+K.

### 10.2 Liquid Glass placement

Glass lives on the chrome layer only, never on content:

- System-provided: toolbar, sidebar translucency.
- Recording pill: the record button morphs (`glassEffectID` within a `GlassEffectContainer`) into a floating glass capsule (waveform, timer, stop). The one deliberate showpiece morph.
- Cmd+K palette and the selection AI toolbar: small glass panels.
- Editor and note list stay on opaque `bg`.

### 10.3 Native theme of Crafted Minimal

Fonts and radii are the theme layer per design.md, so this app is the "native theme":

- Fonts: SF Pro for UI and prose; SF Mono for the mono texture (timestamps, tags, kbd chips, section labels, transcript timestamps). Mono-label discipline holds: at most one mono uppercase label per view section.
- Colors: all 12 semantic tokens from tokens.css as asset colors with light/dark variants (accent `#4b46f5` / `#8a86ff`, etc.). Accent strictly interaction-only. Recording indicator uses `danger` (recording is status).
- On glass surfaces: system label colors only (vibrancy guarantees legibility). Tokens rule every opaque surface, where the 4.5:1 floor is verified with `contrast.py` math.
- Spacing on the 4px scale; radii sm 6 / md 10 / lg 14 on drawn panels; micro-transitions 150-180ms ease; glass morphs use system springs; reduced motion honored everywhere.
- Working-surface density: 14px base UI text; 12px mono metadata. Editor is a Reading surface: 16px body, ~62ch measure.
- Copy rules apply to all UI strings: no em-dashes, empty states are one sentence plus at most one action, inline status near the cause instead of toasts where possible.

### 10.4 Keyboard map

Cmd+N new note, Cmd+Shift+R record toggle, Cmd+K palette, Cmd+F find in note, Cmd+Shift+F global search, Cmd+, settings, Esc walks back (palette, inspector, recording confirm). Visible 2px accent focus rings; kbd chips on hints.

### 10.5 Editor

Live-styled markdown source (iA Writer school): headings sized up, bold/italic rendered, links in accent, syntax glyphs visible but faint. Not hidden-syntax WYSIWYG. Implementation spike decides between macOS 26 SwiftUI TextEditor with AttributedString vs an NSTextView wrapper (16).

### 10.6 Settings

Vault location; Whisper model picker with download progress and disk usage; text AI provider (Foundation Models; Ollama listed as "coming later"); Claude skill install button; MCP registration snippet; audio retention; launch menu bar extra at login.

## 11. Error handling

- All file writes atomic (temp + rename in same directory).
- Unparseable frontmatter: note listed by filename, quiet warning, body untouched.
- External delete/rename while a note is open: editor shows a non-destructive "note was moved or deleted" state with the last content recoverable.
- Permission denials: guidance screens with deep links to System Settings; app remains usable without capture.
- Foundation Models unavailable (Apple Intelligence off, model not ready): availability check, transcript-only notes, "Summarize" retry banner. Auto-organize features quietly pause.
- WhisperKit model download failure: resumable retry with clear error.
- `index.db` missing or corrupt: silently rebuild from files.
- Vault folder missing at launch (moved/renamed/unmounted): picker to relocate, never auto-create a new empty vault over a lost one.

## 12. Testing strategy

- Unit (the bulk): frontmatter codec round-trips including hostile YAML; slug and rename logic; INDEX.md generation; FTS-vs-filesystem sync across create/edit/delete/external-edit; transcript channel interleaving; map-reduce chunker boundaries; echo suppression.
- Integration: NotesStore + real FolderWatcher against temp dirs with concurrent external mutations; MCP server driven over real stdio with golden JSON-RPC transcripts; crash-recovery path (orphaned audio + partial note, then finalize); WhisperKit smoke test on a bundled 10s fixture wav (slow suite, opt-in).
- AI: features tested against a deterministic `MockTextIntelligence`. Model output quality is gated by a manual eval checklist in `docs/evals.md`; every prompt change re-runs it (engineering principle 4).
- UI: thin smoke tests only; manual QA checklist for permission flows and onboarding.

## 13. Build phases

Each phase ends with something used daily.

1. **Vault + editor.** NoterCore complete (store, watcher, FTS, generated files), three-pane UI, live-styled editor, search, Cmd+K, settings (vault). Accept: create/edit/search notes; external edit visible in app under 1s; INDEX.md and CLAUDE.md/AGENTS.md correct; search instant on a 1k-note fixture vault.
2. **Claude skill.** Authored and installable. Accept: in a fresh Claude Code session, "find my note about X" resolves via one INDEX.md read plus at most one rg; write conventions followed on a created note.
3. **Meeting capture.** Mic + system tap, stereo m4a, live WhisperKit transcript streaming into the note, recovery. Accept: record a real call; `Me:`/`Them:` labels correct; kill -9 mid-meeting recovers to a complete transcript; Claude answers a question from the live file mid-meeting.
4. **Intelligence.** Summaries with map-reduce, auto-title, auto-tags, related notes, inline tools. Accept: meeting summary passes eval checklist; renames happen once; tags never silently applied.
5. **MCP server + polish.** noter-mcp with the five tools, menu bar extra, audio retention, onboarding. Accept: Claude Desktop searches and reads notes via MCP; get_live_transcript works during a recording.

## 14. Prerequisites

- Apple Intelligence enabled on the Mac for Foundation Models features (app degrades gracefully without it).
- Whisper model download (~1.5GB) on first transcription use.
- Apple Developer ID only when distribution starts; local builds until then.

## 15. Parked (explicitly not v1)

Semantic search / embeddings (sqlite-vec next to FTS, `semantic_search` MCP tool); OllamaProvider; per-app audio capture selection; meeting-app detection nudge; local diarization; user-editable summary templates; App Store variant; iOS.

## 16. Open technical spikes (resolve during planning/implementation)

1. Editor: macOS 26 SwiftUI TextEditor + AttributedString capability vs NSTextView wrapper. Verify with current docs before Phase 1 editor work.
2. Core Audio process tap: exact API surface (`AudioHardwareCreateProcessTap`, aggregate device wiring) and TCC behavior. Verify before Phase 3.
3. WhisperKit streaming configuration: chunk/VAD settings for near-realtime per-channel transcription on M4 Pro. Verify before Phase 3.
4. Foundation Models: confirm context window, `@Generable` guided generation API shape, and availability API. Verify before Phase 4.
5. MCP Swift SDK maturity for stdio servers; fall back to hand-rolled JSON-RPC (small, stable protocol) if the SDK disappoints. Verify before Phase 5.

Verification for all spikes: Context7 docs plus a minimal compiling probe, per the global rule of never trusting training-data memory for API surfaces.
