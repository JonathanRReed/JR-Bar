import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The island's open/close/interrupt behaviour as a state machine on a
/// hand-cranked clock: a pointer's whole visit is stepped, never slept,
/// so rapid in-and-out, a leave-and-return and a reversal mid-grow are
/// all proved to settle, and never to leave the island stuck open, stuck
/// swollen or holding a timer.
@Suite("Notch state machine")
@MainActor
struct NotchStateMachineTests {
    private func makeToy() -> (toy: NotchToy, store: ToysStore, timers: ManualTimers) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        toy.menuBarHidden = { false }
        toy.reduceMotion = { false }
        // The real pointer stays out of it: a hand resting near the top of
        // the screen would otherwise hold the card open under the test.
        toy.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        let timers = ManualTimers()
        toy.hoverTimer = { delay, work in timers.arm(delay, work) }
        return (toy, store, timers)
    }

    @Test("a resting pointer leans first, opens second, and folds on leaving")
    func visit() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(toy.islandHoverPeek && !toy.islandExpanded, "the swell lands on the same turn: the first frame answers")
        #expect(!toy.islandExpanded)
        timers.advance(by: NotchSettings.defaultHoverOpenDelay)
        #expect(toy.islandExpanded, "then the card")
        #expect(toy.stage.cardStaged && toy.stage.openness == 1, "with no window to carry it the card is simply there")
        toy.setHovered(false)
        #expect(toy.islandExpanded, "a leave is debounced")
        timers.advance(by: NotchMotion.collapseDelay + 0.001)
        #expect(!toy.islandExpanded)
        #expect(!toy.stage.cardStaged && toy.stage.openness == 0)
        #expect(!toy.islandHoverPeek)
    }

    @Test("a pointer thrashing in and out ends wherever it stopped, with no timer left over")
    func thrash() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        // A fixed, uneven rhythm: dwells from 10 ms to 230 ms.
        let dwells: [Double] = [0.01, 0.03, 0.05, 0.02, 0.09, 0.04, 0.23, 0.06, 0.01, 0.11, 0.17, 0.02, 0.07, 0.19, 0.03]
        for round in 0..<6 {
            for (index, dwell) in dwells.enumerated() {
                toy.setHovered((index + round) % 2 == 0)
                timers.advance(by: dwell)
            }
        }
        toy.setHovered(false)
        timers.advance(by: 1)
        #expect(!toy.islandExpanded && !toy.islandHoverPeek, "a pointer that is gone leaves the island at rest")
        #expect(!toy.stage.cardStaged)
        #expect(timers.live == 0, "nothing armed outlives the visit")
        toy.setHovered(true)
        timers.advance(by: 1)
        #expect(toy.islandExpanded, "and the next visit still opens it")
        #expect(timers.live == 0)
    }

    @Test("leaving and returning inside the debounce keeps the card where it is")
    func leaveAndReturn() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        timers.advance(by: 0.2)
        #expect(toy.islandExpanded)
        for _ in 0..<5 {
            toy.setHovered(false)
            timers.advance(by: NotchMotion.collapseDelay * 0.6)
            toy.setHovered(true)
            timers.advance(by: 0.05)
        }
        timers.advance(by: 1)
        #expect(toy.islandExpanded, "the pointer never really left")
        toy.setHovered(false)
        timers.advance(by: 1)
        #expect(!toy.islandExpanded)
    }

    @Test("a pointer that came and went inside the swell's delay never moves the island")
    func quickPassNeverSwells() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        timers.advance(by: NotchMotion.peekDelay * 0.5)
        toy.setHovered(false)
        timers.advance(by: 1)
        #expect(!toy.islandHoverPeek && !toy.islandExpanded)
        #expect(timers.live == 0)
    }

    @Test("a pointer from the menu bar waits for the 300 ms floor")
    func fromTheBar() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.bandHover(true, fromBar: true)
        timers.advance(by: NotchMotion.barArrivalFloor - 0.001)
        #expect(!toy.islandExpanded)
        timers.advance(by: 0.002)
        #expect(toy.islandExpanded)
    }

    @Test("Reduce Motion keeps the island still until the card, which just appears")
    func reduceMotion() {
        let (toy, store, timers) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.reduceMotion = { true }
        toy.setHovered(true)
        timers.advance(by: 0.1)
        #expect(!toy.islandHoverPeek, "no swell under Reduce Motion")
        timers.advance(by: 0.1)
        #expect(toy.islandExpanded)
        #expect(toy.stage.openness == 1, "no travel, so no reveal to wait for")
    }

    @Test("a fold that cannot animate never strands the card on stage")
    func foldWithoutAWindowSettles() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        #expect(toy.stage.cardStaged)
        toy.collapseFromBand()
        #expect(!toy.stage.cardStaged && toy.stage.openness == 0)
        #expect(!toy.islandExpanded)
    }
}
