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

    @Test func guardRejectsMismatchedLengths() {
        // The real-time-safety bounds guard must no-op (not read OOB) when the
        // coverage/buffer/frames don't agree — leaving the buffer untouched.
        let c = GapConcealer(channels: 2, sampleRate: rate)
        var buf1 = [Float](repeating: 0.3, count: 8) // 4 frames * 2ch
        let orig1 = buf1
        c.process(&buf1, coverage: [true, true], frames: 4) // coverage too short
        #expect(buf1 == orig1, "too-short coverage must no-op")

        var buf2 = [Float](repeating: 0.3, count: 4) // only 2 frames at 2ch
        let orig2 = buf2
        c.process(&buf2, coverage: [Bool](repeating: true, count: 4), frames: 4) // buffer too short
        #expect(buf2 == orig2, "too-short buffer must no-op")

        var buf3 = [Float](repeating: 0.3, count: 8)
        let orig3 = buf3
        c.process(&buf3, coverage: [Bool](repeating: true, count: 4), frames: 0)
        #expect(buf3 == orig3, "frames <= 0 must no-op")
    }

    @Test func stereoChannelsAreHeldAndDecayIndependently() {
        // Per-channel hold/decay through a gap, with distinct L/R values — would
        // catch an interleaved-indexing bug (e.g. swapping or holding the wrong
        // channel) that a mono test can't.
        let c = GapConcealer(channels: 2, sampleRate: rate)
        let covered = 4, gap = 200, frames = covered + gap
        var buf = [Float](repeating: 0, count: frames * 2)
        for f in 0..<covered { buf[f * 2] = 0.5; buf[f * 2 + 1] = -0.3 }
        var cov = [Bool](repeating: true, count: frames)
        for f in covered..<frames { cov[f] = false }
        c.process(&buf, coverage: cov, frames: frames)

        // First gap frame holds each channel's OWN last value.
        #expect(buf[covered * 2] == 0.5)
        #expect(buf[covered * 2 + 1] == -0.3)
        // Each channel decays toward 0 independently: L stays positive and
        // non-increasing, R stays negative and rises toward 0 (no L/R swap).
        for f in (covered + 1)..<frames {
            #expect(buf[f * 2] >= 0 && buf[f * 2] <= buf[(f - 1) * 2])
            #expect(buf[f * 2 + 1] <= 0 && buf[f * 2 + 1] >= buf[(f - 1) * 2 + 1])
        }
        #expect(abs(buf[(frames - 1) * 2]) < 0.05 && abs(buf[(frames - 1) * 2 + 1]) < 0.05,
                "both channels fade out within the gap")
    }

    @Test func gapSpanningMultipleProcessCallsStaysContinuous() {
        // A dropout that straddles render-buffer boundaries: state must persist
        // across process() calls (decay continues, no per-call reset/pop).
        let gc = GapConcealer(channels: 1, sampleRate: rate)
        var bufA = [Float](repeating: 0.5, count: 200) // 100 covered, then gap
        for f in 100..<200 { bufA[f] = 0 }
        var covA = [Bool](repeating: true, count: 200)
        for f in 100..<200 { covA[f] = false }
        gc.process(&bufA, coverage: covA, frames: 200)

        var bufB = [Float](repeating: 0, count: 200) // entirely inside the gap
        gc.process(&bufB, coverage: [Bool](repeating: false, count: 200), frames: 200)

        var bufC = [Float](repeating: 0.5, count: 200) // audio resumes
        gc.process(&bufC, coverage: [Bool](repeating: true, count: 200), frames: 200)

        // The decay continued across the A→B seam (gain did NOT reset to 1).
        #expect(bufB[0] <= bufA[199] + 1e-6, "decay must continue across the buffer boundary")
        #expect(bufB[0] < 0.5, "B is deep in the decayed tail, not a fresh hold")
        // No click at any seam across the whole joined stream.
        #expect(maxStep(bufA + bufB + bufC, channels: 1) < 0.05)
    }
}
