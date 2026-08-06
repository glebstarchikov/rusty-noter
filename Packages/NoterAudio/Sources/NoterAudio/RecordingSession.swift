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
    private var drainTask: Task<Void, Never>?
    private var sessionDirectory: URL?

    public init(permissions: AudioPermissions = .live, sessionsDirectory: URL) {
        self.permissions = permissions
        self.sessionsDirectory = sessionsDirectory
    }

    public func start() throws {
        // The system-audio grant fails silently, so a running tap is never
        // evidence of permission. Refuse up front instead.
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

        // Deadline-driven, never arrival-driven: draining on a fixed cadence
        // means a silent source cannot stall the other channel.
        drainTask = Task {
            var cursor: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                cursor += 24_000                    // 0.5s at 48 kHz
                let frames = aligner.drain(upTo: cursor)
                guard !frames.isEmpty else { continue }
                try? await segmentWriter.write(frames)
            }
        }

        startedAt = Date()
        isRecording = true
    }

    public func stop(audioDestination: URL, relativePath: String) async throws
        -> RecordingResult {
        drainTask?.cancel()
        drainTask = nil
        systemTap?.stop()
        microphone?.stop()
        systemTap = nil
        microphone = nil

        guard let writer, let started = startedAt else {
            throw AudioCaptureError.notRecording
        }

        // Everything still buffered belongs in the file: stopping mid-cadence
        // must not discard the last half-second of the meeting.
        let tail = aligner.drainRemaining()
        if !tail.isEmpty { try? await writer.write(tail) }

        let segments = await writer.finish()
        try FileManager.default.createDirectory(
            at: audioDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try await SegmentWriter.concatenate(segments, into: audioDestination)
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil

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
