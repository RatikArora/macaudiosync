import Foundation

/// Tracks how early audio chunks arrive relative to their scheduled play
/// time — the receiver's real safety headroom.
///
/// `margin = playAtMasterNs - masterNow` at the moment a chunk is inserted.
/// The *minimum* margin over a reporting interval tells you how close the
/// stream came to missing its deadline: if the minimum stays comfortably
/// positive (say > 40 ms), the sender's `--buffer-ms` can be lowered by
/// roughly that amount; if it dips near zero (or `late` counts appear),
/// the buffer is too small for this network.
public final class MarginTracker {
    private let lock = NSLock()
    private var minNs: Int64?
    private var maxNs: Int64?
    private var count = 0

    public init() {}

    public func add(marginNs: Int64) {
        lock.lock()
        minNs = Swift.min(minNs ?? marginNs, marginNs)
        maxNs = Swift.max(maxNs ?? marginNs, marginNs)
        count += 1
        lock.unlock()
    }

    /// Returns (min, max, count) since the last drain, and resets.
    public func drain() -> (minNs: Int64, maxNs: Int64, count: Int)? {
        lock.lock()
        defer {
            minNs = nil
            maxNs = nil
            count = 0
            lock.unlock()
        }
        guard let lo = minNs, let hi = maxNs else { return nil }
        return (lo, hi, count)
    }
}
