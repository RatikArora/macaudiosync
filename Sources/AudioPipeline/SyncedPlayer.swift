import Foundation
import AVFoundation
import SyncCore

/// Plays a `JitterBuffer` through the default output device, aligned to a
/// master timeline.
///
/// An `AVAudioSourceNode` pulls audio from us; each render callback comes
/// with the host time its buffer will (approximately) hit the DAC. We map
/// host time -> master time with the injected `masterClock` closure and ask
/// the `TimelineRenderer` for exactly the slice of the master timeline that
/// this callback covers. Because alignment is recomputed from timestamps on
/// every callback, neither network jitter nor DAC clock drift accumulates.
///
/// Used in two places:
/// - receivers: `masterClock` converts via the NTP-style `ClockSynchronizer`
/// - the sender in --party mode: `masterClock` is the identity (the sender
///   IS the master), so its own speakers play the same delayed timeline as
///   every receiver.
public final class SyncedPlayer {
    /// Convert a local host-clock timestamp (ns) to master-timeline ns;
    /// return nil while not yet synchronized (renders silence).
    public typealias MasterClock = (_ hostNs: UInt64) -> UInt64?

    public static let defaultSampleRate = 48_000.0
    public static let defaultChannels = 2
    private static let maxFrames = 8192

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let buffer: JitterBuffer
    private let masterClock: MasterClock
    private let sampleRate: Double
    private let channels: Int
    private var scratch: [Float]
    private var coverage: [Bool] = []
    /// Integer-master-grid scratch for the resampling renderer (reused).
    private var gridScratch: [Float] = []
    private var gridCoverage: [Bool] = []
    /// Reused on the render thread so fetching the overlapping chunks doesn't
    /// heap-allocate a fresh array every audio callback.
    private var overlapScratch: [AudioChunk] = []
    public let stats = RenderStatsAccumulator()

    // Continuous fractional playhead, in master-clock nanoseconds, of the next
    // output frame. This is what makes playback artifact-free: instead of
    // re-snapping the render window to the master clock every callback — which
    // drops or repeats a whole sample at each DAC-drift / clock-correction step,
    // a faint periodic tick — we advance this playhead smoothly and let a gentle
    // servo micro-resample (a few tens of ppm) so it tracks the master clock
    // without ever skipping a frame. nil until the first clock sync.
    private var playheadMasterNs: Double?
    /// Master frames consumed per output frame (≈ 1; the servo nudges it).
    private var rateRatio: Double = 1
    private let frameNs: Double
    /// Jump bigger than this (startup, reconnect, wake-from-sleep) → re-anchor
    /// the playhead instead of trying to slew across it.
    private let resyncThresholdNs: Double = 50_000_000
    /// Proportional servo: close a standing offset over ~this long. Short enough
    /// to track drift, long enough that the implied pitch change is inaudible.
    private let servoTimeNs: Double = 500_000_000
    /// Hard clamp on the rate correction (±). 0.003 = ~5 cents, well below
    /// audibility, and far above any real crystal drift (<50 ppm).
    private let maxRateDeviation: Double = 0.003

    // Turns late/lost-packet silence gaps into click-free dips. A dropped
    // packet would otherwise snap the signal to 0 and back — that step is the
    // "break" you hear even when only a few ms went missing.
    private let concealer: GapConcealer

    /// Real-time FFT spectrum of what's actually playing, for the visualizer.
    public let spectrum: SpectrumAnalyzer

    public init(
        buffer: JitterBuffer,
        sampleRate: Double = SyncedPlayer.defaultSampleRate,
        channels: Int = SyncedPlayer.defaultChannels,
        masterClock: @escaping MasterClock
    ) {
        self.buffer = buffer
        self.sampleRate = sampleRate
        self.channels = channels
        self.masterClock = masterClock
        self.scratch = [Float](repeating: 0, count: Self.maxFrames * channels)
        self.frameNs = 1e9 / sampleRate
        self.concealer = GapConcealer(channels: channels, sampleRate: sampleRate)
        self.spectrum = SpectrumAnalyzer(sampleRate: sampleRate)
    }

    public func start() throws {
        // Standard format = deinterleaved Float32, which is what the mixer
        // accepts (interleaved source formats are rejected with -10868).
        // The render callback deinterleaves our scratch buffer into the
        // per-channel buffer list.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
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
    }

    public func stop() {
        engine.stop()
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

        guard let targetU = masterClock(hostNs) else {
            writeSilence() // not clock-synced yet
            stats.addUnsynced(frames: frames)
            playheadMasterNs = nil // re-anchor on resume
            return
        }
        let target = Double(targetU) // where output frame 0 should land in master time

        // Advance / re-anchor the continuous playhead and update the drift servo.
        let playhead: Double
        if let p = playheadMasterNs, abs(target - p) < resyncThresholdNs {
            playhead = p
            // Proportional servo: error > 0 means we're behind master time, so
            // consume master content a touch faster (ratio > 1) to catch up.
            let error = target - p
            let correction = max(-maxRateDeviation, min(maxRateDeviation, error / servoTimeNs))
            rateRatio = 1 + correction
        } else {
            playhead = target // first sync / big jump (reconnect, wake): re-anchor
            rateRatio = 1
        }

        // Decompose the playhead into a canonical master frame grid (stable chunk
        // placement across callbacks) plus the sub-frame phase the interpolator
        // needs. Computed relative to the playhead to keep Double precision (the
        // absolute frame index is huge — never multiply it back up by 1e9).
        let posFrames = playhead * sampleRate / 1e9
        let startOffsetFrames = posFrames - posFrames.rounded(.down)
        let windowStart = UInt64((playhead - startOffsetFrames * frameNs).rounded())
        let spanFrames = Double(frames) * rateRatio + startOffsetFrames + 2
        let windowEnd = windowStart &+ UInt64(spanFrames * frameNs)

        // Fetch overlapping chunks into the reused scratch (no per-callback heap
        // allocation on the real-time thread).
        buffer.chunksOverlapping(startNs: windowStart, endNs: windowEnd, into: &overlapScratch)
        let renderStats = TimelineRenderer.renderResampled(
            chunks: overlapScratch,
            into: &scratch,
            coverage: &coverage,
            frames: frames,
            channels: channels,
            sampleRate: sampleRate,
            windowStartMasterNs: windowStart,
            startOffsetFrames: startOffsetFrames,
            ratio: rateRatio,
            gridScratch: &gridScratch,
            gridCoverage: &gridCoverage
        )
        buffer.dropChunks(endingBefore: windowStart)
        stats.add(renderStats)

        // Advance the playhead by exactly what we consumed this callback.
        playheadMasterNs = playhead + Double(frames) * rateRatio * frameNs

        // Replace hard-silence gaps with a click-free hold-and-fade so a late
        // or lost packet is a brief dip, not a pop.
        concealer.process(&scratch, coverage: coverage, frames: frames)

        // Feed the visualizer the audio we're about to play (cheap ring copy).
        scratch.withUnsafeBufferPointer { spectrum.append($0, frames: frames, channels: channels) }

        // Copy scratch into the output buffer list (planar from a standard
        // format; handle a single interleaved buffer defensively too) and
        // record the peak level for diagnostics.
        var peak: Float = 0
        for i in 0..<(frames * channels) {
            let magnitude = abs(scratch[i])
            if magnitude > peak { peak = magnitude }
        }
        stats.recordPeak(peak)

        if buffers.count == 1, let data = buffers[0].mData {
            let out = data.assumingMemoryBound(to: Float.self)
            let n = min(frames * channels, Int(buffers[0].mDataByteSize) / 4)
            scratch.withUnsafeBufferPointer { src in
                for i in 0..<n { out[i] = src[i] }
            }
        } else {
            for (ch, buffer) in buffers.enumerated() {
                guard let data = buffer.mData, ch < channels else { continue }
                let out = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(buffer.mDataByteSize) / 4)
                scratch.withUnsafeBufferPointer { src in
                    for frame in 0..<n { out[frame] = src[frame * channels + ch] }
                }
            }
        }
    }
}

/// Thread-safe accumulator for once-a-second stats reporting.
public final class RenderStatsAccumulator {
    private let lock = NSLock()
    private var filled = 0
    private var silent = 0
    private var unsynced = 0
    private var peak: Float = 0

    public init() {}

    public func add(_ stats: TimelineRenderer.RenderStats) {
        lock.lock()
        filled += stats.framesFilled
        silent += stats.framesSilent
        lock.unlock()
    }

    public func addUnsynced(frames: Int) {
        lock.lock()
        unsynced += frames
        lock.unlock()
    }

    public func recordPeak(_ value: Float) {
        lock.lock()
        if value > peak { peak = value }
        lock.unlock()
    }

    /// Returns and resets the counters.
    public func drain() -> (filled: Int, silent: Int, unsynced: Int, peak: Float) {
        lock.lock()
        defer {
            filled = 0; silent = 0; unsynced = 0; peak = 0
            lock.unlock()
        }
        return (filled, silent, unsynced, peak)
    }
}
