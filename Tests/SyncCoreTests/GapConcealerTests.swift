import Testing
import Foundation
@testable import SyncCore

@Suite struct GapConcealerTests {

    private let rate = 48_000.0

    /// Largest step between consecutive output samples (per channel) — a proxy
    /// for "clickiness". Real audio has small steps; a hard silence seam is a
    /// big one.
    private func maxStep(_ buf: [Float], channels: Int) -> Float {
        var m: Float = 0
        for ch in 0..<channels {
            var i = ch
            var prev = buf[i]
            i += channels
            while i < buf.count {
                m = max(m, abs(buf[i] - prev))
                prev = buf[i]
                i += channels
            }
        }
        return m
    }

    @Test func fullyCoveredAudioPassesThroughUnchanged() {
        let c = GapConcealer(channels: 2, sampleRate: rate)
        var buf = (0..<320).map { Float(sin(Double($0) * 0.05)) }
        let original = buf
        c.process(&buf, coverage: [Bool](repeating: true, count: 160), frames: 160)
        #expect(buf == original, "no gaps → identity")
    }

    @Test func gapStartHasNoStep() {
        // Constant 0.5 for a while, then a gap. The first gap sample must equal
        // the last real sample (zero step), not snap to 0.
        let c = GapConcealer(channels: 1, sampleRate: rate)
        var buf = [Float](repeating: 0.5, count: 200)
        for f in 100..<200 { buf[f] = 0 } // renderer wrote silence for the gap
        var cov = [Bool](repeating: true, count: 200)
        for f in 100..<200 { cov[f] = false }
        c.process(&buf, coverage: cov, frames: 200)
        #expect(buf[99] == 0.5)
        #expect(buf[100] == 0.5, "first gap frame must hold the last good sample, not jump to 0")
        // The held tail then decays smoothly and monotonically toward 0.
        for f in 101..<200 { #expect(buf[f] <= buf[f - 1] && buf[f] >= 0) }
        #expect(buf[199] < 0.05, "tail should have faded out within the gap")
    }

    @Test func resumeHasNoLargeStep() {
        // A 30 ms gap then audio returns at a high level; the seam back in must
        // be gradual, not a jump.
        let c = GapConcealer(channels: 1, sampleRate: rate)
        let gapFrames = Int(0.03 * rate)
        let total = gapFrames + 480
        var buf = [Float](repeating: 0, count: total)
        for f in gapFrames..<total { buf[f] = 0.9 }
        var cov = [Bool](repeating: false, count: total)
        for f in gapFrames..<total { cov[f] = true }
        c.process(&buf, coverage: cov, frames: total)
        // No single-sample jump should approach the full 0.9 amplitude.
        #expect(maxStep(buf, channels: 1) < 0.2, "resume must crossfade in, not snap")
        // And it must reach the true level by the end of the ramp.
        #expect(abs(buf[total - 1] - 0.9) < 1e-4)
    }

    @Test func gapConcealmentIsMuchSmootherThanHardSilence() {
        // Compare the click metric: hard silence vs concealed.
        let channels = 1
        var hard = [Float](repeating: 0.6, count: 300)
        for f in 100..<200 { hard[f] = 0 }       // raw renderer output (clicks)
        var cov = [Bool](repeating: true, count: 300)
        for f in 100..<200 { cov[f] = false }
        let hardStep = maxStep(hard, channels: channels)

        let c = GapConcealer(channels: channels, sampleRate: rate)
        var concealed = hard
        c.process(&concealed, coverage: cov, frames: 300)
        let concealedStep = maxStep(concealed, channels: channels)

        #expect(hardStep >= 0.5, "hard silence has a big click step")
        #expect(concealedStep < hardStep / 4, "concealment removes most of the click")
    }
}
