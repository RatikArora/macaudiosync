import Foundation
import SyncCore

/// Renders the master timeline on a timer instead of through the audio
/// hardware. Used by `--headless` for automated end-to-end testing: it
/// exercises the full network + clock-sync + jitter-buffer + renderer path
/// and reports fill statistics, without touching the speakers.
final class HeadlessRenderer {
    private let client: ReceiverClient
    private let queue = DispatchQueue(label: "audiosync.recv.headless")
    private var timer: DispatchSourceTimer?
    private var windowStartMasterNs: UInt64?
    private var scratch = [Float](repeating: 0, count: 4800 * PlaybackEngine.channels)
    let stats = RenderStatsAccumulator()
    private(set) var reseekCount = 0

    private let sampleRate = PlaybackEngine.sampleRate
    private let channels = PlaybackEngine.channels
    private let framesPerTick = 480 // 10 ms
    private let tickNs: UInt64 = 10_000_000

    init(client: ReceiverClient) {
        self.client = client
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("headless renderer started (no audio output)")
    }

    private func tick() {
        guard let masterNow = client.sync.masterNs(forClientNs: MonotonicClock.nowNs()) else {
            stats.addUnsynced(frames: framesPerTick)
            return
        }

        // Render contiguous windows; reseek if we've drifted way off the
        // master clock (e.g. after a debugger pause or machine sleep).
        var start = windowStartMasterNs ?? masterNow
        let skewNs = Int64(bitPattern: masterNow &- start)
        if skewNs.magnitude > 100_000_000 {
            start = masterNow
            if windowStartMasterNs != nil { reseekCount += 1 }
        }

        let renderStats = TimelineRenderer.render(
            chunks: client.buffer.chunksOverlapping(startNs: start, endNs: start + tickNs),
            into: &scratch,
            frames: framesPerTick,
            channels: channels,
            sampleRate: sampleRate,
            windowStartMasterNs: start
        )
        client.buffer.dropChunks(endingBefore: start)
        stats.add(renderStats)
        windowStartMasterNs = start + tickNs
    }
}
