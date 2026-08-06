import Testing
@testable import NoterAudio

@Suite struct StereoAlignerTests {
    /// Values encode the frame index so misalignment shows up in the assertion
    /// rather than hiding inside an amplitude.
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
        // prepended -- otherwise it would corrupt the committed timeline.
        aligner.append(chunk(at: 0, values: [9, 9]), from: .system)
        #expect(aligner.drain(upTo: 2) == [])
    }

    /// A source that goes quiet mid-recording and returns must resume at its
    /// true position, with the gap padded rather than closed up.
    @Test func gapInOneSourceIsPaddedNotClosed() {
        let aligner = StereoAligner(sampleRate: 48_000, framesPerSecond: 48_000)
        aligner.append(chunk(at: 0, values: [1, 2]), from: .microphone)
        aligner.append(chunk(at: 4, values: [5, 6]), from: .microphone)

        let frames = aligner.drain(upTo: 6)

        #expect(frames == [1, 0, 2, 0, 0, 0, 0, 0, 5, 0, 6, 0])
    }
}
