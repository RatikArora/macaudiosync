import Foundation
import CoreAudio
import AVFoundation
import SyncCore

/// Captures the Mac's system audio via a Core Audio process tap
/// (macOS 14.2+) — and, unlike ScreenCaptureKit, **mutes the original
/// output while tapping**. This is what makes --party mode possible: the
/// apps' direct sound never reaches the speakers; the only audible audio
/// everywhere (including on this Mac, via a local SyncedPlayer) is the
/// delayed master timeline, so every speaker in the room plays in unison.
///
/// Our own process is excluded from the tap, otherwise the local synced
/// playback would be re-captured in a feedback loop.
///
/// Requires the "System Audio Recording" privacy permission (macOS prompts
/// on first use; separate from Screen Recording).
@available(macOS 14.2, *)
final class ProcessTapCapture {
    typealias Block = (_ samples: [Float], _ captureHostNs: UInt64, _ sampleRate: Double, _ channels: Int) -> Void

    private let onAudio: Block
    private let targetSampleRate: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: LinearResampler?
    private var tapASBD = AudioStreamBasicDescription()
    private let queue = DispatchQueue(label: "audiosync.sender.tap")

    init(targetSampleRate: Double = 48_000, onAudio: @escaping Block) {
        self.targetSampleRate = targetSampleRate
        self.onAudio = onAudio
    }

    func start() throws {
        // 1. Describe the tap: stereo mixdown of every process except ours,
        //    muting the tapped audio at the real output.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try ownProcessObject()])
        description.name = "MacAudioSync system tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw RuntimeError("AudioHardwareCreateProcessTap failed (\(status)) — grant \"System Audio Recording\" in System Settings > Privacy & Security and retry")
        }

        // 2. Read the tap's stream format (float32 at the device rate).
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapASBD)
        guard status == noErr else {
            throw RuntimeError("could not read tap format (\(status))")
        }
        guard tapASBD.mFormatID == kAudioFormatLinearPCM,
              tapASBD.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapASBD.mBitsPerChannel == 32,
              tapASBD.mChannelsPerFrame > 0 else {
            throw RuntimeError("unexpected tap format")
        }
        if tapASBD.mSampleRate != targetSampleRate {
            resampler = LinearResampler(
                sourceRate: tapASBD.mSampleRate,
                targetRate: targetSampleRate,
                channels: Int(tapASBD.mChannelsPerFrame)
            )
        }

        // 3. Wrap the tap in a private aggregate device (clocked by the
        //    default output device) so we can run an IO proc against it.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MacAudioSync aggregate",
            kAudioAggregateDeviceUIDKey as String: "audiosync-tap-\(getpid())",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: try defaultOutputDeviceUID(),
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: try defaultOutputDeviceUID()]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw RuntimeError("AudioHardwareCreateAggregateDevice failed (\(status))")
        }

        // 4. IO proc: input buffers carry the tapped system audio.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleInput(inInputData, time: inInputTime)
        }
        guard status == noErr, ioProcID != nil else {
            throw RuntimeError("AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw RuntimeError("AudioDeviceStart failed (\(status))")
        }

        log("process-tap capture started (\(Int(tapASBD.mSampleRate)) Hz \(tapASBD.mChannelsPerFrame)ch -> \(Int(targetSampleRate)) Hz, original output MUTED)")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - IO

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let channels = Int(tapASBD.mChannelsPerFrame)
        let isInterleaved = tapASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Frame count from the first buffer's byte size.
        guard let first = buffers.first, first.mData != nil else { return }
        let frames: Int
        if isInterleaved {
            frames = Int(first.mDataByteSize) / 4 / channels
        } else {
            frames = Int(first.mDataByteSize) / 4
        }
        guard frames > 0 else { return }

        var interleaved = [Float](repeating: 0, count: frames * channels)
        if isInterleaved, let data = first.mData {
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(frames * channels) { interleaved[i] = ptr[i] }
        } else {
            for (ch, buffer) in buffers.enumerated() where ch < channels {
                guard let data = buffer.mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(buffer.mDataByteSize) / 4)
                for frame in 0..<n { interleaved[frame * channels + ch] = ptr[frame] }
            }
        }

        let ts = time.pointee
        let hostNs: UInt64
        if ts.mFlags.contains(.hostTimeValid), ts.mHostTime > 0 {
            hostNs = MonotonicClock.ns(fromHostTicks: ts.mHostTime)
        } else {
            hostNs = MonotonicClock.nowNs()
        }

        if let resampler {
            let converted = resampler.process(interleaved)
            if !converted.isEmpty {
                onAudio(converted, hostNs, targetSampleRate, channels)
            }
        } else {
            onAudio(interleaved, hostNs, targetSampleRate, channels)
        }
    }

    // MARK: - Core Audio lookups

    /// Audio process object for our own PID (to exclude from the tap).
    private func ownProcessObject() throws -> AudioObjectID {
        var pid = pid_t(getpid())
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr,
                &size, &processObject
            )
        }
        guard status == noErr else {
            throw RuntimeError("could not translate own PID to audio process object (\(status))")
        }
        return processObject
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw RuntimeError("no default output device (\(status))")
        }
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, uidPtr)
        }
        guard status == noErr else {
            throw RuntimeError("could not read output device UID (\(status))")
        }
        return uid as String
    }
}
