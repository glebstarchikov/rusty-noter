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
