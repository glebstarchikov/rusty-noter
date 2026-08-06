import Foundation

public struct AudioChunk: Sendable {
    /// Position on the shared capture timeline, in frames — not a wall clock.
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
    private let lock = NSLock()

    public init(sampleRate: Double, framesPerSecond: Double) {
        // Alignment works in frame positions, so no rate arithmetic is needed.
        // The parameters are kept so callers state the format they are feeding.
        _ = sampleRate
        _ = framesPerSecond
    }

    public func append(_ chunk: AudioChunk, from source: ChannelSource) {
        lock.lock()
        defer { lock.unlock() }
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
            let overlap = Int(expected - start)
            if overlap < samples.count {
                channel.samples.append(contentsOf: samples.dropFirst(overlap))
            }
        }
    }

    /// Returns interleaved L,R frames from the cursor up to (but not including)
    /// `hostTime`, then advances the cursor and releases consumed samples.
    public func drain(upTo hostTime: UInt64) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
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
