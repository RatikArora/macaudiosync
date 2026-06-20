import Testing
import Foundation
@testable import SyncCore

@Suite struct ClockSynchronizerTests {

    @Test func notSynchronizedBeforeMinimumSamples() {
        let sync = ClockSynchronizer(windowSize: 64, minSamplesToSync: 5)
        var clocks = SimClocks()
        for _ in 0..<4 {
            clocks.runExchange(sync: sync, forwardDelayNs: 200_000, returnDelayNs: 200_000)
        }
        #expect(!sync.isSynchronized, "must not trust fewer than 5 probes")
        clocks.runExchange(sync: sync, forwardDelayNs: 200_000, returnDelayNs: 200_000)
        #expect(sync.isSynchronized)
    }

    @Test func exactOffsetWithSymmetricDelay() throws {
        // With perfectly symmetric delay the math is exact: the estimate must
        // land within rounding error of the true offset, despite the two
        // clocks having epochs ~554,777 seconds apart.
        let sync = ClockSynchronizer()
        var clocks = SimClocks() // client epoch far from master epoch
        for _ in 0..<10 {
            clocks.runExchange(sync: sync, forwardDelayNs: 300_000, returnDelayNs: 300_000)
            clocks.advance(ns: 250_000_000) // 250 ms between probes
        }
        let estimate = try #require(sync.offsetNs)
        let truth = clocks.trueOffsetNs
        #expect(abs(estimate - truth) < 5_000, "symmetric delay should recover offset to <5µs, got \(estimate - truth)ns error")
    }

    @Test func negativeOffsetRecovered() throws {
        // Master clock far ahead of the client clock.
        let sync = ClockSynchronizer()
        var clocks = SimClocks(masterEpochNs: 999_888_777_666_555, clientEpochNs: 5_000_000_000)
        for _ in 0..<10 {
            clocks.runExchange(sync: sync, forwardDelayNs: 250_000, returnDelayNs: 250_000)
            clocks.advance(ns: 250_000_000)
        }
        let estimate = try #require(sync.offsetNs)
        #expect(estimate > 0) // master is way ahead here
        #expect(abs(estimate - clocks.trueOffsetNs) < 5_000)
    }

    @Test func convergesUnderAsymmetricNetworkJitter() throws {
        // Realistic Wi-Fi: base delay 200µs plus bursty queueing jitter of up
        // to 4ms, independently per direction. A naive single-sample
        // estimator would be off by milliseconds; the min-RTT + median filter
        // must stay under 300µs.
        let sync = ClockSynchronizer()
        var clocks = SimClocks()
        var rng = SeededRandom(seed: 1234)
        for _ in 0..<200 {
            let forward = 200_000 + UInt64(rng.uniform(0, 4_000_000))
            let back = 200_000 + UInt64(rng.uniform(0, 4_000_000))
            clocks.runExchange(sync: sync, forwardDelayNs: forward, returnDelayNs: back)
            clocks.advance(ns: 250_000_000)
        }
        let error = abs(try #require(sync.offsetNs) - clocks.trueOffsetNs)
        #expect(error < 300_000, "offset error \(Double(error) / 1e6)ms exceeds 0.3ms budget under 4ms jitter")
    }

    @Test func tracksClockDriftOverTime() throws {
        // 8 ppm frequency skew between the machines. After 10 simulated
        // minutes the raw clocks have slid ~4.8ms apart; the sliding window
        // must keep tracking the *current* offset, not the average of stale
        // history.
        let sync = ClockSynchronizer()
        var clocks = SimClocks(driftPpm: 8)
        var rng = SeededRandom(seed: 99)
        for _ in 0..<(10 * 60 * 4) { // 4 probes/s for 10 minutes
            let forward = 200_000 + UInt64(rng.uniform(0, 1_000_000))
            let back = 200_000 + UInt64(rng.uniform(0, 1_000_000))
            clocks.runExchange(sync: sync, forwardDelayNs: forward, returnDelayNs: back)
            clocks.advance(ns: 250_000_000)
        }
        let error = abs(try #require(sync.offsetNs) - clocks.trueOffsetNs)
        #expect(error < 500_000, "drift-tracking error \(Double(error) / 1e6)ms exceeds 0.5ms after 10 min at 8ppm")
    }

    @Test func rejectsNonsensicalExchanges() {
        let sync = ClockSynchronizer()
        // Reply "arrives" before the request was sent.
        #expect(sync.addExchange(clientSendNs: 1_000_000, serverRecvNs: 5, serverSendNs: 6, clientRecvNs: 999) == nil)
        // Server hold longer than total elapsed time.
        #expect(sync.addExchange(clientSendNs: 1_000, serverRecvNs: 2_000, serverSendNs: 9_000, clientRecvNs: 1_500) == nil)
        #expect(sync.sampleCount == 0)
    }

    @Test func masterAndClientConversionsAreInverse() throws {
        let sync = ClockSynchronizer()
        var clocks = SimClocks()
        for _ in 0..<10 {
            clocks.runExchange(sync: sync, forwardDelayNs: 200_000, returnDelayNs: 200_000)
            clocks.advance(ns: 250_000_000)
        }
        let local: UInt64 = clocks.clientNowNs
        let master = try #require(sync.masterNs(forClientNs: local))
        let backToLocal = try #require(sync.clientNs(forMasterNs: master))
        #expect(backToLocal == local)
    }

    @Test func reBaselinesAfterAClockStepFromSleep() throws {
        // Converge normally.
        let sync = ClockSynchronizer(windowSize: 64, minSamplesToSync: 5)
        var clocks = SimClocks()
        for _ in 0..<12 {
            clocks.runExchange(sync: sync, forwardDelayNs: 250_000, returnDelayNs: 250_000)
            clocks.advance(ns: 250_000_000)
        }
        let before = try #require(sync.offsetNs)
        #expect(abs(before - clocks.trueOffsetNs) < 5_000)

        // The client Mac sleeps ~5 s: CLOCK_UPTIME_RAW pauses, so afterward the
        // client clock reads 5 s behind and the master-minus-client offset
        // jumps by ~5 s. Model it as a new clock baseline continuing at the
        // current master time.
        let sleepNs: UInt64 = 5_000_000_000
        var stepped = SimClocks(masterEpochNs: clocks.masterEpochNs,
                                clientEpochNs: clocks.clientEpochNs &- sleepNs)
        stepped.masterNowNs = clocks.masterNowNs

        for _ in 0..<6 {
            stepped.runExchange(sync: sync, forwardDelayNs: 250_000, returnDelayNs: 250_000)
            stepped.advance(ns: 250_000_000)
        }
        let after = try #require(sync.offsetNs)
        // Must track the NEW clock, not the pre-sleep average of the window.
        #expect(abs(after - stepped.trueOffsetNs) < 50_000,
                "after a clock step the offset must re-baseline, not blend across the window")
        #expect(abs(after - before) > Int64(sleepNs / 2),
                "the estimate must actually jump by ~the sleep duration")
    }

    @Test func windowSlidesAndForgetsOldSamples() {
        let sync = ClockSynchronizer(windowSize: 16, minSamplesToSync: 5)
        var clocks = SimClocks()
        for _ in 0..<100 {
            clocks.runExchange(sync: sync, forwardDelayNs: 200_000, returnDelayNs: 200_000)
            clocks.advance(ns: 250_000_000)
        }
        #expect(sync.sampleCount == 16)
    }
}

@Suite struct DriftEstimatorTests {

    @Test func estimatesKnownDrift() throws {
        // Feed offsets that grow at exactly 5 ppm of client time plus ±50µs
        // of measurement noise; the regression must recover ~5 ppm.
        let estimator = DriftEstimator(windowSize: 300)
        var rng = SeededRandom(seed: 2024)
        let driftPpm = 5.0
        var clientNs: UInt64 = 1_000_000_000
        for _ in 0..<240 { // one probe per 250ms for a minute
            let trueOffset = Double(clientNs) * driftPpm / 1e6
            let noise = rng.uniform(-50_000, 50_000)
            estimator.add(clientNs: clientNs, offsetNs: Int64(trueOffset + noise))
            clientNs += 250_000_000
        }
        let estimate = try #require(estimator.driftPpm)
        #expect(abs(estimate - driftPpm) <= 0.5, "estimated \(estimate) ppm, expected ~\(driftPpm) ppm")
    }

    @Test func noDriftEstimatesNearZero() throws {
        let estimator = DriftEstimator()
        var rng = SeededRandom(seed: 11)
        var clientNs: UInt64 = 0
        for _ in 0..<240 {
            estimator.add(clientNs: clientNs, offsetNs: Int64(rng.uniform(-30_000, 30_000)))
            clientNs += 250_000_000
        }
        let estimate = try #require(estimator.driftPpm)
        #expect(abs(estimate) <= 0.3)
    }

    @Test func requiresMinimumPoints() {
        let estimator = DriftEstimator()
        for i in 0..<9 {
            estimator.add(clientNs: UInt64(i) * 1_000_000, offsetNs: 0)
        }
        #expect(estimator.driftPpm == nil)
    }
}
