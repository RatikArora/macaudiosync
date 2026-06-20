import Foundation

/// NTP-style clock synchronization between a receiver (client) and the
/// sender's master clock.
///
/// For each probe exchange we have four timestamps:
///   t1  client send     (client clock)
///   t2  server receive  (master clock)
///   t3  server send     (master clock)
///   t4  client receive  (client clock)
///
/// Assuming symmetric network delay, the offset of the master clock relative
/// to the client clock is:
///   offset = ((t2 - t1) + (t3 - t4)) / 2        (master = client + offset)
/// and the round-trip network time is:
///   rtt = (t4 - t1) - (t3 - t2)
///
/// Real networks have asymmetric jitter, so a single exchange can be off by
/// milliseconds. We keep a sliding window of samples and estimate the offset
/// as the median of the samples with the lowest RTT — low-RTT exchanges are
/// the ones least contaminated by queueing delay, and the median rejects the
/// remaining outliers. This is the same trick Snapcast/PTP-style systems use
/// and comfortably reaches sub-millisecond accuracy on a LAN.
public final class ClockSynchronizer {
    public struct Sample: Equatable {
        /// Client-clock time of the exchange (t4), used to age out samples.
        public let clientNs: UInt64
        /// Estimated master-minus-client offset from this single exchange.
        public let offsetNs: Int64
        /// Network round-trip time for this exchange.
        public let rttNs: UInt64
    }

    private var samples: [Sample] = []
    private let windowSize: Int
    private let minSamplesToSync: Int
    private let lock = NSLock()

    /// Cached estimate so the audio render thread can read it cheaply.
    private var cachedOffsetNs: Int64?

    /// - Parameters:
    ///   - windowSize: number of recent exchanges to keep.
    ///   - minSamplesToSync: refuse to report an offset until this many
    ///     exchanges have been observed (avoids trusting one noisy probe).
    public init(windowSize: Int = 64, minSamplesToSync: Int = 5) {
        precondition(windowSize >= minSamplesToSync)
        self.windowSize = windowSize
        self.minSamplesToSync = minSamplesToSync
    }

    /// Record one completed probe exchange.
    /// Returns the sample, or nil if the exchange was rejected as nonsensical
    /// (e.g. reply arrived "before" the request was sent).
    @discardableResult
    public func addExchange(
        clientSendNs t1: UInt64,
        serverRecvNs t2: UInt64,
        serverSendNs t3: UInt64,
        clientRecvNs t4: UInt64
    ) -> Sample? {
        guard t4 >= t1, t3 >= t2 else { return nil }
        let elapsed = t4 - t1
        let serverHold = t3 - t2
        guard elapsed >= serverHold else { return nil }
        let rtt = elapsed - serverHold

        // The two clocks have unrelated epochs (each Mac's boot time), so the
        // cross-clock differences can be huge in either direction; Int64 still
        // covers ±292 years of nanoseconds, which is plenty.
        let d1 = Int64(bitPattern: t2 &- t1) // forward leg + offset
        let d2 = Int64(bitPattern: t3 &- t4) // offset - return leg
        let offset = (d1 + d2) / 2

        let sample = Sample(clientNs: t4, offsetNs: offset, rttNs: rtt)
        lock.lock()
        // Clock-step detection. CLOCK_UPTIME_RAW pauses while a Mac sleeps, so
        // if either side sleeps mid-stream the master-minus-client offset jumps
        // by the sleep duration — far beyond any network jitter. Averaging the
        // old and new offsets across that discontinuity would garble audio for
        // the whole window (~16 s at 4 probes/s). When a fresh sample lands a
        // long way from the established offset, treat it as a step: drop the
        // stale samples and re-baseline on the new clock (a brief, clean
        // re-sync instead of seconds of wrong timing).
        if let cached = cachedOffsetNs, abs(offset - cached) > Self.stepThresholdNs {
            samples.removeAll(keepingCapacity: true)
            cachedOffsetNs = nil
        }
        samples.append(sample)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
        cachedOffsetNs = computeOffsetLocked()
        lock.unlock()
        return sample
    }

    /// An offset jump larger than this (200 ms) can't be network jitter — it's
    /// a clock step (sleep/wake), so the sample window is flushed.
    private static let stepThresholdNs: Int64 = 200_000_000

    /// Best current estimate of (master - client) in nanoseconds, or nil if
    /// not yet synchronized. Safe to call from the audio render thread.
    public var offsetNs: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return cachedOffsetNs
    }

    public var isSynchronized: Bool { offsetNs != nil }

    /// Lowest RTT in the current window (diagnostics).
    public var bestRttNs: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return samples.map(\.rttNs).min()
    }

    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// Convert a client-clock timestamp to master-clock time.
    public func masterNs(forClientNs clientNs: UInt64) -> UInt64? {
        guard let off = offsetNs else { return nil }
        let m = Int64(bitPattern: clientNs) &+ off
        return m >= 0 ? UInt64(m) : 0
    }

    /// Convert a master-clock timestamp to client-clock time.
    public func clientNs(forMasterNs masterNs: UInt64) -> UInt64? {
        guard let off = offsetNs else { return nil }
        let c = Int64(bitPattern: masterNs) &- off
        return c >= 0 ? UInt64(c) : 0
    }

    // MARK: - Private

    private func computeOffsetLocked() -> Int64? {
        guard samples.count >= minSamplesToSync else { return nil }
        guard let minRtt = samples.map(\.rttNs).min() else { return nil }
        // Accept samples within 50% + 50µs of the best RTT seen; their delay
        // is necessarily close to symmetric-minimum on both legs.
        let threshold = minRtt + minRtt / 2 + 50_000
        let good = samples.filter { $0.rttNs <= threshold }
        guard !good.isEmpty else { return nil }
        let sorted = good.map(\.offsetNs).sorted()
        return sorted[sorted.count / 2]
    }
}
