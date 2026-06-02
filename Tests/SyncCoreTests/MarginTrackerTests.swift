import Testing
@testable import SyncCore

@Suite struct MarginTrackerTests {

    @Test func tracksMinAndMaxSinceLastDrain() {
        let tracker = MarginTracker()
        tracker.add(marginNs: 50_000_000)
        tracker.add(marginNs: 12_000_000)
        tracker.add(marginNs: 80_000_000)
        let first = tracker.drain()
        #expect(first?.minNs == 12_000_000)
        #expect(first?.maxNs == 80_000_000)
        #expect(first?.count == 3)
        // Drain resets: a new interval starts clean.
        #expect(tracker.drain() == nil)
        tracker.add(marginNs: -3_000_000) // late arrival = negative headroom
        let second = tracker.drain()
        #expect(second?.minNs == -3_000_000)
        #expect(second?.maxNs == -3_000_000)
        #expect(second?.count == 1)
    }

    @Test func emptyTrackerDrainsNil() {
        #expect(MarginTracker().drain() == nil)
    }
}
