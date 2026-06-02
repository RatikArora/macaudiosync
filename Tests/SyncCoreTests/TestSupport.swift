import Foundation
@testable import SyncCore

/// Deterministic PRNG (SplitMix64) so test runs are reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform Double in [lo, hi).
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + uniform() * (hi - lo)
    }

    /// Uniform Int in [lo, hi].
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        lo + Int(next() % UInt64(hi - lo + 1))
    }
}

/// A pair of simulated clocks with independent epochs and a frequency skew,
/// modeling two Macs whose crystals don't run at exactly the same rate.
///
/// Master time is the simulation's ground truth; the client clock reads
/// `clientEpoch + masterElapsed * (1 + driftPpm/1e6)`.
struct SimClocks {
    let masterEpochNs: UInt64
    let clientEpochNs: UInt64
    let driftPpm: Double

    /// Current master "now" — advanced manually by tests.
    var masterNowNs: UInt64

    init(masterEpochNs: UInt64 = 1_000_000_000_000, clientEpochNs: UInt64 = 555_777_000_000_000, driftPpm: Double = 0) {
        self.masterEpochNs = masterEpochNs
        self.clientEpochNs = clientEpochNs
        self.driftPpm = driftPpm
        self.masterNowNs = masterEpochNs
    }

    mutating func advance(ns: UInt64) { masterNowNs += ns }

    /// Client-clock reading at a given master time.
    func clientNs(atMasterNs masterNs: UInt64) -> UInt64 {
        let elapsed = Double(masterNs - masterEpochNs)
        return clientEpochNs + UInt64(elapsed * (1.0 + driftPpm / 1e6))
    }

    var clientNowNs: UInt64 { clientNs(atMasterNs: masterNowNs) }

    /// Ground-truth offset (master - client) at the current master time.
    var trueOffsetNs: Int64 {
        Int64(bitPattern: masterNowNs &- clientNowNs)
    }

    /// Run one clock-probe exchange through the synchronizer with the given
    /// one-way delays, advancing the simulation clock past the exchange.
    mutating func runExchange(
        sync: ClockSynchronizer,
        forwardDelayNs: UInt64,
        returnDelayNs: UInt64,
        serverHoldNs: UInt64 = 20_000
    ) {
        let t1 = clientNowNs
        advance(ns: forwardDelayNs)
        let t2 = masterNowNs
        advance(ns: serverHoldNs)
        let t3 = masterNowNs
        advance(ns: returnDelayNs)
        let t4 = clientNowNs
        sync.addExchange(clientSendNs: t1, serverRecvNs: t2, serverSendNs: t3, clientRecvNs: t4)
    }
}
