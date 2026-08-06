import AVFoundation
import CoreAudio
import Foundation

public enum AudioCaptureError: Error {
    case noDefaultOutputDevice
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case unsupportedFormat
    case segmentAppendFailed
    /// Distinct cases so the surfaced message matches the actual problem: a
    /// permission failure reported as "unsupported format" sends the user
    /// looking in entirely the wrong place.
    case permissionDenied([RecordingBlocker])
    case notRecording
}

/// Captures all system audio output via a Core Audio process tap.
///
/// Every non-obvious step below was established empirically by a throwaway
/// spike; the comments record why, because none of it is guessable.
public final class SystemAudioTap: @unchecked Sendable {
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let ioQueue = DispatchQueue(label: "nl.glebstarchikov.noteraudio.system")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var frameCursor: UInt64 = 0

    public init(onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.onChunk = onChunk
    }

    public func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Rusty Noter meeting capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted     // the user must keep hearing the call

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioCaptureError.tapCreationFailed(status) }

        let outputUID = try Self.defaultOutputDeviceUID()
        let plist: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rusty Noter Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(plist as CFDictionary, &aggregateID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.aggregateCreationFailed(status)
        }

        // A tap answers kAudioTapPropertyFormat; the device stream-format
        // property returns kAudioHardwareBadObjectError ('who?').
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }

        // The pointer from withUnsafePointer is valid ONLY inside the closure;
        // returning it yields a non-PCM format that crashes inside the IO proc
        // with `required condition is false: isPCMFormat(fmt)`.
        let built: AVAudioFormat? = withUnsafePointer(to: asbd) {
            AVAudioFormat(streamDescription: $0)
        }
        guard let captureFormat = built else {
            teardown()
            throw AudioCaptureError.unsupportedFormat
        }

        let handler = onChunk
        // A REAL queue, never nil: with nil the IO proc fires exactly once and
        // then never again, silently. This was the hardest failure to diagnose.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: captureFormat, bufferListNoCopy: inputData, deallocator: nil),
                  let channels = buffer.floatChannelData else { return }

            // The tap delivers INTERLEAVED float32: one channel pointer, samples
            // alternating L,R. Mix down to mono for the "them" channel.
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let stride = buffer.stride
            let channelCount = Int(captureFormat.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            if captureFormat.isInterleaved {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += channels[0][frame * stride + channel]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            } else {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += channels[channel][frame]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            }
            let start = self.frameCursor
            self.frameCursor += UInt64(frames)
            handler(AudioChunk(hostTime: start, samples: mono))
        }
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw AudioCaptureError.ioProcFailed(status)
        }
    }

    public func stop() { teardown() }

    /// Every exit path tears down in order: IO proc, aggregate, tap. The spike
    /// leaked all three on its error paths.
    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { throw AudioCaptureError.noDefaultOutputDevice }

        // Core Audio hands back a +1 CFStringRef. Reading it into an
        // `Unmanaged` makes that ownership explicit; taking the address of a
        // bare `CFString` writes over a managed reference.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &uidSize, &uid) == noErr,
            let value = uid?.takeRetainedValue()
        else { throw AudioCaptureError.noDefaultOutputDevice }
        return value as String
    }
}
