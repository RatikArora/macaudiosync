import Testing
import Foundation
@testable import AudioPipeline

@Suite struct SpectrumAnalyzerTests {

    private let rate = 48_000.0

    private func feedSine(_ analyzer: SpectrumAnalyzer, freq: Double, frames: Int, amplitude: Float = 0.5) {
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let s = amplitude * Float(sin(2 * Double.pi * freq * Double(i) / rate))
            interleaved[i * 2] = s
            interleaved[i * 2 + 1] = s
        }
        interleaved.withUnsafeBufferPointer { analyzer.append($0, frames: frames, channels: 2) }
    }

    @Test func toneShowsUpInTheBandThatContainsItsFrequency() {
        let analyzer = SpectrumAnalyzer(bandCount: 32, sampleRate: rate)
        feedSine(analyzer, freq: 1_000, frames: 4_096)
        let bands = analyzer.bands()
        #expect(bands.count == 32)
        let peakBand = bands.indices.max(by: { bands[$0] < bands[$1] })!
        // Log spacing 40 Hz…16 kHz over 32 bands puts 1 kHz around band 17.
        #expect(peakBand >= 14 && peakBand <= 20, "1 kHz peaked at band \(peakBand)")
        #expect(bands[peakBand] > 0.5, "the tone's band should be near full scale")
    }

    @Test func lowToneAndHighTonePeakInDifferentBands() {
        let low = SpectrumAnalyzer(bandCount: 32, sampleRate: rate)
        feedSine(low, freq: 120, frames: 4_096)
        let lowPeak = low.bands().indices.max(by: { low.bands()[$0] < low.bands()[$1] })!

        let high = SpectrumAnalyzer(bandCount: 32, sampleRate: rate)
        feedSine(high, freq: 8_000, frames: 4_096)
        let highBands = high.bands()
        let highPeak = highBands.indices.max(by: { highBands[$0] < highBands[$1] })!

        #expect(lowPeak < highPeak, "bass must sit left of treble (\(lowPeak) vs \(highPeak))")
    }

    @Test func silenceReadsFlat() {
        let analyzer = SpectrumAnalyzer(sampleRate: rate)
        let silent = [Float](repeating: 0, count: 4_096)
        silent.withUnsafeBufferPointer { analyzer.append($0, frames: 2_048, channels: 2) }
        #expect(analyzer.bands().allSatisfy { $0 == 0 }, "true silence must not be amplified into noise")
    }
}
