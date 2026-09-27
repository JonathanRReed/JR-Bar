import Foundation
import Testing
@testable import JRBarCore

@Suite("Keep Awake states are not lock guarantees")
struct KeepAwakeRepairTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [KeepAwakeReading.State.off, .agents(count: 2),
                      .lease(.indefinite), .lease(.agentsFinish)])
    func displayHelpDoesNotPromiseToBypassLockPolicy(state: KeepAwakeReading.State) {
        let help = KeepAwakeReading(state: state, display: true).chipHelp(now: now)
        #expect(!help.contains("will not lock"))
        #expect(!help.contains("no lock"))
        #expect(help.contains("idle display sleep"))
        #expect(help.contains("Manual locking and system security policies still apply"))
    }

    @Test func endingManualSessionDoesNotPromiseAllHoldsEnd() {
        let help = KeepAwakeReading(state: .lease(.until(now.addingTimeInterval(90))))
            .chipHelp(now: now)
        #expect(help.contains("end your manual session"))
        #expect(help.contains("Automatic agent holds and other apps"))
        #expect(!help.contains("click to allow sleep"))
    }

    @Test func pausedDemandAndAutomaticHoldKeepTheirDifferentAuthorities() {
        let automatic = KeepAwakeReading(state: .agents(count: 1))
        #expect(automatic.holding)
        #expect(!automatic.leaseInForce)
        let paused = KeepAwakeReading(state: .lease(.indefinite), suspended: "thermal")
        #expect(!paused.holding)
        #expect(paused.leaseInForce)
        #expect(paused.chipHelp(now: now).contains("Paused: too warm"))
        let grace = KeepAwakeReading(state: .agents(count: 0))
        #expect(grace.holding && !grace.leaseInForce)
    }
}
