import Foundation

/// Maps buffered audio chunks onto an output window of the master timeline.
///
/// This is the piece that makes playback *synchronized* rather than merely
/// *streamed*: every render callback asks "what does the master timeline say
/// should be coming out of the speaker during [windowStart, windowStart + N
/// frames)?" and we answer by copying the overlapping chunk samples into the
/// right frame positions. Missing audio (not yet arrived / lost) renders as
/// silence; alignment is recomputed from timestamps every window, so DAC
/// clock drift cannot accumulate into growing desync — at worst a chunk
/// boundary repeats or skips a single frame every few tens of seconds.
///
/// That single-frame skip/repeat is a faint periodic click on real speakers,
/// so the live playback path (`SyncedPlayer`) uses `renderResampled` instead:
/// it advances a continuous fractional playhead and interpolates, correcting
/// DAC drift by micro-resampling rather than snapping whole frames. This plain
/// `render` (whole-frame grid) is still used by the headless test renderer and
/// is the bit-exact reference `renderResampled` collapses to when ratio == 1.
public enum TimelineRenderer {
    public struct RenderStats: Equatable {
        /// Frames in the window that were covered by buffered audio.
        public var framesFilled = 0
        /// Frames left as silence (gap, loss, or not-yet-arrived).
        public var framesSilent = 0
        public init() {}
    }

    /// Render `frames` frames of interleaved audio for the master-time window
    /// starting at `windowStartMasterNs` into `out` (which must hold at least
    /// `frames * channels` floats; it is fully overwritten).
    @discardableResult
    public static func render(
        chunks: [AudioChunk],
        into out: inout [Float],
        frames: Int,
        channels: Int,
        sampleRate: Double,
        windowStartMasterNs: UInt64
    ) -> RenderStats {
        var noCoverage: [Bool] = []
        return render(chunks: chunks, into: &out, frames: frames, channels: channels,
                      sampleRate: sampleRate, windowStartMasterNs: windowStartMasterNs,
                      coverage: &noCoverage, wantCoverage: false)
    }

    /// As above, but also writes a per-frame coverage mask (`coverage[f]` is
    /// true iff frame `f` was filled by real audio, false for a gap). The
    /// playback layer uses this to conceal gaps with click-free fades instead
    /// of emitting hard silence. `coverage` is resized to `frames` if needed.
    @discardableResult
    public static func render(
        chunks: [AudioChunk],
        into out: inout [Float],
        frames: Int,
        channels: Int,
        sampleRate: Double,
        windowStartMasterNs: UInt64,
        coverage: inout [Bool]
    ) -> RenderStats {
        if coverage.count != frames { coverage = [Bool](repeating: false, count: frames) }
        return render(chunks: chunks, into: &out, frames: frames, channels: channels,
                      sampleRate: sampleRate, windowStartMasterNs: windowStartMasterNs,
                      coverage: &coverage, wantCoverage: true)
    }

    @discardableResult
    private static func render(
        chunks: [AudioChunk],
        into out: inout [Float],
        frames: Int,
        channels: Int,
        sampleRate: Double,
        windowStartMasterNs: UInt64,
        coverage: inout [Bool],
        wantCoverage: Bool
    ) -> RenderStats {
        precondition(out.count >= frames * channels)
        for i in 0..<(frames * channels) { out[i] = 0 }
        if wantCoverage { for i in 0..<frames { coverage[i] = false } }

        var stats = RenderStats()
        guard frames > 0 else { return stats }

        // Filled-frame accounting via interval union (chunks may overlap).
        var filledIntervals: [(start: Int, end: Int)] = []

        for chunk in chunks where chunk.channels == channels {
            // Position of the chunk's first frame relative to the window
            // start, in frames (can be negative: chunk started earlier).
            let deltaNs = Double(Int64(bitPattern: chunk.playAtMasterNs &- windowStartMasterNs))
            let chunkStartFrame = Int((deltaNs * sampleRate / 1e9).rounded())

            let srcStart = max(0, -chunkStartFrame)
            let dstStart = max(0, chunkStartFrame)
            let n = min(chunk.frameCount - srcStart, frames - dstStart)
            guard n > 0 else { continue }

            chunk.samples.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let srcBase = srcStart * channels
                    let dstBase = dstStart * channels
                    for i in 0..<(n * channels) {
                        dst[dstBase + i] = src[srcBase + i]
                    }
                }
            }
            filledIntervals.append((dstStart, dstStart + n))
        }

        if wantCoverage {
            for iv in filledIntervals {
                let s = max(0, iv.start), e = min(frames, iv.end)
                if s < e { for f in s..<e { coverage[f] = true } }
            }
        }

        stats.framesFilled = unionLength(of: filledIntervals, clampedTo: frames)
        stats.framesSilent = frames - stats.framesFilled
        return stats
    }

    /// Render `frames` output frames that are NOT on the master frame grid:
    /// output frame `f` reads the master timeline at fractional master-frame
    /// position `startOffsetFrames + f * ratio` (relative to `windowStartMasterNs`),
    /// linearly interpolating between the two bracketing master frames.
    ///
    /// This is what lets a receiver play in lock-step with its own DAC crystal
    /// WITHOUT ever skipping or repeating a whole frame: instead of snapping the
    /// render window to the master clock every callback (which drops/duplicates a
    /// sample at each clock correction — a faint periodic tick), the playback
    /// layer advances a continuous fractional playhead and asks for exactly the
    /// resampled slice. `ratio` is the master-frames-consumed per output-frame
    /// (≈ 1; a drift servo nudges it by a few tens of ppm to stay time-aligned).
    ///
    /// At `ratio == 1` and `startOffsetFrames == 0` every interpolation lands
    /// exactly on a grid frame, so this reproduces `render(...)` bit-for-bit —
    /// the existing bit-exact guarantees hold when there is nothing to resample.
    ///
    /// A frame is marked covered only if BOTH bracketing master frames were
    /// covered, so the gap concealer still sees (and softens) real loss.
    @discardableResult
    public static func renderResampled(
        chunks: [AudioChunk],
        into out: inout [Float],
        coverage: inout [Bool],
        frames: Int,
        channels: Int,
        sampleRate: Double,
        windowStartMasterNs: UInt64,
        startOffsetFrames: Double,
        ratio: Double,
        gridScratch: inout [Float],
        gridCoverage: inout [Bool]
    ) -> RenderStats {
        precondition(out.count >= frames * channels)
        if coverage.count != frames { coverage = [Bool](repeating: false, count: frames) }
        var stats = RenderStats()
        guard frames > 0 else { return stats }

        // How many integer master frames the interpolation reaches into: from
        // floor(startOffsetFrames) up to the last source index needed, +1 for
        // the right interpolation neighbour, +1 slack.
        let lastSrc = startOffsetFrames + Double(frames - 1) * ratio
        let gridLen = max(1, Int(lastSrc.rounded(.up)) + 2)
        if gridScratch.count < gridLen * channels {
            gridScratch = [Float](repeating: 0, count: gridLen * channels)
        }
        if gridCoverage.count < gridLen { gridCoverage = [Bool](repeating: false, count: gridLen) }

        // Gather the master content onto the integer grid (bit-exact, reuses the
        // tested placement logic), then interpolate down to the DAC grid.
        render(chunks: chunks, into: &gridScratch, frames: gridLen, channels: channels,
               sampleRate: sampleRate, windowStartMasterNs: windowStartMasterNs,
               coverage: &gridCoverage)

        out.withUnsafeMutableBufferPointer { dst in
            gridScratch.withUnsafeBufferPointer { grid in
                gridCoverage.withUnsafeBufferPointer { gcov in
                    var filled = 0
                    for f in 0..<frames {
                        let src = startOffsetFrames + Double(f) * ratio
                        let i = Int(src.rounded(.down))
                        let frac = Float(src - Double(i))
                        let i1 = min(i + 1, gridLen - 1)
                        // Need both bracketing frames to interpolate; but when we
                        // land exactly on a grid frame (frac == 0) only the left
                        // one is read, so don't demand the right neighbour — keeps
                        // coverage exact in the bit-exact (ratio == 1) case.
                        let covered = i >= 0 && i < gridLen && gcov[i] && (frac == 0 || gcov[i1])
                        if covered { filled += 1 }
                        coverage[f] = covered
                        let aBase = i * channels
                        let bBase = i1 * channels
                        let oBase = f * channels
                        for ch in 0..<channels {
                            let a = grid[aBase + ch]
                            let b = grid[bBase + ch]
                            dst[oBase + ch] = a + (b - a) * frac
                        }
                    }
                    stats.framesFilled = filled
                }
            }
        }
        stats.framesSilent = frames - stats.framesFilled
        return stats
    }

    private static func unionLength(of intervals: [(start: Int, end: Int)], clampedTo limit: Int) -> Int {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.start < $1.start }
        var total = 0
        var curStart = sorted[0].start
        var curEnd = sorted[0].end
        for iv in sorted.dropFirst() {
            if iv.start <= curEnd {
                curEnd = max(curEnd, iv.end)
            } else {
                total += min(curEnd, limit) - max(curStart, 0)
                curStart = iv.start
                curEnd = iv.end
            }
        }
        total += min(curEnd, limit) - max(curStart, 0)
        return max(0, min(total, limit))
    }
}
