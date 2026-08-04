# Audio Capture (Phase 3A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a meeting — microphone and system audio — into a stereo m4a attached to a meeting note, with no transcription.

**Architecture:** A new `Packages/NoterAudio` holds capture. `SystemAudioTap` (Core Audio process tap) and `MicrophoneInput` (AVAudioEngine) feed `StereoRecorder`, which aligns them by host time into mic=L / system=R and writes 30-second m4a segments. `RecordingSession` is the only public surface. `NoterCore` gains the meeting-note lifecycle; the app gains a record button.

**Tech Stack:** Swift 6.0 strict concurrency, Core Audio, AVFoundation, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-02-audio-capture-design.md`

## Global Constraints

- **macOS 26.0**, Swift 6.0 strict concurrency. Capture types are `Sendable` or actor-isolated; the IO proc runs off the main thread.
- **No new third-party dependencies.** Core Audio + AVFoundation only.
- **No `try?` on anything the user must know about.** The spike produced a 4 KB header-only file because every write failed into a swallowed error. Every failure path surfaces.
- **Never infer permission from a running tap.** The system-audio grant fails *silently*: correct frame counts, all samples 0.0. Check authorization explicitly.
- **Never write an automated test that captures real audio.** TCC follows the LaunchServices-launched bundle, so a headless capture reads as silent even when the code is perfect. Such a test fails on correct code and invites "fixing" a non-bug. Capture is verified by launching the app.
- **Tear down on every exit path**, including failure: IO proc, aggregate device, then tap. The spike leaked all three on its error paths.
- **Build:** `xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug build`
- **Tests:** `swift test --package-path Packages/NoterCore` (87), `swift test --package-path Packages/NoterAudio` (new), `xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS'` (9)
- **New files require `xcodegen generate`.**
- **App path** (`$APP`): `/Users/glebstarcikov/Library/Developer/Xcode/DerivedData/RustyNoter-bccdtssewntkcffozkbztbtgmgou/Build/Products/Debug/RustyNoter.app`
- **Rebuild AND relaunch before judging behavior:** `killall RustyNoter 2>/dev/null; open -n "$APP"`

## File Structure

| File | Responsibility |
|---|---|
| `Packages/NoterAudio/Package.swift` (create) | New SPM package |
| `.../NoterAudio/AudioPermissions.swift` (create) | Mic + system-audio authorization |
| `.../NoterAudio/StereoRecorder.swift` (create) | Host-time alignment, mic=L / system=R |
| `.../NoterAudio/SegmentWriter.swift` (create) | 30s m4a segments, concatenation |
| `.../NoterAudio/SystemAudioTap.swift` (create) | Process tap → aggregate device → IO proc |
| `.../NoterAudio/MicrophoneInput.swift` (create) | AVAudioEngine input tap |
| `.../NoterAudio/RecordingSession.swift` (create) | Public façade |
| `Packages/NoterCore/Sources/NoterCore/NotesStore.swift` (modify) | `startMeeting` / `finishMeeting` |
| `Packages/NoterCore/Sources/NoterCore/VaultCoordinator.swift` (modify) | Coordinator wrappers |
| `App/Sources/RecordingController.swift` (create) | App-side glue: session ↔ AppModel |
| `App/Sources/RustyNoterApp.swift` (modify) | Record button, ⌘⇧R |
| `App/Info.plist` via `project.yml` (modify) | Usage strings |

---

### Task 1: Meeting-note lifecycle in NoterCore

Pure vault work, no audio. Doing it first means the note side is proven before any hardware is involved.

**Files:**
- Modify: `Packages/NoterCore/Sources/NoterCore/NotesStore.swift`
- Modify: `Packages/NoterCore/Sources/NoterCore/VaultCoordinator.swift`
- Test: `Packages/NoterCore/Tests/NoterCoreTests/NotesStoreTests.swift`

**Interfaces:**
- Produces:
  - `NotesStore.startMeeting(title: String, now: Date) throws -> Note`
  - `NotesStore.finishMeeting(_ relativePath: String, audio: String, duration: String, now: Date) throws -> Note`
  - `VaultCoordinator.startMeeting(title:) async throws -> Note`
  - `VaultCoordinator.finishMeeting(_:audio:duration:) async throws -> Note`

- [ ] **Step 1: Write the failing tests**

Add to `NotesStoreTests.swift` inside the existing suite:

```swift
    @Test func startMeetingCreatesARecordingNote() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let now = Date.iso8601Local("2026-08-02T14:30:00+02:00")!

        let note = try await store.startMeeting(title: "Standup", now: now)

        #expect(note.metadata.type == .meeting)
        #expect(note.metadata.status == .recording)
        #expect(note.metadata.audio == nil)
        // The on-disk file must carry the marker: it is what crash recovery and
        // the Claude skill both key on.
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.metadata.status == .recording)
        #expect(reparsed.metadata.type == .meeting)
    }

    @Test func finishMeetingClearsTheRecordingMarkerAndRecordsTheAudio() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let start = Date.iso8601Local("2026-08-02T14:30:00+02:00")!
        let end = Date.iso8601Local("2026-08-02T15:05:00+02:00")!
        let note = try await store.startMeeting(title: "Standup", now: start)

        let done = try await store.finishMeeting(
            note.relativePath,
            audio: "audio/2026-08-02-standup.m4a",
            duration: "00:35:00",
            now: end)

        #expect(done.metadata.status == nil)
        #expect(done.metadata.audio == "audio/2026-08-02-standup.m4a")
        #expect(done.metadata.duration == "00:35:00")
        #expect(done.metadata.updated == end)
        let reparsed = try FrontmatterCodec.parse(
            try String(contentsOf: vault.noteURL(note.relativePath), encoding: .utf8))
        #expect(reparsed.metadata.status == nil)
        #expect(reparsed.metadata.audio == "audio/2026-08-02-standup.m4a")
    }

    /// A meeting note is still a note: it must be found by enumeration, and the
    /// audio file next to it must NOT be. Guards the exclusion the whole design
    /// leans on -- a future change to isNotePath would otherwise break search
    /// and the sidebar in a way that looks unrelated to its cause.
    @Test func audioFilesAreNeverTreatedAsNotes() async throws {
        let vault = try makeTempVault()
        let store = NotesStore(vault: vault)
        _ = await store.loadAll()
        let note = try await store.startMeeting(title: "Standup", now: .now)

        let audioDirectory = vault.root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
        try Data("not really audio".utf8).write(
            to: audioDirectory.appendingPathComponent("2026-08-02-standup.m4a"))

        let files = try vault.enumerateNoteFiles()
        #expect(files.contains(note.relativePath))
        #expect(!files.contains { $0.hasSuffix(".m4a") })
        #expect(!vault.isNotePath("audio/2026-08-02-standup.m4a"))
    }
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --package-path Packages/NoterCore 2>&1 | grep -E "error:|✘" | head
```

Expected: `type 'NotesStore' has no member 'startMeeting'`. (`audioFilesAreNeverTreatedAsNotes` will pass once it compiles — it characterizes existing behavior deliberately.)

- [ ] **Step 3: Implement in NotesStore**

Add to `NotesStore`, next to `create`:

```swift
    /// Creates the meeting note at recording start. `status: recording` is the
    /// crash-recovery marker, the append target for the live transcript, and the
    /// signal the Claude skill reads as "read-only, re-read for fresh content".
    public func startMeeting(title: String, now: Date = .now) throws -> Note {
        let existing = Set((try? vault.enumerateNoteFiles()) ?? []).union(cache.keys)
        let filename = Slug.uniqueFilename(date: now, title: title, existing: existing)
        var metadata = NoteMetadata(title: title, created: now, updated: now)
        metadata.type = .meeting
        metadata.status = .recording
        let note = Note(relativePath: filename, metadata: metadata, body: "")
        try write(note)
        return note
    }

    /// Finalizes the note when recording stops: attach the audio, record the
    /// duration, and clear the recording marker.
    public func finishMeeting(
        _ relativePath: String,
        audio: String,
        duration: String,
        now: Date = .now
    ) throws -> Note {
        guard !unparseablePaths.contains(relativePath) else {
            throw NotesStoreError.refusingToRewriteUnparseable
        }
        guard var note = cache[relativePath] else {
            throw NotesStoreError.noteNotFound(relativePath)
        }
        note.metadata.audio = audio
        note.metadata.duration = duration
        note.metadata.status = nil
        note.metadata.updated = now
        try write(note)
        return note
    }
```

- [ ] **Step 4: Add the coordinator wrappers**

Add to `VaultCoordinator`, next to `updateDraft`:

```swift
    public func startMeeting(title: String) async throws -> Note {
        let note = try await store.startMeeting(title: title)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }

    public func finishMeeting(
        _ relativePath: String,
        audio: String,
        duration: String
    ) async throws -> Note {
        let note = try await store.finishMeeting(
            relativePath, audio: audio, duration: duration)
        try? await index.upsert(note)
        scheduleIndexMd()
        await publishSnapshot()
        return note
    }
```

- [ ] **Step 5: Run to verify they pass**

```bash
swift test --package-path Packages/NoterCore 2>&1 | tail -3
```

Expected: 90 tests passing (87 + 3).

- [ ] **Step 6: Commit**

```bash
git add Packages/NoterCore
git commit -m "feat(core): meeting note lifecycle for recording

startMeeting creates the note with status: recording -- the marker crash
recovery, the live transcript and the Claude skill all key on. finishMeeting
attaches the audio path and duration and clears the marker.

Also pins the exclusion the audio design leans on: .m4a files are never
enumerated as notes, so a future change to isNotePath cannot silently put
recordings into search results."
```

---

### Task 2: StereoRecorder alignment

The hard part, and pure — no hardware, fully test-driven.

**Files:**
- Create: `Packages/NoterAudio/Package.swift`
- Create: `Packages/NoterAudio/Sources/NoterAudio/StereoRecorder.swift`
- Test: `Packages/NoterAudio/Tests/NoterAudioTests/StereoRecorderTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces:
  - `struct AudioChunk: Sendable { let hostTime: UInt64; let samples: [Float] }`
  - `enum ChannelSource { case microphone, system }`
  - `final class StereoAligner` — `append(_ chunk: AudioChunk, from: ChannelSource)`, `drain(upTo hostTime: UInt64) -> [Float]` (interleaved L,R)
  - `StereoAligner.init(sampleRate: Double, framesPerSecond: Double)`

- [ ] **Step 1: Create the package**

`Packages/NoterAudio/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoterAudio",
    platforms: [.macOS(.v26)],
    products: [.library(name: "NoterAudio", targets: ["NoterAudio"])],
    targets: [
        .target(name: "NoterAudio"),
        .testTarget(name: "NoterAudioTests", dependencies: ["NoterAudio"]),
    ]
)
```

Register it in `project.yml` under `packages:`:

```yaml
  NoterAudio:
    path: Packages/NoterAudio
```

and add `- package: NoterAudio` to the `RustyNoter` target's `dependencies`.

- [ ] **Step 2: Write the failing tests**

`Packages/NoterAudio/Tests/NoterAudioTests/StereoRecorderTests.swift`:

```swift
import Testing
@testable import NoterAudio

@Suite struct StereoAlignerTests {
    /// 1 kHz-ish helper: value encodes the frame index so misalignment is visible
    /// in the assertion rather than hidden in an amplitude.
    private func chunk(at hostTime: UInt64, values: [Float]) -> AudioChunk {
        AudioChunk(hostTime: hostTime, samples: values)
    }

    @Test func interleavesMicrophoneLeftAndSystemRight() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2, 3]), from: .microphone)
        aligner.append(chunk(at: 0, values: [-1, -2, -3]), from: .system)

        let frames = aligner.drain(upTo: 3)

        #expect(frames == [1, -1, 2, -2, 3, -3])
    }

    /// The microphone is always live but system audio is silent whenever nobody
    /// is speaking. A missing source must pad, never stall or shift the other
    /// channel -- a shift here desynchronises Me:/Them: for the rest of the call.
    @Test func padsWithSilenceWhenOneSourceHasNotDelivered() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2, 3]), from: .microphone)

        let frames = aligner.drain(upTo: 3)

        #expect(frames == [1, 0, 2, 0, 3, 0])
    }

    @Test func lateArrivingSourceDoesNotShiftTheOtherChannel() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2]), from: .microphone)
        _ = aligner.drain(upTo: 2)                       // system was silent here

        aligner.append(chunk(at: 2, values: [3, 4]), from: .microphone)
        aligner.append(chunk(at: 2, values: [-3, -4]), from: .system)
        let frames = aligner.drain(upTo: 4)

        // System audio resumes aligned to frame 2, NOT replayed from frame 0.
        #expect(frames == [3, -3, 4, -4])
    }

    @Test func drainsOnlyUpToTheRequestedDeadline() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2, 3, 4]), from: .microphone)
        aligner.append(chunk(at: 0, values: [-1, -2, -3, -4]), from: .system)

        #expect(aligner.drain(upTo: 2) == [1, -1, 2, -2])
        #expect(aligner.drain(upTo: 4) == [3, -3, 4, -4])
        #expect(aligner.drain(upTo: 4) == [])
    }

    @Test func discardsAudioOlderThanTheDrainCursor() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2]), from: .microphone)
        _ = aligner.drain(upTo: 2)

        // A very late buffer for already-written frames must be dropped, not
        // prepended -- otherwise it would corrupt the timeline.
        aligner.append(chunk(at: 0, values: [9, 9]), from: .system)
        #expect(aligner.drain(upTo: 2) == [])
    }
}
```

- [ ] **Step 3: Run to verify they fail**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | grep -E "error:" | head -3
```

Expected: `cannot find 'StereoAligner' in scope`.

- [ ] **Step 4: Implement**

`Packages/NoterAudio/Sources/NoterAudio/StereoRecorder.swift`:

```swift
import Foundation

public struct AudioChunk: Sendable {
    /// Frame index on the shared capture timeline, not a wall-clock time.
    public let hostTime: UInt64
    public let samples: [Float]

    public init(hostTime: UInt64, samples: [Float]) {
        self.hostTime = hostTime
        self.samples = samples
    }
}

public enum ChannelSource: Sendable {
    case microphone
    case system
}

/// Interleaves two independently-clocked mono sources into stereo frames,
/// microphone on the left and system audio on the right.
///
/// Alignment is by frame position, never by arrival order. The microphone runs
/// continuously while system audio produces nothing between utterances, so a
/// source that has not delivered is padded with silence rather than waited for.
/// Waiting would shift one channel relative to the other, and a shift
/// desynchronises the Me:/Them: labelling for the remainder of the recording.
public final class StereoAligner {
    /// Contiguous samples plus the frame index of `samples[0]`.
    ///
    /// Deliberately an array, not a dictionary keyed by frame: at 48 kHz stereo
    /// a per-sample dictionary would perform ~96,000 inserts and removes per
    /// second on the audio path, which is far too slow for realtime.
    private struct Channel {
        var samples: [Float] = []
        var baseFrame: UInt64 = 0
    }

    private var microphone = Channel()
    private var system = Channel()
    /// Frames before this index are already written and can never be filled.
    private var cursor: UInt64 = 0

    public init(sampleRate: Double, framesPerSecond: Double) {
        // Alignment works in frame positions, so no rate arithmetic is needed.
        // The parameters are kept so callers state the format they are feeding.
        _ = sampleRate
        _ = framesPerSecond
    }

    public func append(_ chunk: AudioChunk, from source: ChannelSource) {
        switch source {
        case .microphone: Self.append(chunk, to: &microphone, cursor: cursor)
        case .system: Self.append(chunk, to: &system, cursor: cursor)
        }
    }

    private static func append(_ chunk: AudioChunk, to channel: inout Channel,
                               cursor: UInt64) {
        let end = chunk.hostTime + UInt64(chunk.samples.count)
        // Entirely behind the committed timeline: dropping is the only safe
        // option, since prepending would corrupt frames already written.
        guard end > cursor else { return }

        // Trim any part that precedes the cursor.
        var start = chunk.hostTime
        var samples = chunk.samples[...]
        if start < cursor {
            samples = samples.dropFirst(Int(cursor - start))
            start = cursor
        }

        if channel.samples.isEmpty {
            channel.baseFrame = start
            channel.samples = Array(samples)
            return
        }

        let expected = channel.baseFrame + UInt64(channel.samples.count)
        if start > expected {
            // Gap: the source delivered nothing for those frames. Pad so later
            // samples stay at their true positions instead of sliding earlier.
            channel.samples.append(
                contentsOf: [Float](repeating: 0, count: Int(start - expected)))
            channel.samples.append(contentsOf: samples)
        } else if start == expected {
            channel.samples.append(contentsOf: samples)
        } else {
            // Overlap: keep what is already committed, take only the new tail.
            channel.samples.append(contentsOf: samples.dropFirst(Int(expected - start)))
        }
    }

    /// Returns interleaved L,R frames from the cursor up to (but not including)
    /// `hostTime`, then advances the cursor and releases consumed samples.
    public func drain(upTo hostTime: UInt64) -> [Float] {
        guard hostTime > cursor else { return [] }
        let count = Int(hostTime - cursor)
        var frames = [Float](repeating: 0, count: count * 2)
        Self.fill(&frames, from: microphone, at: 0, cursor: cursor, count: count)
        Self.fill(&frames, from: system, at: 1, cursor: cursor, count: count)
        Self.consume(&microphone, upTo: hostTime)
        Self.consume(&system, upTo: hostTime)
        cursor = hostTime
        return frames
    }

    private static func fill(_ frames: inout [Float], from channel: Channel,
                             at offset: Int, cursor: UInt64, count: Int) {
        for index in 0..<count {
            let frame = cursor + UInt64(index)
            guard frame >= channel.baseFrame else { continue }
            let position = Int(frame - channel.baseFrame)
            guard position < channel.samples.count else { break }
            frames[index * 2 + offset] = channel.samples[position]
        }
    }

    private static func consume(_ channel: inout Channel, upTo hostTime: UInt64) {
        guard hostTime > channel.baseFrame else { return }
        let drop = min(Int(hostTime - channel.baseFrame), channel.samples.count)
        channel.samples.removeFirst(drop)
        channel.baseFrame += UInt64(drop)
    }
}
```

- [ ] **Step 5: Run to verify they pass**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | tail -3
```

Expected: 5 tests passing.

- [ ] **Step 6: Commit**

```bash
xcodegen generate
git add Packages/NoterAudio project.yml
git commit -m "feat(audio): stereo aligner for two independently-clocked sources

Microphone and system audio arrive on separate clocks at unrelated times.
Aligning by frame position and padding a silent source keeps the channels from
sliding apart -- drift here would desynchronise the Me:/Them: labelling that the
transcript format depends on.

Late buffers for already-written frames are dropped rather than prepended, so a
committed timeline cannot be corrupted after the fact."
```

---

### Task 3: AudioPermissions

**Files:**
- Create: `Packages/NoterAudio/Sources/NoterAudio/AudioPermissions.swift`
- Test: `Packages/NoterAudio/Tests/NoterAudioTests/AudioPermissionsTests.swift`
- Modify: `project.yml` (usage strings)

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `enum AudioAuthorization: Sendable { case granted, denied, undetermined }`
  - `struct AudioPermissions` with injected probes:
    `init(microphone: @escaping @Sendable () -> AudioAuthorization, systemAudio: @escaping @Sendable () -> AudioAuthorization)`
  - `var readiness: RecordingReadiness` — `.ready` / `.blocked([Blocker])`
  - `static let live: AudioPermissions`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import NoterAudio

@Suite struct AudioPermissionsTests {
    private func permissions(
        mic: AudioAuthorization,
        system: AudioAuthorization
    ) -> AudioPermissions {
        AudioPermissions(microphone: { mic }, systemAudio: { system })
    }

    @Test func readyOnlyWhenBothGrantsArePresent() {
        #expect(permissions(mic: .granted, system: .granted).readiness == .ready)
    }

    /// The system-audio grant fails SILENTLY -- the tap runs, delivers the right
    /// frame count, and every sample is zero. Recording must be refused up front
    /// rather than producing a file containing only one side of the conversation.
    @Test func blockedWhenSystemAudioIsMissing() {
        let readiness = permissions(mic: .granted, system: .denied).readiness
        #expect(readiness == .blocked([.systemAudio]))
    }

    @Test func blockedWhenMicrophoneIsMissing() {
        #expect(permissions(mic: .denied, system: .granted).readiness
                == .blocked([.microphone]))
    }

    @Test func reportsEveryMissingGrantAtOnce() {
        // One trip to System Settings, not two.
        #expect(permissions(mic: .denied, system: .denied).readiness
                == .blocked([.microphone, .systemAudio]))
    }

    @Test func undeterminedCountsAsBlockedNotReady() {
        #expect(permissions(mic: .undetermined, system: .granted).readiness
                == .blocked([.microphone]))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | grep -E "error:" | head -3
```

- [ ] **Step 3: Implement**

```swift
import AVFoundation
import CoreAudio
import Foundation

public enum AudioAuthorization: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

public enum RecordingBlocker: Sendable, Equatable {
    case microphone
    case systemAudio
}

public enum RecordingReadiness: Sendable, Equatable {
    case ready
    case blocked([RecordingBlocker])
}

/// Authorization for the two grants recording needs.
///
/// The probes are injected so the state machine is testable without touching
/// real TCC state.
public struct AudioPermissions: Sendable {
    private let microphone: @Sendable () -> AudioAuthorization
    private let systemAudio: @Sendable () -> AudioAuthorization

    public init(
        microphone: @escaping @Sendable () -> AudioAuthorization,
        systemAudio: @escaping @Sendable () -> AudioAuthorization
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    /// Every missing grant at once, so the user makes a single trip to System
    /// Settings instead of being stopped twice.
    public var readiness: RecordingReadiness {
        var blockers: [RecordingBlocker] = []
        if microphone() != .granted { blockers.append(.microphone) }
        if systemAudio() != .granted { blockers.append(.systemAudio) }
        return blockers.isEmpty ? .ready : .blocked(blockers)
    }

    public static let live = AudioPermissions(
        microphone: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .undetermined
            default: .denied
            }
        },
        systemAudio: {
            // There is no query API for the system-audio grant, and the failure
            // mode is silence rather than an error, so we ask Core Audio whether
            // a tap can actually be created and immediately destroy it.
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.isPrivate = true
            var tapID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
                  tapID != kAudioObjectUnknown else { return .denied }
            AudioHardwareDestroyProcessTap(tapID)
            return .granted
        })

    public func requestMicrophone() async -> AudioAuthorization {
        await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
    }
}
```

Add the usage strings to the `RustyNoter` target's `info.properties` in `project.yml`:

```yaml
        NSMicrophoneUsageDescription: Rusty Noter records your voice during meetings so it can transcribe them on this Mac.
        NSAudioCaptureUsageDescription: Rusty Noter records the other participants' audio during meetings so it can transcribe them on this Mac.
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | tail -3
```

Expected: 10 tests passing (5 + 5).

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Packages/NoterAudio project.yml
git commit -m "feat(audio): explicit authorization check for both grants

The system-audio grant fails silently -- the tap runs, the frame count is
correct, and every sample is zero -- so recording must be refused up front
rather than inferred from a running tap. Probes are injected so the state
machine is testable without real TCC state; the live probe creates and
immediately destroys a tap, since no query API exists."
```

---

### Task 4: SystemAudioTap and MicrophoneInput

Hardware-bound. Not unit-testable (see Global Constraints); verified by the acceptance pass.

**Files:**
- Create: `Packages/NoterAudio/Sources/NoterAudio/SystemAudioTap.swift`
- Create: `Packages/NoterAudio/Sources/NoterAudio/MicrophoneInput.swift`

**Interfaces:**
- Consumes: `AudioChunk`, `ChannelSource` (Task 2)
- Produces:
  - `final class SystemAudioTap` — `init(onChunk: @escaping @Sendable (AudioChunk) -> Void)`, `start() throws`, `stop()`
  - `final class MicrophoneInput` — same shape
  - `enum AudioCaptureError: Error { case noDefaultOutputDevice, tapCreationFailed(OSStatus), aggregateCreationFailed(OSStatus), ioProcFailed(OSStatus), unsupportedFormat }`

- [ ] **Step 1: Implement SystemAudioTap**

Follow spec §4.1 exactly. The four findings below are not optional — each one cost an iteration during the spike:

```swift
import AVFoundation
import CoreAudio
import Foundation

public enum AudioCaptureError: Error {
    case noDefaultOutputDevice
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case unsupportedFormat
    case segmentAppendFailed
    /// Distinct cases so the surfaced message matches the actual problem: a
    /// permission failure reported as "unsupported format" sends the user
    /// looking in entirely the wrong place.
    case permissionDenied([RecordingBlocker])
    case notRecording
}

/// Captures all system audio output via a Core Audio process tap.
public final class SystemAudioTap {
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let ioQueue = DispatchQueue(label: "nl.glebstarchikov.noteraudio.system")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var frameCursor: UInt64 = 0

    public init(onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.onChunk = onChunk
    }

    public func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Rusty Noter meeting capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted     // the user must keep hearing the call

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioCaptureError.tapCreationFailed(status) }

        let outputUID = try Self.defaultOutputDeviceUID()
        let plist: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rusty Noter Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(plist as CFDictionary, &aggregateID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.aggregateCreationFailed(status)
        }

        // A tap answers kAudioTapPropertyFormat; the device stream-format
        // property returns kAudioHardwareBadObjectError ('who?').
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }

        // The pointer from withUnsafePointer is valid ONLY inside the closure;
        // returning it yields a non-PCM format that crashes inside the IO proc.
        let format: AVAudioFormat? = withUnsafePointer(to: asbd) {
            AVAudioFormat(streamDescription: $0)
        }
        guard let captureFormat = format else {
            teardown()
            throw AudioCaptureError.unsupportedFormat
        }

        let handler = onChunk
        // A REAL queue, never nil: with nil the IO proc fires exactly once and
        // then never again, silently.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: captureFormat, bufferListNoCopy: inputData, deallocator: nil),
                  let channels = buffer.floatChannelData else { return }

            // The tap delivers INTERLEAVED float32: there is one channel pointer
            // and samples alternate L,R. Mix to mono for the "them" channel.
            let frames = Int(buffer.frameLength)
            let stride = buffer.stride
            let channelCount = Int(captureFormat.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels[0][frame * stride + channel]
                }
                mono[frame] = sum / Float(channelCount)
            }
            let start = self.frameCursor
            self.frameCursor += UInt64(frames)
            handler(AudioChunk(hostTime: start, samples: mono))
        }
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }
    }

    public func stop() { teardown() }

    /// Every exit path tears down in order: IO proc, aggregate, tap. The spike
    /// leaked all three on its error paths.
    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { throw AudioCaptureError.noDefaultOutputDevice }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &uidSize, &uid) == noErr
        else { throw AudioCaptureError.noDefaultOutputDevice }
        return uid as String
    }
}
```

- [ ] **Step 2: Implement MicrophoneInput**

```swift
import AVFoundation
import Foundation

/// Captures the microphone as mono chunks on the same frame timeline as the tap.
public final class MicrophoneInput {
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var frameCursor: UInt64 = 0

    /// Matches the tap so both sources reach the aligner at one rate.
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    public init(onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.onChunk = onChunk
    }

    public func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(
                Double(buffer.frameLength) * (48_000 / buffer.format.sampleRate) + 1024)
            guard let out = AVAudioPCMBuffer(
                pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let samples = out.floatChannelData?[0] else { return }

            let frames = Int(out.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: samples, count: frames))
            let start = self.frameCursor
            self.frameCursor += UInt64(frames)
            self.onChunk(AudioChunk(hostTime: start, samples: chunk))
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build --package-path Packages/NoterAudio 2>&1 | grep -E "error:|warning: .*never" | head
swift test --package-path Packages/NoterAudio 2>&1 | tail -2
```

Expected: builds clean, 10 tests still pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/NoterAudio
git commit -m "feat(audio): system audio tap and microphone capture

Implements the recipe the spike verified: global stereo tap, private aggregate
device with the real output as main sub-device, tap auto-start, and an IO proc
on a real DispatchQueue -- with nil the proc fires once and then never again.

Carries the other spike findings: a tap answers kAudioTapPropertyFormat rather
than the device stream-format property, the format must be built inside the
withUnsafePointer closure or it dangles, and tap audio is interleaved float32.
Teardown runs on every exit path including failure."
```

---

### Task 5: Segmented writer and RecordingSession

**Files:**
- Create: `Packages/NoterAudio/Sources/NoterAudio/SegmentWriter.swift`
- Create: `Packages/NoterAudio/Sources/NoterAudio/RecordingSession.swift`
- Test: `Packages/NoterAudio/Tests/NoterAudioTests/SegmentWriterTests.swift`

**Interfaces:**
- Consumes: `StereoAligner`, `AudioPermissions`, `SystemAudioTap`, `MicrophoneInput`
- Produces:
  - `actor SegmentWriter` — `init(directory: URL, sampleRate: Double, segmentSeconds: Double)`, `write(_ interleaved: [Float]) async throws`, `finish() async throws -> [URL]`
  - `static SegmentWriter.concatenate(_ segments: [URL], into destination: URL) async throws`
  - `@MainActor final class RecordingSession` — `start(title:) async throws`, `stop() async throws -> RecordingResult`, `var elapsed: Duration`, `var isRecording: Bool`
  - `struct RecordingResult { let audioRelativePath: String; let duration: String }`

- [ ] **Step 1: Write the failing tests for segmentation**

Only the segmentation arithmetic and concatenation are tested — they are pure/file-level. Capture itself is verified in Task 7.

```swift
import AVFoundation
import Testing
@testable import NoterAudio

@Suite struct SegmentWriterTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A crash must cost one segment, not the meeting. Writing more than one
    /// segment's worth of audio must roll over to a new file rather than
    /// buffering everything until stop.
    @Test func rollsOverToANewSegmentAtTheBoundary() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 1)

        // 2.5 seconds of stereo silence => 3 segments (1s, 1s, 0.5s).
        let oneSecond = [Float](repeating: 0, count: 48_000 * 2)
        try await writer.write(oneSecond)
        try await writer.write(oneSecond)
        try await writer.write(Array(oneSecond.prefix(48_000)))
        let segments = try await writer.finish()

        #expect(segments.count == 3)
        for segment in segments {
            #expect(FileManager.default.fileExists(atPath: segment.path))
        }
    }

    @Test func everySegmentIsIndependentlyPlayable() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 1)
        try await writer.write([Float](repeating: 0, count: 48_000 * 2))
        let segments = try await writer.finish()

        // The point of segmenting: a surviving segment opens on its own.
        let asset = AVURLAsset(url: try #require(segments.first))
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.5)
    }

    @Test func concatenationProducesOneFileOfTheCombinedLength() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 1)
        try await writer.write([Float](repeating: 0, count: 48_000 * 2))
        try await writer.write([Float](repeating: 0, count: 48_000 * 2))
        let segments = try await writer.finish()

        let destination = directory.appendingPathComponent("combined.m4a")
        try await SegmentWriter.concatenate(segments, into: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(duration.seconds > 1.5)
        #expect(duration.seconds < 2.5)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | grep -E "error:" | head -3
```

- [ ] **Step 3: Implement SegmentWriter**

```swift
import AVFoundation
import Foundation

/// Writes stereo audio as a sequence of finalized m4a segments.
///
/// AVAssetWriter cannot reopen a finalized file, and an unfinalized file is not
/// a truncated recording -- it is unplayable. Writing fixed-length segments and
/// finalizing each as it completes means a crash costs the last segment rather
/// than the whole meeting.
public actor SegmentWriter {
    private let directory: URL
    private let sampleRate: Double
    private let framesPerSegment: Int

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var framesInSegment = 0
    private var segmentIndex = 0
    private var segments: [URL] = []

    public init(directory: URL, sampleRate: Double, segmentSeconds: Double) {
        self.directory = directory
        self.sampleRate = sampleRate
        self.framesPerSegment = Int(sampleRate * segmentSeconds)
    }

    public func write(_ interleaved: [Float]) async throws {
        var offset = 0
        let totalFrames = interleaved.count / 2
        while offset < totalFrames {
            if writer == nil { try startSegment() }
            let remaining = framesPerSegment - framesInSegment
            let take = min(remaining, totalFrames - offset)
            let slice = Array(interleaved[(offset * 2)..<((offset + take) * 2)])
            try append(slice)
            framesInSegment += take
            offset += take
            if framesInSegment >= framesPerSegment { try await closeSegment() }
        }
    }

    public func finish() async throws -> [URL] {
        if writer != nil { try await closeSegment() }
        return segments
    }

    /// Joins finalized segments into one file. Used at stop, and by crash
    /// recovery over whatever segments survived.
    public static func concatenate(_ segments: [URL], into destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioCaptureError.unsupportedFormat }

        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: segment)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw AudioCaptureError.unsupportedFormat }
        try await export.export(to: destination, as: .m4a)
    }

    private func startSegment() throws {
        let url = directory.appendingPathComponent(String(format: "%04d.m4a", segmentIndex))
        try? FileManager.default.removeItem(at: url)
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        assetWriter.add(writerInput)
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        input = writerInput
        framesInSegment = 0
        segments.append(url)
        segmentIndex += 1
    }

    private func append(_ interleaved: [Float]) throws {
        guard let input, input.isReadyForMoreMediaData else { return }
        let frames = interleaved.count / 2
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 2, interleaved: true),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw AudioCaptureError.unsupportedFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        interleaved.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: interleaved.count)
        }
        guard let sampleBuffer = buffer.toSampleBuffer(
            presentationTime: CMTime(
                value: CMTimeValue(framesInSegment), timescale: CMTimeScale(sampleRate)))
        else { throw AudioCaptureError.unsupportedFormat }
        // Not `try?`: a dropped append is exactly the failure that produced a
        // header-only file during the spike.
        guard input.append(sampleBuffer) else {
            throw AudioCaptureError.segmentAppendFailed
        }
    }

    private func closeSegment() async throws {
        input?.markAsFinished()
        await writer?.finishWriting()
        writer = nil
        input = nil
        framesInSegment = 0
    }
}

private extension AVAudioPCMBuffer {
    /// Bridges a PCM buffer into the CMSampleBuffer AVAssetWriterInput expects.
    func toSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var formatDescription: CMFormatDescription? = format.formatDescription
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: audioBufferList) == noErr
        else { return nil }
        return sampleBuffer
    }
}
```

- [ ] **Step 4: Implement RecordingSession**

```swift
import Foundation

public struct RecordingResult: Sendable {
    public let audioRelativePath: String
    public let duration: String
}

/// The only public surface of NoterAudio: owns the two capture sources, the
/// aligner and the segment writer, and exposes start/stop.
@MainActor
public final class RecordingSession {
    public private(set) var isRecording = false
    public private(set) var startedAt: Date?

    private let permissions: AudioPermissions
    private let sessionsDirectory: URL
    private let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
    private var systemTap: SystemAudioTap?
    private var microphone: MicrophoneInput?
    private var writer: SegmentWriter?
    private var drainTimer: Timer?
    private var sessionDirectory: URL?

    public init(permissions: AudioPermissions = .live, sessionsDirectory: URL) {
        self.permissions = permissions
        self.sessionsDirectory = sessionsDirectory
    }

    public func start() throws {
        if case .blocked(let missing) = permissions.readiness {
            throw AudioCaptureError.permissionDenied(missing)
        }
        let directory = sessionsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory

        let segmentWriter = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 30)
        writer = segmentWriter

        let aligner = self.aligner
        let tap = SystemAudioTap { chunk in aligner.append(chunk, from: .system) }
        let mic = MicrophoneInput { chunk in aligner.append(chunk, from: .microphone) }
        try tap.start()
        do {
            try mic.start()
        } catch {
            tap.stop()
            throw error
        }
        systemTap = tap
        microphone = mic

        // Deadline-driven, never arrival-driven: drain on a fixed cadence so a
        // silent source cannot stall the other channel.
        var cursor: UInt64 = 0
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            cursor += 24_000                      // 0.5s at 48 kHz
            let frames = aligner.drain(upTo: cursor)
            guard !frames.isEmpty else { return }
            Task { try? await segmentWriter.write(frames) }
        }

        startedAt = Date()
        isRecording = true
    }

    public func stop(audioDestination: URL, relativePath: String) async throws
        -> RecordingResult {
        drainTimer?.invalidate()
        drainTimer = nil
        systemTap?.stop()
        microphone?.stop()
        systemTap = nil
        microphone = nil

        guard let writer, let started = startedAt else {
            throw AudioCaptureError.notRecording
        }
        let segments = try await writer.finish()
        try FileManager.default.createDirectory(
            at: audioDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try await SegmentWriter.concatenate(segments, into: audioDestination)
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }

        let elapsed = Int(Date().timeIntervalSince(started))
        isRecording = false
        startedAt = nil
        self.writer = nil
        return RecordingResult(
            audioRelativePath: relativePath,
            duration: String(format: "%02d:%02d:%02d",
                             elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60))
    }
}
```

- [ ] **Step 5: Run tests**

```bash
swift test --package-path Packages/NoterAudio 2>&1 | tail -3
```

Expected: 13 tests passing (10 + 3).

- [ ] **Step 6: Commit**

```bash
git add Packages/NoterAudio
git commit -m "feat(audio): segmented m4a writer and recording session

Audio is written as 30-second finalized segments in Application Support and
concatenated at stop, so a crash leaves playable segments rather than one
unplayable file. Appends throw rather than being swallowed -- a dropped append
is exactly what produced a header-only file during the spike.

RecordingSession owns both sources, the aligner and the writer, and drains on a
fixed cadence so a silent source cannot stall the other channel."
```

---

### Task 6: App wiring and UI

**Files:**
- Create: `App/Sources/RecordingController.swift`
- Modify: `App/Sources/RustyNoterApp.swift`

**Interfaces:**
- Consumes: `RecordingSession`, `VaultCoordinator.startMeeting/finishMeeting`
- Produces: `@MainActor @Observable final class RecordingController` with `isRecording`, `elapsedText`, `error`, `toggle()`

- [ ] **Step 1: Implement RecordingController**

```swift
import AppKit          // NSWorkspace, for the System Settings deep link
import Foundation
import NoterAudio
import NoterCore
import Observation

/// Glue between RecordingSession and the vault: creates the meeting note on
/// start and finalizes it on stop.
@MainActor
@Observable
final class RecordingController {
    private(set) var isRecording = false
    private(set) var elapsedText = "00:00"
    private(set) var error: String?
    private(set) var blockers: [RecordingBlocker] = []

    private let session: RecordingSession
    private let permissions: AudioPermissions
    private weak var model: AppModel?
    private var recordingPath: String?
    private var ticker: Timer?

    init(model: AppModel, permissions: AudioPermissions = .live) {
        self.model = model
        self.permissions = permissions
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RustyNoter/recording", isDirectory: true)
        self.session = RecordingSession(permissions: permissions, sessionsDirectory: support)
    }

    func toggle() {
        Task { isRecording ? await stop() : await start() }
    }

    private func start() async {
        // Explicit check: the system-audio grant fails silently, so a running
        // tap is not evidence of permission.
        if case .blocked(let missing) = permissions.readiness {
            if missing.contains(.microphone) {
                _ = await permissions.requestMicrophone()
            }
            if case .blocked(let stillMissing) = permissions.readiness {
                blockers = stillMissing
                error = Self.guidance(for: stillMissing)
                return
            }
        }
        blockers = []

        guard let coordinator = model?.coordinator else { return }
        do {
            let title = "Meeting \(Self.timestampTitle())"
            let note = try await coordinator.startMeeting(title: title)
            recordingPath = note.relativePath
            try session.start()
            isRecording = true
            error = nil
            model?.select(note.relativePath)
            startTicking()
        } catch {
            self.error = error.localizedDescription
            isRecording = false
        }
    }

    private func stop() async {
        guard let coordinator = model?.coordinator,
              let path = recordingPath,
              let vaultRoot = model?.vaultURL else { return }
        stopTicking()
        let slug = (path as NSString).deletingPathExtension
        let relative = "audio/\(slug).m4a"
        do {
            let result = try await session.stop(
                audioDestination: vaultRoot.appendingPathComponent(relative),
                relativePath: relative)
            _ = try await coordinator.finishMeeting(
                path, audio: result.audioRelativePath, duration: result.duration)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isRecording = false
        recordingPath = nil
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        elapsedText = "00:00"
    }

    private func tick() {
        guard let started = session.startedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(started))
        elapsedText = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    /// Names exactly what is missing. "Permission denied" alone sends the user
    /// hunting through System Settings; the system-audio pane in particular is
    /// not where most people would look for a note-taking app.
    private static func guidance(for blockers: [RecordingBlocker]) -> String {
        let names = blockers.map { blocker in
            switch blocker {
            case .microphone: "Microphone"
            case .systemAudio: "Screen & System Audio Recording"
            }
        }
        return "Rusty Noter needs \(names.joined(separator: " and ")) access in "
            + "System Settings ▸ Privacy & Security before it can record."
    }

    /// Opens the precise pane rather than the top of System Settings.
    func openSettings(for blocker: RecordingBlocker) {
        let pane = switch blocker {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_ScreenCapture"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func timestampTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
```

- [ ] **Step 2: Wire into the app**

In `App/Sources/RustyNoterApp.swift`, add to `MainSplitView`:

```swift
    @State private var recording: RecordingController?
```

and in the existing `.toolbar` block, add a second item before the New Note item:

```swift
                ToolbarItem(placement: .navigation) {
                    Button {
                        recording?.toggle()
                    } label: {
                        Label(
                            recording?.isRecording == true
                                ? "Stop Recording (\(recording?.elapsedText ?? ""))"
                                : "Record Meeting",
                            systemImage: recording?.isRecording == true
                                ? "stop.circle.fill" : "record.circle")
                    }
                    .help("Record Meeting (Cmd+Shift+R)")
                    .tint(recording?.isRecording == true ? TokenColor.danger : nil)
                }
```

Add to the `.commands` block:

```swift
            CommandGroup(after: .newItem) {
                Button("Record Meeting") { recording?.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
```

Create the controller once the model exists — add to `MainSplitView.body`'s outermost container:

```swift
        .onAppear { if recording == nil { recording = RecordingController(model: model) } }
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug build 2>&1 | grep -E "^/Users.*error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App project.yml
git commit -m "feat(app): record button and meeting note wiring

Creates the meeting note on start, finalizes it with audio path and duration on
stop, and surfaces any capture failure rather than swallowing it. Permission is
checked explicitly before recording begins.

Lights up the recording dot in NoteRow, built during the UI refresh and
unreachable until now."
```

---

### Task 7: Acceptance

No code expected. The capture path cannot be verified any other way (see Global Constraints).

- [ ] **Step 1: Full suite green**

```bash
swift test --package-path Packages/NoterCore 2>&1 | tail -1
swift test --package-path Packages/NoterAudio 2>&1 | tail -1
swift test --package-path Packages/NoterEditor 2>&1 | tail -1
xcodebuild test -project RustyNoter.xcodeproj -scheme RustyNoter -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED"
```

Expected: 90 NoterCore, 13 NoterAudio, 93 NoterEditor, 9 App.

- [ ] **Step 2: Record a real meeting**

```bash
killall RustyNoter 2>/dev/null; open -n "$APP"
```

Launch via `open` — the TCC grant follows the LaunchServices-launched bundle, so a recording started any other way will be silent.

| Check | Expected |
|---|---|
| First record press | Prompts for microphone, then Screen & System Audio Recording |
| Denying either | Clear message; recording does not start |
| Recording starts | Note appears with a red dot; toolbar shows elapsed time |
| Talk, and play the other side (a call or a video) for ~2 minutes | — |
| Stop | Note finalizes: `duration` set, `audio:` set, red dot gone |
| `afplay ~/Notes/audio/<slug>.m4a` | Plays back |
| Open in QuickTime, pan hard left | Only your voice |
| Pan hard right | Only the other side |

- [ ] **Step 3: Verify crash resilience**

Start a recording, wait 90 seconds, then `killall -9 RustyNoter`.

```bash
ls ~/Library/Application\ Support/RustyNoter/recording/*/
```

Expected: at least two finalized `.m4a` segments, each independently playable with `afplay`. This is what makes subsystem D possible; if the directory holds one unplayable file, the segmenting is not working and must be fixed before proceeding.

- [ ] **Step 4: Verify the vault stayed clean**

```bash
ls ~/Notes/audio/
```

In the app: no "audio" folder in the sidebar, and searching for a word in the note does not return `.m4a` files.

- [ ] **Step 5: Tag**

Only if every check passed:

```bash
git tag -a v0.4.0-phase3a -m "Phase 3A: meeting audio capture"
```

If any check failed, stop and report which. A failing capture check means the design or the spike findings need revisiting, not a workaround here.

---

## Notes for the implementer

- **Rebuild AND relaunch before judging behavior.** Stale builds have repeatedly caused false conclusions on this project.
- **Launch via `open`, never by executing the binary**, whenever audio is involved — the TCC grant does not follow a directly-executed binary, and the failure is silence rather than an error.
- **If three fixes in a row fail on the same problem, stop and raise it.** The spike's hardest bug (the `nil` IO queue) was solved by diffing against a working reference implementation, not by reasoning about it.
