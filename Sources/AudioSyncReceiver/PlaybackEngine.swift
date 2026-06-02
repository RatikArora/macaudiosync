import Foundation
import AVFoundation
import SyncCore

/// Plays the receiver's jitter buffer through the default output device,
/// aligned to the master clock.
///
/// An `AVAudioSourceNode` pulls audio from us; each render callback comes
/// with the host time its buffer will (approximately) hit the DAC. We map
/// host time -> master time using the clock synchronizer and ask the
/// `TimelineRenderer` for exactly the slice of the master timeline that this
/// callback covers. Because alignment is recomputed from timestamps on every
/// callback, neither network jitter nor DAC clock drift can accumulate.
final class PlaybackEngine {
    static let sampleRate = 48_000.0
    static let channels = 2
    private static let maxFrames = 8192

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let client: ReceiverClient
    private var scratch = [Float](repeating: 0, count: maxFrames * channels)
    let stats = RenderStatsAccumulator()

    init(client: ReceiverClient) {
        self.client = client
    }

    func start() throws {
        // Standard format = deinterleaved Float32, which is what the mixer
        // accepts (interleaved source formats are rejected with -10868).
        // The render callback deinterleaves our scratch buffer into the
        // per-channel buffer list.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channels)
        ) else {
            throw RuntimeError("could not create audio format")
        }

        let node = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, audioBufferList -> OSStatus in
            self?.render(timestamp: timestamp, frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        try engine.start()
        log("playback engine started (\(Int(Self.sampleRate)) Hz, \(Self.channels)ch)")
    }

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let frames = min(frameCount, Self.maxFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        func writeSilence() {
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }

        // Host time of this buffer's playback deadline.
        let ts = timestamp.pointee
        let hostNs: UInt64
        if ts.mFlags.contains(.hostTimeValid), ts.mHostTime > 0 {
            hostNs = MonotonicClock.ns(fromHostTicks: ts.mHostTime)
        } else {
            hostNs = MonotonicClock.nowNs()
        }

        guard let windowStart = client.sync.masterNs(forClientNs: hostNs) else {
            writeSilence() // not clock-synced yet
            stats.addUnsynced(frames: frames)
            return
        }

        let windowNs = UInt64(Double(frames) / Self.sampleRate * 1e9)
        let chunks = client.buffer.chunksOverlapping(startNs: windowStart, endNs: windowStart + windowNs)
        let renderStats = TimelineRenderer.render(
            chunks: chunks,
            into: &scratch,
            frames: frames,
            channels: Self.channels,
            sampleRate: Self.sampleRate,
            windowStartMasterNs: windowStart
        )
        client.buffer.dropChunks(endingBefore: windowStart)
        stats.add(renderStats)

        // Copy scratch into the output buffer list. With an interleaved
        // format this is one buffer; handle a planar list defensively too.
        if buffers.count == 1, let data = buffers[0].mData {
            let out = data.assumingMemoryBound(to: Float.self)
            let n = min(frames * Self.channels, Int(buffers[0].mDataByteSize) / 4)
            scratch.withUnsafeBufferPointer { src in
                for i in 0..<n { out[i] = src[i] }
            }
        } else {
            for (ch, buffer) in buffers.enumerated() {
                guard let data = buffer.mData, ch < Self.channels else { continue }
                let out = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(buffer.mDataByteSize) / 4)
                scratch.withUnsafeBufferPointer { src in
                    for frame in 0..<n { out[frame] = src[frame * Self.channels + ch] }
                }
            }
        }
    }
}

/// Thread-safe accumulator for once-a-second stats reporting.
final class RenderStatsAccumulator {
    private let lock = NSLock()
    private var filled = 0
    private var silent = 0
    private var unsynced = 0

    func add(_ stats: TimelineRenderer.RenderStats) {
        lock.lock()
        filled += stats.framesFilled
        silent += stats.framesSilent
        lock.unlock()
    }

    func addUnsynced(frames: Int) {
        lock.lock()
        unsynced += frames
        lock.unlock()
    }

    /// Returns and resets (filled, silent, unsynced) frame counts.
    func drain() -> (filled: Int, silent: Int, unsynced: Int) {
        lock.lock()
        defer {
            filled = 0; silent = 0; unsynced = 0
            lock.unlock()
        }
        return (filled, silent, unsynced)
    }
}

func log(_ message: String) {
    let seconds = Double(MonotonicClock.nowNs()) / 1e9
    FileHandle.standardError.write(Data(String(format: "[%.3f] %@\n", seconds, message).utf8))
}
