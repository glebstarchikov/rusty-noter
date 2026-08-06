// AVFAudio predates strict concurrency and its buffer types are not Sendable,
// though the converter calls its input block synchronously on the calling
// thread. Marking the import keeps that unavoidable noise from masking a real
// concurrency warning on the audio path.
@preconcurrency import AVFoundation
import Foundation

/// Captures the microphone as mono chunks on the same frame timeline as the tap.
public final class MicrophoneInput: @unchecked Sendable {
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
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.unsupportedFormat
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 48_000 / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(
                pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            // Reference box rather than a captured var: the converter's input
            // block is synchronous, but a captured mutable local reads as a
            // data race to the compiler and would hide genuine ones.
            let feed = SingleBufferFeed(buffer: buffer)
            converter.convert(to: out, error: &error, withInputFrom: feed.provide)
            guard error == nil,
                  out.frameLength > 0,
                  let samples = out.floatChannelData?[0] else { return }

            let frames = Int(out.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: samples, count: frames))
            let start = self.frameCursor
            self.frameCursor += UInt64(frames)
            self.onChunk(AudioChunk(hostTime: start, samples: chunk))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }
}

/// Hands one captured buffer to `AVAudioConverter` exactly once.
///
/// Reporting `.haveData` a second time would replay the same buffer and
/// duplicate audio into the recording.
/// `@unchecked Sendable` is sound here and nowhere broader: an instance is
/// created inside one tap callback, consumed by the synchronous `convert` call
/// in that same callback, and never stored or shared.
private final class SingleBufferFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func provide(
        _ count: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
