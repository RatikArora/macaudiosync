import Foundation
import SyncCore

/// Timer-driven test source: generates a phase-continuous sine wave in 10 ms
/// blocks and hands it to the server with master-clock play timestamps.
///
/// Timestamps are derived from the cumulative frame count, not from when the
/// timer happened to fire, so the stream is gapless on the master timeline
/// even if individual timer ticks jitter.
final class ToneSource {
    private let server: SenderServer
    private let generator: ToneGenerator
    private let bufferDelayNs: UInt64
    private let sampleRate: Double
    private let channels: Int
    private let framesPerBlock: Int
    private var framesSent: UInt64 = 0
    private var streamStartNs: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "audiosync.sender.tone")

    init(server: SenderServer, frequency: Double, sampleRate: Double = 48_000, channels: Int = 2, bufferDelayMs: Int) {
        self.server = server
        self.generator = ToneGenerator(frequency: frequency, sampleRate: sampleRate, amplitude: 0.2, channels: channels)
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferDelayNs = UInt64(bufferDelayMs) * 1_000_000
        self.framesPerBlock = Int(sampleRate / 100) // 10 ms blocks
    }

    func start() {
        streamStartNs = MonotonicClock.nowNs()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("tone source started: \(generator.frequency) Hz, \(Int(sampleRate)) Hz \(channels)ch, buffer \(bufferDelayNs / 1_000_000) ms")
    }

    private func tick() {
        // If the timer fell behind (timer coalescing, system load), generate
        // enough blocks to catch back up to real time so receivers never
        // starve.
        let now = MonotonicClock.nowNs()
        let targetFrames = UInt64(Double(now - streamStartNs) * sampleRate / 1e9) + UInt64(framesPerBlock)
        while framesSent < targetFrames {
            let samples = generator.nextChunk(frameCount: framesPerBlock)
            let playAt = streamStartNs + bufferDelayNs + UInt64(Double(framesSent) / sampleRate * 1e9)
            server.sendAudio(
                samples: samples,
                firstFramePlayAtNs: playAt,
                sampleRate: sampleRate,
                channels: channels
            )
            framesSent += UInt64(framesPerBlock)
        }
    }
}
