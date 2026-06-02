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
        precondition(out.count >= frames * channels)
        for i in 0..<(frames * channels) { out[i] = 0 }

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

        stats.framesFilled = unionLength(of: filledIntervals, clampedTo: frames)
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
