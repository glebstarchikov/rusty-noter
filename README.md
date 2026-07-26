# Rusty Noter

A native macOS notes app for people who want their notes to stay theirs, and who want AI agents to be able to read and write them directly.

Notes are plain markdown files on disk in a vault, full stop. There is no database that can get out of sync, no proprietary format, no cloud account. The app captures meetings from your microphone and system audio, transcribes them locally with Whisper, and summarizes them locally with Apple's on-device Foundation Models. Nothing leaves the Mac. Claude Code, Codex, and Claude Desktop are first-class consumers of the vault: they read and write notes directly as files, so there is no chat UI bolted onto the app. Claude is the chat interface; Rusty Noter is the capture and editing surface.

Highlights:

- **Files are the source of truth.** Every derived structure, the search index, `INDEX.md`, the in-app list, is a rebuildable cache. Delete all caches and you lose nothing.
- **Fully local.** No network calls for transcription, summarization, or organization. The only downloads are Whisper model files, fetched explicitly with your consent.
- **Agent-native.** Vault conventions are designed to be discovered and used by agents. One file read gives an agent the full map of the vault, and nothing holds notes hostage to app-only state.
- **Meeting capture.** Microphone and system audio are captured together (via a Core Audio process tap), so it works for online meetings, with mic and system channels split into rough speaker labels.
- **Native macOS.** SwiftUI, Liquid Glass chrome, keyboard-first, built to the same design system as the rest of what I ship.

## Stack
Swift 6, SwiftUI, macOS 26 (Liquid Glass), WhisperKit for local transcription, Apple Foundation Models for local summarization, XcodeGen for project generation.

## Getting started
Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), macOS 26.

```sh
xcodegen generate
open RustyNoter.xcodeproj
```

Then build and run the `RustyNoter` target. The default vault lives at `~/Notes` and is changeable in Settings.

Run tests for the two Swift packages:

```sh
swift test --package-path Packages/NoterCore
swift test --package-path Packages/NoterEditor
```

## License
MIT

---
Part of what I build at [glebstarchikov.nl](https://glebstarchikov.nl).
