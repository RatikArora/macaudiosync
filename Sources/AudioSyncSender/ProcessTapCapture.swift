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
    /// Resampling, wire encoding and network sends happen here, NOT on the
    /// IO callback — overrunning the audio cycle budget glitches the device
    /// for every process on the system.
    private let processQueue = DispatchQueue(label: "audiosync.sender.tap.process")

    // Timestamp synthesis (all touched only on processQueue).
    //
    // IO-callback host timestamps jitter by a few frames between callbacks;
    // stamping chunks with them directly makes consecutive chunks overlap or
    // gap by ±1–2 frames — audible as continuous crackle. Instead we count
    // frames (exactly contiguous by construction, driven by the device
    // clock) anchored to the host clock once, with a gentle servo so the
    // anchor tracks long-term device-vs-host clock drift without ever
    // jumping.
    private var anchorNs: UInt64 = 0
    private var inputFramesSeen: UInt64 = 0

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
            // We normalize every callback to interleaved stereo before
            // resampling, so the resampler is always 2-channel.
            resampler = LinearResampler(
                sourceRate: tapASBD.mSampleRate,
                targetRate: targetSampleRate,
                channels: 2
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

    private var loggedLayout = false

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, first.mData != nil else { return }

        // Derive the layout from the ACTUAL buffer list (`mNumberChannels`
        // per buffer), never from the ASBD's interleaved flag: on some
        // macOS builds the tap's nominal format claims non-interleaved while
        // the IO proc delivers a single interleaved buffer. Trusting the
        // flag doubles the frame count — the timeline then runs 2× fast
        // (buffered/margin run away by seconds per second on receivers,
        // tsJit climbs at the block rate) and channels scramble. Seen live
        // on Ratik's MacBook Pro while the Air was fine.
        let sourceChannels: Int
        let frames: Int
        if buffers.count == 1 {
            sourceChannels = max(1, Int(first.mNumberChannels))
            frames = Int(first.mDataByteSize) / 4 / sourceChannels
        } else {
            sourceChannels = buffers.count // one buffer per channel
            frames = Int(first.mDataByteSize) / 4 / max(1, Int(first.mNumberChannels))
        }
        guard frames > 0 else { return }

        if !loggedLayout {
            loggedLayout = true
            let claimsInterleaved = tapASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            log("tap IO layout: \(buffers.count) buffer(s) × \(first.mNumberChannels)ch, \(frames) frames/callback " +
                "(nominal format: \(Int(tapASBD.mSampleRate)) Hz \(tapASBD.mChannelsPerFrame)ch interleaved=\(claimsInterleaved))")
        }

        // Normalize to interleaved STEREO — the wire format receivers play.
        var interleaved = [Float](repeating: 0, count: frames * 2)
        if buffers.count == 1, let data = first.mData {
            let ptr = data.assumingMemoryBound(to: Float.self)
            if sourceChannels == 1 {
                for f in 0..<frames {
                    let v = ptr[f]
                    interleaved[f * 2] = v
                    interleaved[f * 2 + 1] = v
                }
            } else {
                let rightOffset = min(1, sourceChannels - 1)
                for f in 0..<frames {
                    interleaved[f * 2] = ptr[f * sourceChannels]
                    interleaved[f * 2 + 1] = ptr[f * sourceChannels + rightOffset]
                }
            }
        } else {
            for ch in 0..<2 {
                let buffer = buffers[min(ch, buffers.count - 1)]
                guard let data = buffer.mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(buffer.mDataByteSize) / 4)
                for f in 0..<n { interleaved[f * 2 + ch] = ptr[f] }
            }
        }

        let ts = time.pointee
        let hostTimeValid = ts.mFlags.contains(.hostTimeValid) && ts.mHostTime > 0
        let hostNs = hostTimeValid ? MonotonicClock.ns(fromHostTicks: ts.mHostTime) : MonotonicClock.nowNs()

        // Get off the IO path immediately; everything else is async.
        processQueue.async { [weak self] in
            self?.process(interleaved, frames: frames, channels: 2, hostNs: hostNs, hostTimeValid: hostTimeValid)
        }
    }

    private func process(_ interleaved: [Float], frames: Int, channels: Int, hostNs: UInt64, hostTimeValid: Bool) {
        let inputRate = tapASBD.mSampleRate

        if anchorNs == 0 {
            anchorNs = hostNs
        } else if hostTimeValid {
            let expectedNs = anchorNs + UInt64(Double(inputFramesSeen) / inputRate * 1e9)
            let errorNs = Int64(bitPattern: hostNs &- expectedNs)
            if errorNs.magnitude > 100_000_000 {
                // Frame-counter time has diverged >100 ms from the host
                // clock: the nominal rate or layout must be wrong. Re-anchor
                // hard (one audible blip) instead of drifting forever, and
                // say so — this should never fire; if it does, the log line
                // is the bug report.
                log("WARNING: tap timeline diverged \(errorNs / 1_000_000) ms from host clock — re-anchoring (rate/layout mismatch?)")
                anchorNs = UInt64(Int64(anchorNs) + errorNs)
            } else {
                // Servo: nudge the anchor toward the host clock so
                // frame-counter time can't drift away over hours (device vs
                // host crystal ppm). Gain 1/128 with a ±200 µs/callback
                // clamp; individual adjustments far below one frame period.
                let adjustment = max(-200_000, min(200_000, errorNs / 128))
                anchorNs = UInt64(Int64(anchorNs) + adjustment)
            }
        }

        // Contiguous capture timestamp for this block, on the frame grid.
        let captureNs = anchorNs + UInt64(Double(inputFramesSeen) / inputRate * 1e9)
        inputFramesSeen += UInt64(frames)

        if let resampler {
            let converted = resampler.process(interleaved)
            if !converted.isEmpty {
                onAudio(converted, captureNs, targetSampleRate, channels)
            }
        } else {
            onAudio(interleaved, captureNs, targetSampleRate, channels)
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
