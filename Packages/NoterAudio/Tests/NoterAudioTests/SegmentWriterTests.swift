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

    /// A tone rather than silence: an encoder can drop pure digital silence, so
    /// silence would make "the audio survived" unfalsifiable.
    private func tone(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.5
            interleaved[frame * 2] = value
            interleaved[frame * 2 + 1] = value
        }
        return interleaved
    }

    /// A crash must cost one segment, not the meeting. More than a segment's
    /// worth of audio has to roll over to a new file rather than buffering
    /// everything until stop.
    @Test func rollsOverToANewSegmentAtTheBoundary() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 1)

        try await writer.write(tone(seconds: 1))
        try await writer.write(tone(seconds: 1))
        try await writer.write(tone(seconds: 0.5))
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
        try await writer.write(tone(seconds: 2))
        let segments = try await writer.finish()

        // The entire point of segmenting: a surviving segment opens on its own.
        let first = try #require(segments.first)
        let duration = try await AVURLAsset(url: first).load(.duration)
        #expect(duration.seconds > 0.5)
    }

    @Test func concatenationProducesOneFileOfTheCombinedLength() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 1)
        try await writer.write(tone(seconds: 2))
        let segments = try await writer.finish()

        let destination = directory.appendingPathComponent("combined.m4a")
        try await SegmentWriter.concatenate(segments, into: destination)

        let duration = try await AVURLAsset(url: destination).load(.duration)
        #expect(duration.seconds > 1.5)
        #expect(duration.seconds < 2.5)
    }

    /// The failure the spike actually hit: writes silently doing nothing and
    /// leaving a header-only file. A real segment is far larger than a header.
    @Test func segmentsContainAudioNotJustAHeader() async throws {
        let directory = try makeTempDirectory()
        let writer = SegmentWriter(
            directory: directory, sampleRate: 48_000, segmentSeconds: 5)
        try await writer.write(tone(seconds: 2))
        let segments = try await writer.finish()

        let first = try #require(segments.first)
        let size = try FileManager.default
            .attributesOfItem(atPath: first.path)[.size] as? Int ?? 0
        #expect(size > 8_000, "segment looks header-only at \(size) bytes")
    }
}
