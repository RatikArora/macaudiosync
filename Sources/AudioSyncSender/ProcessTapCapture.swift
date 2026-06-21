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

    /// The rate the IO proc ACTUALLY delivers frames at. This is the
    /// aggregate device's rate (= the output device's rate, e.g. 96 kHz on
    /// MacBook Pro speakers), NOT the tap's nominal format rate — the two
    /// disagree on machines whose output doesn't run at 48 kHz, and trusting
    /// the wrong one plays everything at the wrong speed.
    private var ioRate: Double = 48_000
    // Rate self-healing: if frame-time keeps diverging from the host clock,
    // measure the true rate and correct ourselves.
    private var reanchorCount = 0
    private var rateMeasureStartNs: UInt64 = 0
    private var rateMeasureFrames: UInt64 = 0

    init(targetSampleRate: Double = 48_000, onAudio: @escaping Block) {
        self.targetSampleRate = targetSampleRate
        self.onAudio = onAudio
    }

    func start() throws {
        // If any step after the tap/aggregate/IO-proc is created throws, tear
        // down what we already built (stop() is idempotent) so we never leak a
        // half-initialized process tap (which holds .mutedWhenTapped).
        do {
            try startBody()
        } catch {
            stop()
            throw error
        }
    }

    private func startBody() throws {
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
        // Resampler is configured later from the aggregate device's actual
        // IO rate (see configureResampler()), not the tap's nominal rate.

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

        // The IO proc runs on the AGGREGATE's clock — its sample rate is the
        // output device's rate (96 kHz on MacBook Pro speakers!), which can
        // differ from the tap's nominal format rate. This is the rate the
        // frames actually arrive at; resampling and timestamps must use it.
        var aggregateRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &aggregateRate)
        ioRate = (status == noErr && aggregateRate > 0) ? aggregateRate : tapASBD.mSampleRate
        configureResampler()

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

        log("process-tap capture started (device \(Int(ioRate)) Hz \(tapASBD.mChannelsPerFrame)ch -> \(Int(targetSampleRate)) Hz, original output MUTED)")
    }

    /// (Re)build the resampler for the current `ioRate`. We normalize every
    /// callback to interleaved stereo before resampling, so it's always
    /// 2-channel.
    private func configureResampler() {
        if ioRate != targetSampleRate {
            resampler = LinearResampler(sourceRate: ioRate, targetRate: targetSampleRate, channels: 2)
        } else {
            resampler = nil
        }
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
        if anchorNs == 0 {
            anchorNs = hostNs
            rateMeasureStartNs = hostNs
            rateMeasureFrames = 0
        } else if hostTimeValid {
            let expectedNs = anchorNs + UInt64(Double(inputFramesSeen) / ioRate * 1e9)
            let errorNs = Int64(bitPattern: hostNs &- expectedNs)
            if errorNs.magnitude > 100_000_000 {
                // Frame-counter time has diverged >100 ms from the host
                // clock: our notion of the IO rate must be wrong. Re-anchor
                // hard, and after repeated divergence MEASURE the true rate
                // (frames delivered / host time elapsed), snap to the
                // nearest standard rate, and reconfigure — self-healing for
                // devices whose reported rates lie.
                reanchorCount += 1
                log("WARNING: tap timeline diverged \(errorNs / 1_000_000) ms from host clock — re-anchoring (\(reanchorCount))")
                anchorNs = UInt64(Int64(anchorNs) + errorNs)
                if reanchorCount >= 3 {
                    healRate(nowNs: hostNs)
                }
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
        let captureNs = anchorNs + UInt64(Double(inputFramesSeen) / ioRate * 1e9)
        inputFramesSeen += UInt64(frames)
        rateMeasureFrames += UInt64(frames)

        if let resampler {
            let converted = resampler.process(interleaved)
            if !converted.isEmpty {
                onAudio(converted, captureNs, targetSampleRate, channels)
            }
        } else {
            onAudio(interleaved, captureNs, targetSampleRate, channels)
        }
    }

    /// Measure the true delivery rate from frames/elapsed-host-time, snap to
    /// the nearest standard rate, and reconfigure the pipeline around it.
    private func healRate(nowNs: UInt64) {
        let elapsedNs = nowNs - rateMeasureStartNs
        guard elapsedNs > 500_000_000, rateMeasureFrames > 0 else { return }
        let measured = Double(rateMeasureFrames) / (Double(elapsedNs) / 1e9)
        let standards: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        let snapped = standards.min { abs($0 - measured) < abs($1 - measured) } ?? measured
        let corrected = abs(snapped - measured) / snapped < 0.02 ? snapped : measured
        log("tap IO rate corrected: nominal said \(Int(ioRate)) Hz, measured \(Int(measured)) Hz -> using \(Int(corrected)) Hz")
        ioRate = corrected
        configureResampler()
        // Restart the timeline cleanly at the corrected rate.
        anchorNs = nowNs
        inputFramesSeen = 0
        rateMeasureStartNs = nowNs
        rateMeasureFrames = 0
        reanchorCount = 0
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
