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
            // There is no query API for the system-audio grant, and its failure
            // mode is silence rather than an error, so ask Core Audio whether a
            // tap can actually be created and immediately destroy it.
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
