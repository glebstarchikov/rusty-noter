import AppKit          // NSWorkspace, for the System Settings deep link
import Foundation
import NoterAudio
import NoterCore
import Observation

/// Glue between `RecordingSession` and the vault: creates the meeting note on
/// start and finalizes it on stop.
@MainActor
@Observable
final class RecordingController {
    private(set) var isRecording = false
    private(set) var elapsedText = "00:00"
    private(set) var error: String?
    private(set) var blockers: [RecordingBlocker] = []

    @ObservationIgnored private let session: RecordingSession
    @ObservationIgnored private let permissions: AudioPermissions
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var recordingPath: String?
    @ObservationIgnored private var ticker: Timer?

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

    func clearError() {
        error = nil
        blockers = []
    }

    private func start() async {
        // Explicit check: the system-audio grant fails silently, so a running
        // tap is never evidence of permission.
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
            let note = try await coordinator.startMeeting(title: Self.meetingTitle())
            recordingPath = note.relativePath
            try session.start()
            isRecording = true
            error = nil
            model?.select(note.relativePath)
            startTicking()
        } catch {
            self.error = error.localizedDescription
            isRecording = false
            recordingPath = nil
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
            // Surfaced, never swallowed: a recording that fails quietly is only
            // discovered after the meeting.
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
    /// hunting through System Settings, and the system-audio pane in particular
    /// is not where anyone would look for a note-taking app.
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

    private static func meetingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(formatter.string(from: Date()))"
    }
}
