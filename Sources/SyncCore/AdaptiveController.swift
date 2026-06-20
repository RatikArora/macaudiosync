import Foundation

/// A receiver's once-a-second health report, sent upstream to the sender so it
/// can tune the stream to the worst-case receiver. Client → server only.
public struct Feedback: Equatable {
    /// Minimum arrival headroom this interval (ms). Negative = audio landed
    /// after its deadline.
    public var marginMinMs: Int32
    /// Chunks that arrived too late to play, this interval.
    public var lateCount: UInt32
    /// Fraction of frames actually filled this interval, in per-mille (1000 =
    /// 100% fill).
    public var fillPermille: UInt32
    /// Audio currently queued ahead (ms).
    public var bufferedMs: UInt32
    /// Best clock-probe round-trip (ms).
    public var rttMs: UInt32

    public init(marginMinMs: Int32, lateCount: UInt32, fillPermille: UInt32, bufferedMs: UInt32, rttMs: UInt32) {
        self.marginMinMs = marginMinMs
        self.lateCount = lateCount
        self.fillPermille = fillPermille
        self.bufferedMs = bufferedMs
        self.rttMs = rttMs
    }
}

/// Worst-case network health aggregated across all receivers for one control
/// tick.
public struct ControllerInput: Equatable {
    public let minMarginMs: Int
    public let lateOccurred: Bool
    public let minFillPermille: Int

    public init(minMarginMs: Int, lateOccurred: Bool, minFillPermille: Int) {
        self.minMarginMs = minMarginMs
        self.lateOccurred = lateOccurred
        self.minFillPermille = minFillPermille
    }

    /// Reduce a set of receiver reports to the worst case on each axis. Empty
    /// input ⇒ "perfectly healthy" so the controller relaxes toward the floor.
    public static func worstCase(_ reports: [Feedback]) -> ControllerInput {
        guard !reports.isEmpty else {
            return ControllerInput(minMarginMs: Int.max, lateOccurred: false, minFillPermille: 1000)
        }
        return ControllerInput(
            minMarginMs: reports.map { Int($0.marginMinMs) }.min() ?? Int.max,
            lateOccurred: reports.contains { $0.lateCount > 0 },
            minFillPermille: reports.map { Int($0.fillPermille) }.min() ?? 1000
        )
    }
}

/// Decides the playback buffer (latency) from live receiver feedback. It is
/// deliberately conservative and one-dimensional: it only moves the buffer —
/// a perceptually transparent knob — so adaptation NEVER changes audio
/// quality. (Bitrate/codec adaptation is reserved for a future perceptual
/// codec; PCM-Int16 is already at the transparent sweet spot.)
///
/// Control law (one `step` per second):
/// - DISTRESS (late, fill < 98.5%, or margin < 12 ms): raise the buffer fast.
/// - TIGHT (margin < 30 ms): nudge the buffer up.
/// - HEALTHY: lower the buffer one notch, but only after a sustained healthy
///   streak — quick to protect, slow to relax, so it can't oscillate.
///
/// The sender applies the returned buffer by SLEWING toward it a few µs per
/// packet (below the receiver's timestamp-jitter threshold), so even the
/// transition is gap-free and inaudible.
public final class AdaptiveController {
    public let floorMs: Int
    public let ceilMs: Int
    public private(set) var bufferMs: Int
    /// Consecutive healthy ticks; relaxation requires `relaxAfter` of them.
    private var healthyStreak = 0

    // Tunables (ms / ticks). Asymmetric on purpose.
    private let raiseDistressStep = 30
    private let raiseTightStep = 10
    private let relaxStep = 10
    private let relaxAfter = 5
    private let distressFillPermille = 985
    private let distressMarginMs = 12
    private let tightMarginMs = 30

    public init(initialBufferMs: Int, floorMs: Int = 40, ceilMs: Int = 500) {
        self.floorMs = floorMs
        self.ceilMs = ceilMs
        self.bufferMs = min(max(initialBufferMs, floorMs), ceilMs)
    }

    /// Advance one control tick and return the new target buffer (ms).
    ///
    /// `currentBufferMs` is the buffer the receivers are actually experiencing
    /// (the sender's slew-limited *effective* buffer). Stepping relative to it
    /// — rather than an internal accumulator — keeps the target from running
    /// away from the (deliberately slow) slew, so the feedback loop stays
    /// closed on what listeners actually hear.
    @discardableResult
    public func step(currentBufferMs: Int, _ input: ControllerInput) -> Int {
        var b = min(max(currentBufferMs, floorMs), ceilMs)
        let distress = input.lateOccurred
            || input.minFillPermille < distressFillPermille
            || input.minMarginMs < distressMarginMs
        if distress {
            healthyStreak = 0
            b = min(ceilMs, b + raiseDistressStep)
        } else if input.minMarginMs < tightMarginMs {
            healthyStreak = 0
            b = min(ceilMs, b + raiseTightStep)
        } else {
            healthyStreak += 1
            if healthyStreak >= relaxAfter {
                healthyStreak = 0
                b = max(floorMs, b - relaxStep)
            }
        }
        bufferMs = b
        return b
    }
}
