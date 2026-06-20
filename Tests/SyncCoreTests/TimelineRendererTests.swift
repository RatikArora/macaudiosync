import Testing
import Foundation
@testable import SyncCore

@Suite struct TimelineRendererTests {

    private let rate = 48_000.0
    private let channels = 2

    private func render(_ chunks: [AudioChunk], frames: Int, windowStartNs: UInt64) -> (out: [Float], stats: TimelineRenderer.RenderStats) {
        var out = [Float](repeating: .nan, count: frames * channels) // NaN to catch un-overwritten cells
        let stats = TimelineRenderer.render(
            chunks: chunks, into: &out, frames: frames, channels: channels,
            sampleRate: rate, windowStartMasterNs: windowStartNs
        )
        return (out, stats)
    }

    private func nsForFrames(_ frames: Int) -> UInt64 {
        UInt64(Double(frames) / rate * 1e9)
    }

    @Test func perfectlyAlignedChunkCopiesSampleExact() {
        let samples = (0..<320).map { Float($0) / 320.0 }
        let chunk = AudioChunk(sequence: 1, playAtMasterNs: 1_000_000_000, sampleRate: rate, channels: channels, samples: samples)
        let (out, stats) = render([chunk], frames: 160, windowStartNs: 1_000_000_000)
        #expect(out == samples)
        #expect(stats.framesFilled == 160)
        #expect(stats.framesSilent == 0)
    }

    @Test func emptyBufferRendersPureSilence() {
        let (out, stats) = render([], frames: 480, windowStartNs: 0)
        #expect(out.allSatisfy { $0 == 0 }, "must zero the buffer even with nothing to play")
        #expect(stats.framesSilent == 480)
        #expect(stats.framesFilled == 0)
    }

    @Test func chunkStartingMidWindowGetsSilenceThenAudio() {
        // Chunk begins exactly 100 frames into a 260-frame window.
        let windowStart: UInt64 = 5_000_000_000
        let chunkStart = windowStart + nsForFrames(100)
        let chunk = AudioChunk(
            sequence: 1, playAtMasterNs: chunkStart, sampleRate: rate, channels: channels,
            samples: [Float](repeating: 0.7, count: 160 * channels)
        )
        let (out, stats) = render([chunk], frames: 260, windowStartNs: windowStart)
        for frame in 0..<100 {
            #expect(out[frame * channels] == 0, "frame \(frame) should be silent")
        }
        for frame in 100..<260 {
            #expect(out[frame * channels] == 0.7, "frame \(frame) should carry audio")
        }
        #expect(stats.framesFilled == 160)
        #expect(stats.framesSilent == 100)
    }

    @Test func chunkStartedBeforeWindowReadsFromCorrectSourceOffset() {
        // Chunk of 320 ascending samples starts 100 frames before the window:
        // the window's first frame must be source frame 100, not frame 0.
        let chunkStart: UInt64 = 2_000_000_000
        let windowStart = chunkStart + nsForFrames(100)
        let samples = (0..<320).flatMap { [Float($0), Float($0)] } // L=R=frame index
        let chunk = AudioChunk(sequence: 1, playAtMasterNs: chunkStart, sampleRate: rate, channels: channels, samples: samples)
        let (out, _) = render([chunk], frames: 160, windowStartNs: windowStart)
        for frame in 0..<160 {
            #expect(out[frame * channels] == Float(100 + frame), "window frame \(frame) must map to source frame \(100 + frame)")
        }
    }

    @Test func gapBetweenChunksRendersSilenceInBetween() {
        // Two 100-frame chunks with a 50-frame hole between them (lost packet).
        let chunkA = AudioChunk(sequence: 1, playAtMasterNs: 0, sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.3, count: 100 * channels))
        let chunkB = AudioChunk(sequence: 3, playAtMasterNs: nsForFrames(150), sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.9, count: 100 * channels))
        let (out, stats) = render([chunkA, chunkB], frames: 250, windowStartNs: 0)
        for frame in 0..<100 { #expect(out[frame * channels] == 0.3) }
        for frame in 100..<150 { #expect(out[frame * channels] == 0, "lost-packet gap must be silence") }
        for frame in 150..<250 { #expect(out[frame * channels] == 0.9) }
        #expect(stats.framesFilled == 200)
        #expect(stats.framesSilent == 50)
    }

    @Test func continuousSineSurvivesChunkingAndWindowingExactly() {
        // The full pipeline property that makes audio click-free: a sine
        // split into 160-frame chunks, rendered through misaligned windows
        // (size 191, deliberately coprime with chunk size), must reassemble
        // bit-exactly into the original signal.
        let generator = ToneGenerator(frequency: 440, sampleRate: rate, amplitude: 0.5, channels: channels)
        let totalFrames = 4_800 // 100 ms
        let reference = generator.nextChunk(frameCount: totalFrames)

        // Chunk the reference as the sender would.
        var chunks: [AudioChunk] = []
        let streamStart: UInt64 = 10_000_000_000
        var frame = 0
        var seq: UInt32 = 0
        while frame < totalFrames {
            let n = min(160, totalFrames - frame)
            seq += 1
            chunks.append(AudioChunk(
                sequence: seq,
                playAtMasterNs: streamStart + nsForFrames(frame),
                sampleRate: rate, channels: channels,
                samples: Array(reference[(frame * channels)..<((frame + n) * channels)])
            ))
            frame += n
        }

        // Render through awkward window sizes.
        var reassembled = [Float]()
        var windowFrame = 0
        while windowFrame < totalFrames {
            let n = min(191, totalFrames - windowFrame)
            let (out, stats) = render(chunks, frames: n, windowStartNs: streamStart + nsForFrames(windowFrame))
            reassembled.append(contentsOf: out[0..<(n * channels)])
            #expect(stats.framesSilent == 0, "no silence expected mid-stream at window frame \(windowFrame)")
            windowFrame += n
        }

        #expect(reassembled.map(\.bitPattern) == reference.map(\.bitPattern),
                "chunking + windowed rendering must be lossless")
    }

    @Test func overlappingChunksDoNotDoubleCountFill() {
        // Two identical chunks covering the same span (e.g. duplicate that
        // slipped through with a different sequence number).
        let chunk1 = AudioChunk(sequence: 1, playAtMasterNs: 0, sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.4, count: 160 * channels))
        let chunk2 = AudioChunk(sequence: 2, playAtMasterNs: 0, sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.4, count: 160 * channels))
        let (_, stats) = render([chunk1, chunk2], frames: 160, windowStartNs: 0)
        #expect(stats.framesFilled == 160, "fill accounting must union overlaps, not sum them")
    }

    @Test func channelCountMismatchIsSkippedNotCorrupted() {
        // A mono chunk reaching a stereo renderer must be ignored, not
        // misinterpreted as interleaved stereo.
        let mono = AudioChunk(sequence: 1, playAtMasterNs: 0, sampleRate: rate, channels: 1,
                              samples: [Float](repeating: 0.8, count: 160))
        let (out, stats) = render([mono], frames: 160, windowStartNs: 0)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(stats.framesFilled == 0)
    }

    @Test func coverageMaskMarksFilledAndGapFrames() {
        // Two 100-frame chunks with a 50-frame hole: coverage must be true on
        // the filled spans and false in the gap, so the concealer knows where
        // to smooth.
        let chunkA = AudioChunk(sequence: 1, playAtMasterNs: 0, sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.3, count: 100 * channels))
        let chunkB = AudioChunk(sequence: 3, playAtMasterNs: nsForFrames(150), sampleRate: rate, channels: channels,
                                samples: [Float](repeating: 0.9, count: 100 * channels))
        var out = [Float](repeating: 0, count: 250 * channels)
        var coverage: [Bool] = []
        TimelineRenderer.render(chunks: [chunkA, chunkB], into: &out, frames: 250,
                                channels: channels, sampleRate: rate,
                                windowStartMasterNs: 0, coverage: &coverage)
        #expect(coverage.count == 250)
        for f in 0..<100 { #expect(coverage[f]) }
        for f in 100..<150 { #expect(!coverage[f], "gap frame \(f) must be uncovered") }
        for f in 150..<250 { #expect(coverage[f]) }
    }

    @Test func subFrameTimestampJitterRoundsToNearestFrame() {
        // A chunk whose timestamp is off by 0.4 of a frame period (8.3µs)
        // must still land on the nearest frame slot — sub-frame network
        // timing noise must not shift audio by a whole frame.
        let jitterNs = UInt64(0.4 / rate * 1e9)
        let chunk = AudioChunk(sequence: 1, playAtMasterNs: 1_000_000_000 + jitterNs,
                               sampleRate: rate, channels: channels,
                               samples: [Float](repeating: 0.6, count: 160 * channels))
        let (out, _) = render([chunk], frames: 160, windowStartNs: 1_000_000_000)
        #expect(out[0] == 0.6, "0.4-frame jitter should round to frame 0")
    }
}

@Suite struct ToneGeneratorTests {

    @Test func phaseContinuityAcrossChunkBoundaries() {
        // Generating in many small chunks must equal generating in one shot.
        let chunked = ToneGenerator(frequency: 440, sampleRate: 48_000, amplitude: 0.5, channels: 1)
        let oneShot = ToneGenerator(frequency: 440, sampleRate: 48_000, amplitude: 0.5, channels: 1)
        var viaChunks = [Float]()
        for _ in 0..<100 { viaChunks.append(contentsOf: chunked.nextChunk(frameCount: 48)) }
        let reference = oneShot.nextChunk(frameCount: 4_800)
        for (a, b) in zip(viaChunks, reference) {
            #expect(abs(a - b) <= 1e-5)
        }
    }

    @Test func frequencyViaZeroCrossings() {
        let generator = ToneGenerator(frequency: 1_000, sampleRate: 48_000, amplitude: 0.5, channels: 1)
        let seconds = 1.0
        let samples = generator.nextChunk(frameCount: Int(48_000 * seconds))
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 {
            crossings += 1
        }
        // One positive-going crossing per cycle.
        #expect(abs(Double(crossings) - 1_000 * seconds) <= 2)
    }

    @Test func amplitudeBounded() {
        let generator = ToneGenerator(frequency: 440, sampleRate: 48_000, amplitude: 0.2, channels: 2)
        let samples = generator.nextChunk(frameCount: 48_000)
        #expect(samples.map(abs).max()! <= 0.2 + 1e-6)
    }
}
