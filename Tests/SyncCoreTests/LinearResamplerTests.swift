import Testing
import Foundation
@testable import SyncCore

@Suite struct LinearResamplerTests {

    @Test func passthroughWhenRatesEqualIsBitExact() {
        let resampler = LinearResampler(sourceRate: 48_000, targetRate: 48_000, channels: 2)
        var rng = SeededRandom(seed: 5)
        let input = (0..<640).map { _ in Float(rng.uniform(-1, 1)) }
        #expect(resampler.process(input).map(\.bitPattern) == input.map(\.bitPattern))
    }

    @Test func outputLengthConvergesToRateRatio() {
        // 44.1k -> 48k over many chunks: total output frames must track
        // input * 48/44.1 within a frame or two.
        let resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000, channels: 2)
        var totalIn = 0
        var totalOut = 0
        var rng = SeededRandom(seed: 9)
        for _ in 0..<200 {
            let frames = rng.int(400, 600)
            let input = [Float](repeating: 0.25, count: frames * 2)
            totalIn += frames
            totalOut += resampler.process(input).count / 2
        }
        let expected = Double(totalIn) * 48_000 / 44_100
        #expect(abs(Double(totalOut) - expected) <= 2,
                "expected ~\(expected) frames, got \(totalOut)")
    }

    @Test func preservesSineFrequencyAcrossChunkBoundaries() {
        // A 1 kHz sine at 44.1k resampled to 48k in awkward chunk sizes must
        // still be a 1 kHz sine: same zero-crossing count per second, and no
        // discontinuities at chunk joins.
        let source = ToneGenerator(frequency: 1_000, sampleRate: 44_100, amplitude: 0.5, channels: 1)
        let resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000, channels: 1)
        var output = [Float]()
        var produced = 0
        while produced < 44_100 { // one second of source
            let chunk = source.nextChunk(frameCount: 441) // 10 ms
            output.append(contentsOf: resampler.process(chunk))
            produced += 441
        }
        // ~48000 output samples expected.
        #expect(abs(output.count - 48_000) <= 2)

        var crossings = 0
        for i in 1..<output.count where output[i - 1] < 0 && output[i] >= 0 {
            crossings += 1
        }
        #expect(abs(crossings - 1_000) <= 2, "got \(crossings) zero crossings, expected ~1000")

        // Continuity: max sample-to-sample step of a 1 kHz/0.5-amp sine at
        // 48k is 2π·1000/48000·0.5 ≈ 0.0654; allow small headroom. A glitch
        // at a chunk boundary would blow way past this.
        var maxStep: Float = 0
        for i in 1..<output.count {
            maxStep = max(maxStep, abs(output[i] - output[i - 1]))
        }
        #expect(maxStep < 0.07, "discontinuity detected: max step \(maxStep)")
    }

    @Test func downsamplingHalvesFrameCount() {
        let resampler = LinearResampler(sourceRate: 96_000, targetRate: 48_000, channels: 2)
        let input = [Float](repeating: 0.1, count: 960 * 2)
        let out = resampler.process(input)
        #expect(abs(out.count / 2 - 480) <= 1)
    }

    @Test func stereoChannelsStayIndependent() {
        // L ramps up, R ramps down; after resampling L must still be
        // ascending and R descending (no channel bleed/swap).
        let resampler = LinearResampler(sourceRate: 44_100, targetRate: 48_000, channels: 2)
        var input = [Float]()
        for i in 0..<441 {
            input.append(Float(i) / 441)        // L
            input.append(1 - Float(i) / 441)    // R
        }
        let out = resampler.process(input)
        let frames = out.count / 2
        #expect(frames > 100)
        for f in 2..<frames {
            #expect(out[f * 2] >= out[(f - 1) * 2] - 1e-4, "L must be non-decreasing")
            #expect(out[f * 2 + 1] <= out[(f - 1) * 2 + 1] + 1e-4, "R must be non-increasing")
        }
    }
}
