import Foundation

/// Click-free concealment of silence gaps in an interleaved audio buffer.
///
/// The timeline renderer leaves hard zeros wherever audio was late or lost.
/// Playing those zeros means the signal snaps to 0 and back — an audible click
/// at each seam, which is what a dropped packet *sounds* like even though only
/// a few milliseconds went missing. This smooths both seams:
///
/// - **Into a gap:** the first missing frame emits the last good sample (so the
///   step is zero), then decays that held value toward 0 over a few ms.
/// - **Out of a gap:** real audio is crossfaded back in over a few ms against
///   the still-decaying held tail, so the return is gradual too.
///
/// Fully-covered audio passes through bit-exactly. State persists across calls
/// (and across reconnects), so a gap that spans render buffers is handled
/// continuously.
public final class GapConcealer {
    private let channels: Int
    private var held: [Float]       // last good sample per channel
    private var source: [Float]     // value frozen when the current gap began
    private var gain: Float = 0     // multiplies `source` through a gap (decays)
    private var xfade: Float = 1    // 0→1 crossfade applied when audio returns
    private var inGap = false
    private let decayPerFrame: Float
    private let rampPerFrame: Float

    /// - fadeMs: time for a gap's held tail to fall to ~‑62 dB.
    /// - resumeMs: time to crossfade real audio back in after a gap.
    public init(channels: Int, sampleRate: Double, fadeMs: Double = 6, resumeMs: Double = 3) {
        self.channels = channels
        self.held = [Float](repeating: 0, count: channels)
        self.source = [Float](repeating: 0, count: channels)
        self.decayPerFrame = powf(0.0008, 1.0 / Float(max(1, fadeMs / 1000 * sampleRate)))
        self.rampPerFrame = 1.0 / Float(max(1, resumeMs / 1000 * sampleRate))
    }

    /// Conceal gaps in `buffer` (interleaved, `frames * channels` samples) using
    /// `coverage` (true = real audio present for that frame). `buffer` is
    /// modified in place.
    public func process(_ buffer: inout [Float], coverage: [Bool], frames: Int) {
        guard frames > 0, coverage.count >= frames, buffer.count >= frames * channels else { return }
        buffer.withUnsafeMutableBufferPointer { s in
            coverage.withUnsafeBufferPointer { cov in
                for f in 0..<frames {
                    let base = f * channels
                    if cov[f] {
                        if inGap { inGap = false; xfade = 0 }
                        if xfade < 1 {
                            for ch in 0..<channels {
                                let real = s[base + ch]
                                let tail = source[ch] * gain
                                s[base + ch] = tail * (1 - xfade) + real * xfade
                                held[ch] = real
                            }
                            xfade = min(1, xfade + rampPerFrame)
                            gain *= decayPerFrame
                        } else {
                            for ch in 0..<channels { held[ch] = s[base + ch] }
                        }
                    } else {
                        if !inGap {
                            inGap = true
                            gain = 1
                            for ch in 0..<channels { source[ch] = held[ch] }
                        }
                        for ch in 0..<channels { s[base + ch] = source[ch] * gain }
                        gain *= decayPerFrame
                    }
                }
            }
        }
    }
}
