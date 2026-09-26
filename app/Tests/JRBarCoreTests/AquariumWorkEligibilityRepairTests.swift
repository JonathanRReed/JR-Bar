import Testing
@testable import JRBarCore

@Suite("Aquarium work requires a live interval")
struct AquariumWorkEligibilityRepairTests {
    @Test func disconnectedWorkingSnapshotEarnsNoWorkTime() {
        var clock = AquariumWorkClock()
        clock.reset(connected: true, at: 0)
        #expect(clock.consume(connected: false, at: 20, maximum: 20) == 0)
        #expect(clock.consume(connected: false, at: 40, maximum: 20) == 0)
    }

    @Test func unchangedConnectedSnapshotRemainsEligible() {
        var clock = AquariumWorkClock()
        clock.reset(connected: true, at: 0)
        #expect(clock.consume(connected: true, at: 20, maximum: 20) == 20)
        #expect(clock.consume(connected: true, at: 40, maximum: 20) == 20)
    }

    @Test func reconnectDoesNotBackfillDisconnectedTime() {
        var clock = AquariumWorkClock()
        clock.reset(connected: true, at: 0)
        clock.reset() // synchronously on the connection transition
        #expect(clock.consume(connected: true, at: 600, maximum: 20) == 0)
        #expect(clock.consume(connected: true, at: 620, maximum: 20) == 20)
        clock.reset(connected: true, at: 700)
        #expect(clock.consume(connected: true, at: 705, maximum: 20) == 5)
    }

    @Test func duplicateAndDelayedAndInvalidTicksDoNotMintExtraTime() {
        var clock = AquariumWorkClock()
        clock.reset(connected: true, at: 0)
        #expect(clock.consume(connected: true, at: 500, maximum: 20) == 20)
        #expect(clock.consume(connected: true, at: 500, maximum: 20) == 0)
        #expect(clock.consume(connected: true, at: .nan, maximum: 20) == 0)
        #expect(clock.consume(connected: true, at: 520, maximum: 20) == 0)
        #expect(clock.consume(connected: true, at: 540, maximum: -1) == 0)
    }
}
