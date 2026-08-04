# Audio Capture (Phase 3, subsystem A): Design

## 1. Scope

Phase 3 in the master spec ("meeting capture") bundles four independently large
subsystems. This document covers only the first:

| | Subsystem | Status |
|---|---|---|
| **A** | **Audio capture — mic + system audio → stereo m4a, permissions, note lifecycle** | **this spec** |
| B | Transcription (WhisperKit, model download, VAD chunking) | later cycle |
| C | Live transcript streaming into the note | later cycle |
| D | Crash recovery and finalization | later cycle |

A ships something usable on its own: **record a meeting, get a playable stereo
recording attached to a note.** No transcription.

## 2. Feasibility: already proven

The riskiest assumption in the master spec — that a Core Audio process tap can
capture system audio — was verified on 2026-08-02 with a throwaway spike:
924 IO callbacks, 473,088 frames over ~10s, rms ≈0.03 on both channels of real
system output. The spike is deleted; its findings are recorded here and in the
`macos-system-audio-tap` memory.

Four non-obvious facts, each of which cost an iteration:

- **`AudioDeviceCreateIOProcIDWithBlock` must be given a real `DispatchQueue`.**
  With `nil` the IO proc fires exactly once and then never again — no error, no
  warning. This was diagnosed by diffing against a working reference
  implementation, not by reasoning.
- **A tap is not a device.** It answers `kAudioTapPropertyFormat` (`'tfmt'`);
  the device stream-format property returns `kAudioHardwareBadObjectError`.
- **`withUnsafePointer(to:) { $0 }` returns a dangling pointer.** Building
  `AVAudioFormat` from it yields a non-PCM format that crashes inside the IO
  proc with `required condition is false: isPCMFormat(fmt)`, three layers from
  the mistake. Construct the format inside the closure.
- **The tap delivers interleaved float32** (48 kHz, 2 ch, `mFormatFlags = 9`).
  `floatChannelData[1]` does not exist; index
  `floatChannelData[0][frame * stride + channel]`.

## 3. Decisions

| Decision | Choice | Why |
|---|---|---|
| Tap scope | Global (`stereoGlobalTapButExcludeProcesses: []`) | Works with any conferencing tool, zero configuration. Matches the master spec |
| Per-app capture | Parked | macOS 26 adds `CATapDescription.bundleIDs`, making it nearly free later, but it costs a picker and silently captures nothing if the user picks wrong |
| Package | New `Packages/NoterAudio` | Audio is not a vault concern; burying it in `App/` would make it untestable |
| Audio location | `<vault>/audio/<slug>.m4a` | Vault-relative, matching the master spec's `audio:` frontmatter key |
| Retention setting | Parked for B | "Delete after transcription" presupposes transcription. Default: keep forever |
| Note creation | At recording start | `status: recording` is the recovery marker, the live-transcript target, and the agent read-only signal |

## 4. Architecture

```
Packages/NoterAudio
├── AudioPermissions      mic + system-audio authorization status and request
├── SystemAudioTap        CATapDescription → aggregate device → IO proc
│                         emits interleaved float32 @ 48 kHz stereo
├── MicrophoneInput       AVAudioEngine input tap → mono buffers
├── StereoRecorder        aligns both sources → mic = L, system = R → m4a
└── RecordingSession      public façade: start() / stop(), observable state
```

Only `RecordingSession` is public to the app, mirroring how `VaultCoordinator`
fronts the store, watcher and index. The app never touches a `CATapDescription`.

### 4.1 The system tap

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, with
   `isPrivate = true` and `muteBehavior = .unmuted` — the user must keep hearing
   the call.
2. `AudioHardwareCreateProcessTap`.
3. Aggregate device with `name`, `uid`, `master` (the default output device's
   UID, required), `private: true`, `stacked: false`, `tapautostart: true`,
   `subdevices: [{uid: outputUID}]`,
   `taps: [{driftcompensation: true, uid: tapDescription.uuid.uuidString}]`.
4. `AudioDeviceCreateIOProcIDWithBlock` **with a serial `DispatchQueue`**, then
   `AudioDeviceStart`. Tap audio arrives in `inInputData`.

Teardown destroys the IO proc, the aggregate device and the tap. The spike leaked
all three on its error paths; the real implementation tears down on every exit
path, including failure.

### 4.2 StereoRecorder — the hard part

Mic and system audio are independent sources with separate clocks, different
sample rates, and buffers arriving at unrelated times. Interleaving whatever
arrives causes drift, and drift slides the "Me" and "Them" channels out of sync —
which corrupts the `Me:`/`Them:` labelling that the entire transcript format in
subsystems B and C depends on.

Design:

- Each source converts to a common 48 kHz mono format via `AVAudioConverter`.
- Each writes into its own ring buffer, keyed by host time.
- A writer drains both on a fixed cadence, pairing frames by timestamp and
  padding a channel with silence when that source has not delivered — the mic is
  always live, but system audio produces nothing while nobody is speaking.

The cadence is deadline-driven, never arrival-driven. This alignment logic is
pure given two timestamped buffer streams, so it is fully unit-testable without
hardware (§8).

### 4.3 Segmented writing

An `AVAssetWriter` file that is never finalized is not a truncated-but-valid
recording — it is unplayable. Losing an hour-long meeting to a crash is the
largest data-loss risk in this phase.

`AVAssetWriter` cannot reopen a finalized file, so "finalize periodically" means
writing a sequence of files rather than one:

- Audio is written in **30-second segments** into
  `~/Library/Application Support/RustyNoter/recording/<session-id>/NNNN.m4a`,
  each finalized as it completes.
- On stop, the segments are concatenated into the final
  `<vault>/audio/<slug>.m4a` and the session directory is removed.
- A crash therefore leaves a directory of valid, playable segments. Recovering
  them is D's job; A's obligation is to ensure something recoverable exists.

30 seconds trades a bounded worst-case loss against writer churn. The session
directory lives in Application Support, not the vault, because partial segments
are not notes and must never be indexed or shown.

## 5. Vault artifacts

```
~/Notes/
├── 2026-08-02-meeting-1430.md       created when recording starts
└── audio/
    └── 2026-08-02-meeting-1430.m4a  stereo: mic = L, system = R
```

**At start:** the note is created with `type: meeting` and `status: recording`.
That flag is the crash-recovery marker (D), the append target for the live
transcript (C), and the signal the shipped Phase 2 skill already teaches agents
to treat as read-only and re-read for fresh content.

**At stop:** finalize the m4a, write `audio:` (vault-relative) and `duration:`,
remove `status`. The watcher republishes and the note appears like any other.

### 5.1 Two exclusions this introduces

Both are deliberate changes in `NoterCore`, not incidental:

1. **`AppModel.topLevelFolders` derives from any note path containing `/`**, so
   an `audio/` directory would appear as a folder in the sidebar. Audio paths
   must be excluded.
2. **The FTS indexer and note store walk the vault** and must ignore `.m4a`
   files and the `audio/` directory entirely. They are not notes.

## 6. Permissions

Two separate grants, failing in different ways:

- **Microphone** — the familiar prompt; denial is explicit.
- **Screen & System Audio Recording** — proven by the spike to fail *silently*:
  the tap runs, delivers the correct frame count, and every sample is 0.0.

Because of this, the app must check authorization explicitly and refuse to start
when it is missing. It must never infer permission from "did the tap start",
which would produce a recording that looks successful and contains only one side
of the conversation.

Denial shows a guidance screen deep-linking the exact System Settings pane
(master spec §8.1). Both usage strings are required in the app's Info.plist:
`NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`.

## 7. UI

Small, because most of it already exists:

- Record button in the toolbar, plus ⌘⇧R.
- Elapsed time while recording.
- `NoteRow` already renders a red dot for `status == .recording` — built during
  the UI refresh and currently unreachable. This is what lights it up.

## 8. Failure handling and testing

**No `try?` on anything the user needs to know about.** The spike produced a
4 KB header-only file because every write failed into a swallowed error. Cases
that must surface: permission denied, no default output device, tap creation
failure, disk full mid-recording, writer failure. A recording that stops silently
is worse than one that visibly errors, because it is discovered after the meeting.

**Unit-testable without hardware:**

- `StereoRecorder` alignment: drift between sources, one source silent, one
  source delivering late, sample-rate conversion.
- Note lifecycle: `status: recording` → finalized with `duration` and `audio:`.
- The `audio/` and `.m4a` vault exclusions (§5.1).
- Permission state machine, with injected authorization status.

**Explicitly NOT automated: any test that captures real audio.** The spike proved
a headless run reads as silent even when the code is correct, because the TCC
grant follows the bundle launched through LaunchServices — `open Foo.app` has the
permission, executing the binary directly does not. Such a test would fail on
correct code, and the real hazard is that someone would then "fix" a non-bug.
Capture is verified by launching the app and recording something real.

## 9. Acceptance

- Record a real 2-minute call.
- The m4a plays back with the user's voice on the left channel and the other
  party on the right.
- The note finalizes with correct `duration` and `audio:`, and `status` removed.
- Killing the app mid-recording costs at most the last segment, not the file.
- No `audio` folder appears in the sidebar; no `.m4a` appears in search results.

## 10. Out of scope

Transcription, live transcript streaming, crash recovery, summarization, audio
retention policy, and per-app tap selection. Each belongs to a later subsystem or
phase.
