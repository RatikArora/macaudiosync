import Testing
@testable import SyncCore

@Suite struct AdaptiveControllerTests {

    private func healthy() -> ControllerInput {
        ControllerInput(minMarginMs: 100, lateOccurred: false, minFillPermille: 1000)
    }
    private func distress() -> ControllerInput {
        ControllerInput(minMarginMs: 5, lateOccurred: true, minFillPermille: 800)
    }

    @Test func distressRaisesBuffer() {
        let c = AdaptiveController(initialBufferMs: 150)
        #expect(c.step(currentBufferMs: 150, distress()) == 180)
    }

    @Test func sustainedHealthLowersOnlyAfterStreak() {
        let c = AdaptiveController(initialBufferMs: 200)
        var b = 200
        // Hysteresis: the first four healthy ticks must NOT lower the buffer.
        for _ in 0..<4 { b = c.step(currentBufferMs: b, healthy()) }
        #expect(b == 200)
        // The fifth healthy tick relaxes by one notch.
        b = c.step(currentBufferMs: b, healthy())
        #expect(b == 190)
    }

    @Test func clampsToFloorAndCeiling() {
        let c = AdaptiveController(initialBufferMs: 100, floorMs: 40, ceilMs: 200)
        var b = 100
        for _ in 0..<50 { b = c.step(currentBufferMs: b, distress()) }
        #expect(b == 200) // never above ceiling
        for _ in 0..<300 { b = c.step(currentBufferMs: b, healthy()) }
        #expect(b == 40)  // never below floor
    }

    @Test func recoversAfterDistressClears() {
        let c = AdaptiveController(initialBufferMs: 100)
        let raised = c.step(currentBufferMs: 100, distress())
        #expect(raised == 130)
        var b = raised
        for _ in 0..<5 { b = c.step(currentBufferMs: b, healthy()) }
        #expect(b < raised)
    }

    @Test func tightMarginNudgesUpGently() {
        let c = AdaptiveController(initialBufferMs: 100)
        // Margin under 30 ms but no late/low-fill = TIGHT → small +10 raise.
        let out = c.step(currentBufferMs: 100, ControllerInput(minMarginMs: 20, lateOccurred: false, minFillPermille: 1000))
        #expect(out == 110)
    }

    @Test func initialBufferClampedIntoRange() {
        #expect(AdaptiveController(initialBufferMs: 9999, floorMs: 40, ceilMs: 500).bufferMs == 500)
        #expect(AdaptiveController(initialBufferMs: 1, floorMs: 40, ceilMs: 500).bufferMs == 40)
    }

    @Test func worstCaseAggregatesAcrossReceivers() {
        let good = Feedback(marginMinMs: 100, lateCount: 0, fillPermille: 1000, bufferedMs: 200, rttMs: 1)
        let bad = Feedback(marginMinMs: 8, lateCount: 3, fillPermille: 900, bufferedMs: 50, rttMs: 5)
        let input = ControllerInput.worstCase([good, bad])
        #expect(input.minMarginMs == 8)
        #expect(input.lateOccurred == true)
        #expect(input.minFillPermille == 900)
    }

    @Test func emptyFeedbackIsTreatedAsHealthy() {
        let input = ControllerInput.worstCase([])
        #expect(input.lateOccurred == false)
        #expect(input.minFillPermille == 1000)
    }
}
