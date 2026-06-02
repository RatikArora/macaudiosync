import Testing
import Foundation
@testable import SyncCore

/// Full-pipeline simulation: a master streaming a tone through the real wire
/// encoding, across a jittery/reordering network, into a receiver whose
/// clock has a different epoch AND runs at a slightly different rate —
/// exactly the situation with two physical MacBooks. The receiver must
/// reproduce the master's audio bit-exactly on its own clock.
@Suite struct EndToEndPipelineTests {

    private struct SimResult {
        var rendered: [Float] = []
        var referenceSent: [Float] = []
        var firstWindowStartNs: UInt64 = 0
        var toneStartNs: UInt64 = 0
        var steadySilentFrames = 0
        var steadyWindows = 0
        var syncErrorNs: Int64 = 0
        var duplicateCount = 0
        var lostChunkFrames = 0
        var insertedCount = 0
    }

    /// Runs the simulation. Master ticks every 10 ms: generates a 480-frame
    /// tone block, splits it into wire packets (160 frames each, like the
    /// real sender), and "transmits" them with random per-packet delay,
    /// 30 ms reorder spikes, optional duplication and optional loss. The
    /// receiver delivers arrived packets, keeps clock-syncing every 250 ms,
    /// and renders contiguous 10 ms windows of the master timeline.
    private func runSimulation(
        seed: UInt64,
        driftPpm: Double,
        duplicateProbability: Double = 0,
        lossProbability: Double = 0,
        seconds: Int = 10
    ) throws -> SimResult {
        let rate = 48_000.0
        let channels = 2
        let framesPerBlock = 480
        let framesPerPacket = Wire.maxFramesPerPacket
        let bufferDelayNs: UInt64 = 300_000_000
        let tickNs: UInt64 = 10_000_000

        var clocks = SimClocks(driftPpm: driftPpm)
        let sync = ClockSynchronizer()
        let buffer = JitterBuffer()
        var rng = SeededRandom(seed: seed)
        let tone = ToneGenerator(frequency: 440, sampleRate: rate, amplitude: 0.5, channels: channels)
        var result = SimResult()

        func networkDelay() -> UInt64 {
            // 0.2–3 ms typical; 2% of packets take a 30 ms detour (reorder).
            var delay = UInt64(rng.uniform(200_000, 3_000_000))
            if rng.uniform() < 0.02 { delay += 30_000_000 }
            return delay
        }
        func runClockExchange() {
            clocks.runExchange(
                sync: sync,
                forwardDelayNs: 200_000 + UInt64(rng.uniform(0, 2_000_000)),
                returnDelayNs: 200_000 + UInt64(rng.uniform(0, 2_000_000))
            )
        }

        // Warm up clock sync (receiver probes for ~5 s before audio starts).
        for _ in 0..<20 {
            runClockExchange()
            clocks.advance(ns: 250_000_000)
        }

        struct InFlight {
            let data: Data
            let arrivalMasterNs: UInt64
        }
        var inFlight: [InFlight] = []
        var sequence: UInt32 = 0
        var framesGenerated: UInt64 = 0
        let streamStartNs = clocks.masterNowNs
        result.toneStartNs = streamStartNs + bufferDelayNs

        var windowStartNs: UInt64? = nil
        var scratch = [Float](repeating: 0, count: framesPerBlock * channels)
        var lostChunkSpans: [(startNs: UInt64, endNs: UInt64)] = []

        let ticks = seconds * 100
        for tick in 0..<ticks {
            // --- master side: generate one block, packetize, transmit ---
            let block = tone.nextChunk(frameCount: framesPerBlock)
            result.referenceSent.append(contentsOf: block)
            var frame = 0
            while frame < framesPerBlock {
                let n = min(framesPerPacket, framesPerBlock - frame)
                sequence &+= 1
                let playAt = streamStartNs + bufferDelayNs
                    + UInt64(Double(framesGenerated + UInt64(frame)) / rate * 1e9)
                let chunk = AudioChunk(
                    sequence: sequence, playAtMasterNs: playAt,
                    sampleRate: rate, channels: channels,
                    samples: Array(block[(frame * channels)..<((frame + n) * channels)])
                )
                let data = Wire.encode(.audio(chunk))
                if rng.uniform() < lossProbability {
                    lostChunkSpans.append((playAt, chunk.endMasterNs))
                } else {
                    inFlight.append(InFlight(data: data, arrivalMasterNs: clocks.masterNowNs + networkDelay()))
                    if rng.uniform() < duplicateProbability {
                        inFlight.append(InFlight(data: data, arrivalMasterNs: clocks.masterNowNs + networkDelay()))
                    }
                }
                frame += n
            }
            framesGenerated += UInt64(framesPerBlock)

            // --- clock probe every 250 ms of stream time ---
            if tick % 25 == 24 { runClockExchange() }

            clocks.advance(ns: tickNs)

            // --- network: deliver everything that has arrived (UDP order
            //     not guaranteed: deliver in randomized order) ---
            var due = [Int]()
            for (i, packet) in inFlight.enumerated() where packet.arrivalMasterNs <= clocks.masterNowNs {
                due.append(i)
            }
            // Shuffle deterministically.
            if due.count > 1 {
                for i in stride(from: due.count - 1, to: 0, by: -1) {
                    due.swapAt(i, rng.int(0, i))
                }
            }
            for i in due {
                if case .audio(let chunk) = try Wire.decode(inFlight[i].data) {
                    buffer.insert(chunk)
                }
            }
            for i in due.sorted(by: >) { inFlight.remove(at: i) }

            // --- receiver: render one contiguous 10 ms master window ---
            let masterEstimate = try #require(sync.masterNs(forClientNs: clocks.clientNowNs),
                                              "clock must be synced after warmup")
            let start: UInt64
            if let w = windowStartNs {
                start = w
            } else {
                start = masterEstimate
                result.firstWindowStartNs = masterEstimate
            }
            let stats = TimelineRenderer.render(
                chunks: buffer.chunksOverlapping(startNs: start, endNs: start + tickNs),
                into: &scratch,
                frames: framesPerBlock, channels: channels,
                sampleRate: rate, windowStartMasterNs: start
            )
            buffer.dropChunks(endingBefore: start)
            result.rendered.append(contentsOf: scratch[0..<(framesPerBlock * channels)])
            windowStartNs = start + tickNs

            // Steady state: window fully inside the streamed tone. Any chunk
            // in this range was generated ≥ bufferDelay (300 ms) ago and the
            // worst-case network detour is 33 ms, so it must have arrived.
            if start >= result.toneStartNs + tickNs,
               start + tickNs <= result.toneStartNs + UInt64(Double(framesGenerated) / rate * 1e9) {
                result.steadySilentFrames += stats.framesSilent
                result.steadyWindows += 1
            }
        }

        result.syncErrorNs = try #require(sync.offsetNs) - clocks.trueOffsetNs
        result.duplicateCount = buffer.duplicateCount
        result.insertedCount = buffer.insertedCount
        // Frames of audio that were deliberately lost.
        for span in lostChunkSpans {
            result.lostChunkFrames += Int(Double(span.endNs - span.startNs) * rate / 1e9 + 0.5)
        }
        return result
    }

    /// Index of the first interleaved sample where rendered audio (shifted to
    /// the tone's start position) differs from what was sent, or nil if equal.
    private func firstMismatch(_ result: SimResult, channels: Int = 2) -> Int? {
        let rate = 48_000.0
        let deltaFrames = Int((Double(result.toneStartNs - result.firstWindowStartNs) * rate / 1e9).rounded())
        guard deltaFrames >= 0 else { return -1 }
        let renderedTail = Array(result.rendered.dropFirst(deltaFrames * channels))
        let n = min(renderedTail.count, result.referenceSent.count)
        for i in 0..<n where renderedTail[i].bitPattern != result.referenceSent[i].bitPattern {
            return i
        }
        return nil
    }

    // MARK: - The tests

    @Test func losslessSyncedPlaybackAcrossDriftingClocks() throws {
        let result = try runSimulation(seed: 31_337, driftPpm: 6)

        // 1. Clock sync accuracy: sub-millisecond against ground truth.
        #expect(abs(result.syncErrorNs) < 300_000,
                "clock sync error \(Double(result.syncErrorNs) / 1e6) ms exceeds 0.3 ms")

        // 2. No dropouts: once the stream is flowing, every steady-state
        // window must be completely filled with audio.
        #expect(result.steadyWindows > 900, "expected ~10 s of steady windows, got \(result.steadyWindows)")
        #expect(result.steadySilentFrames == 0, "audible dropouts in steady state")

        // 3. Bit-exact audio: the rendered master timeline must reproduce
        // the sent samples exactly, at the frame position the timestamps
        // dictate.
        let mismatch = firstMismatch(result)
        #expect(mismatch == nil, "rendered audio diverges from sent audio at interleaved index \(mismatch ?? -1)")
        #expect(result.rendered.count > Int(48_000.0) * 2 * 8, "should compare at least 8 s of audio")
    }

    @Test func duplicatedPacketsAreDeduplicatedAndHarmless() throws {
        let result = try runSimulation(seed: 777, driftPpm: 6, duplicateProbability: 0.05)
        #expect(result.duplicateCount > 0, "test must actually exercise duplicates")
        #expect(result.steadySilentFrames == 0)
        let mismatch = firstMismatch(result)
        #expect(mismatch == nil, "duplicates corrupted audio at index \(mismatch ?? -1)")
    }

    @Test func packetLossProducesBoundedSilenceOnly() throws {
        // 1% packet loss: lost chunks must come out as silence in exactly
        // their own time slots — they must not shift or corrupt the rest.
        let result = try runSimulation(seed: 4_242, driftPpm: 6, lossProbability: 0.01)

        #expect(result.lostChunkFrames > 0, "test must actually lose packets")
        // Silence must stay within a chunk-or-so of the exact lost duration
        // (edge chunks may fall partly outside the steady window range).
        #expect(result.steadySilentFrames <= result.lostChunkFrames + 480,
                "silence (\(result.steadySilentFrames)) exceeds lost audio (\(result.lostChunkFrames)) — something else is dropping frames")
        #expect(result.steadySilentFrames >= result.lostChunkFrames - 480 * 4,
                "silence (\(result.steadySilentFrames)) far below lost audio (\(result.lostChunkFrames)) — renderer inventing audio?")

        // Non-lost audio must still come through.
        let renderedNonZero = result.rendered.lazy.filter { $0 != 0 }.count
        let sentNonZero = result.referenceSent.lazy.filter { $0 != 0 }.count
        let lostSamples = result.lostChunkFrames * 2
        #expect(renderedNonZero > sentNonZero - lostSamples - 480 * 2 * 40,
                "too much audio missing beyond the lost packets")
    }

    @Test func highDriftStillStaysAligned() throws {
        // 25 ppm is a pessimistic crystal mismatch (≈ 90 ms/hour). The
        // sliding-window sync must still hold sub-millisecond alignment over
        // 20 simulated seconds.
        let result = try runSimulation(seed: 1, driftPpm: 25, seconds: 20)
        #expect(abs(result.syncErrorNs) < 500_000)
        #expect(result.steadySilentFrames == 0)
        #expect(firstMismatch(result) == nil)
    }
}
