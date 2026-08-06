@preconcurrency import AVFoundation
import Foundation

/// Writes stereo audio as a sequence of finalized m4a segments.
///
/// `AVAssetWriter` cannot reopen a finalized file, and an unfinalized file is
/// not a truncated recording -- it is unplayable. Writing fixed-length segments
/// and finalizing each as it completes means a crash costs the last segment
/// rather than the whole meeting.
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
        self.framesPerSegment = max(1, Int(sampleRate * segmentSeconds))
    }

    public func write(_ interleaved: [Float]) async throws {
        var offset = 0
        let totalFrames = interleaved.count / 2
        while offset < totalFrames {
            if writer == nil { try startSegment() }
            let remaining = framesPerSegment - framesInSegment
            let take = min(remaining, totalFrames - offset)
            try append(Array(interleaved[(offset * 2)..<((offset + take) * 2)]))
            framesInSegment += take
            offset += take
            if framesInSegment >= framesPerSegment { await closeSegment() }
        }
    }

    public func finish() async -> [URL] {
        if writer != nil { await closeSegment() }
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
            guard duration.seconds > 0 else { continue }
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
        guard assetWriter.startWriting() else {
            throw AudioCaptureError.segmentAppendFailed
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        input = writerInput
        framesInSegment = 0
        segments.append(url)
        segmentIndex += 1
    }

    private func append(_ interleaved: [Float]) throws {
        guard let input else { throw AudioCaptureError.segmentAppendFailed }
        let frames = interleaved.count / 2
        guard frames > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 2, interleaved: true),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw AudioCaptureError.unsupportedFormat }

        buffer.frameLength = AVAudioFrameCount(frames)
        interleaved.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0]
                .update(from: source.baseAddress!, count: interleaved.count)
        }

        let presentationTime = CMTime(
            value: CMTimeValue(framesInSegment), timescale: CMTimeScale(sampleRate))
        guard let sampleBuffer = Self.sampleBuffer(from: buffer, at: presentationTime)
        else { throw AudioCaptureError.unsupportedFormat }

        // The encoder is not always ready; spinning briefly is correct here
        // because the caller drains on a fixed cadence and dropping audio would
        // silently shorten the recording.
        var attempts = 0
        while !input.isReadyForMoreMediaData && attempts < 100 {
            Thread.sleep(forTimeInterval: 0.005)
            attempts += 1
        }
        // Not `try?`: a dropped append is exactly the failure that produced a
        // header-only file during the spike.
        guard input.append(sampleBuffer) else {
            throw AudioCaptureError.segmentAppendFailed
        }
    }

    private func closeSegment() async {
        input?.markAsFinished()
        await writer?.finishWriting()
        writer = nil
        input = nil
        framesInSegment = 0
    }

    /// Bridges a PCM buffer into the `CMSampleBuffer` `AVAssetWriterInput` wants.
    private static func sampleBuffer(
        from buffer: AVAudioPCMBuffer, at presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)

        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList) == noErr
        else { return nil }

        return sampleBuffer
    }
}
