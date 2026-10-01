import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A card grown by hover folds 0.18 s after the pointer leaves the island
/// window. The Custom timer's entry, a stack's grid and the new-reminder
/// field are popovers of their own that hang below the card, so reaching for
/// one is a leave, and the card folded out from under it. While a popover is
/// up the card holds; when the last one closes the leave check runs again.
/// The timers here are never waited on: the leave check is fired by hand.
@Suite("Card popover hold")
@MainActor
struct CardPopoverHoldTests {
    // MARK: The hold

    @Test("held while any popover is open, and told only when that changes")
    func holdCountsPopovers() {
        let hold = CardPopoverHold()
        var told: [Bool] = []
        hold.onChange = { told.append($0) }
        #expect(!hold.isHeld)
        hold.note("timerEntry", open: true)
        hold.note("timerEntry", open: true)
        #expect(hold.isHeld && told == [true], "a repeat of the same popover says nothing")
        hold.note("stack:a", open: true)
        #expect(told == [true], "a second popover does not change the card's state")
        hold.note("timerEntry", open: false)
        #expect(hold.isHeld && told == [true], "one is still up")
        hold.note("stack:a", open: false)
        #expect(!hold.isHeld && told == [true, false], "the last one released it")
        hold.note("stack:a", open: false)
        #expect(told == [true, false], "closing what was never open says nothing")
    }

    @Test("releaseAll lets go of everything at once, and only once")
    func releaseAllLetsGo() {
        let hold = CardPopoverHold()
        var told: [Bool] = []
        hold.onChange = { told.append($0) }
        hold.releaseAll()
        #expect(told.isEmpty, "nothing held, nothing to say")
        hold.note("a", open: true)
        hold.note("b", open: true)
        hold.releaseAll()
        #expect(!hold.isHeld && told == [true, false])
        hold.note("a", open: false)
        #expect(told == [true, false], "a late close of a released popover is not a second release")
    }

    // MARK: The island card

    private func makeToy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    /// The pointer left the island window and the leave check came due.
    private func pointerLeavesAndTheCheckFires(_ toy: NotchToy) {
        toy.setHovered(false)
        toy.collapseTimerFired()
    }

    @Test("a hover-grown card with no popover folds when the pointer leaves, as it always did")
    func foldsWithoutAPopover() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        toy.setHovered(true)
        #expect(toy.islandExpanded)
        pointerLeavesAndTheCheckFires(toy)
        #expect(!toy.islandExpanded)
    }

    @Test("a hover-grown card stays up under an open popover, and folds once it closes")
    func holdsUnderAPopover() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        toy.setHovered(true)
        // The Custom timer entry opens, and the pointer goes toward it.
        toy.cardModel.popoverHold.note("timerEntry", open: true)
        pointerLeavesAndTheCheckFires(toy)
        #expect(toy.islandExpanded, "the pointer is on its way to the popover, not away")
        // The popover closes with the pointer off the island: the leave
        // check is armed again, and it folds the card.
        toy.cardModel.popoverHold.note("timerEntry", open: false)
        #expect(toy.collapseWork != nil, "closing re-runs the leave check")
        toy.collapseTimerFired()
        #expect(!toy.islandExpanded)
    }

    @Test("a pointer that is back on the island when the popover closes folds nothing")
    func pointerBackOnTheIsland() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        toy.setHovered(true)
        toy.cardModel.popoverHold.note("reminder", open: true)
        toy.setHovered(false)
        toy.setHovered(true)
        toy.cardModel.popoverHold.note("reminder", open: false)
        #expect(toy.collapseWork == nil, "the pointer is over the card: no leave to check")
        #expect(toy.islandExpanded)
    }

    @Test("two popovers hold the card until both have closed")
    func twoPopovers() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        toy.setHovered(true)
        toy.cardModel.popoverHold.note("timerEntry", open: true)
        toy.cardModel.popoverHold.note("stack:a", open: true)
        toy.cardModel.popoverHold.note("timerEntry", open: false)
        pointerLeavesAndTheCheckFires(toy)
        #expect(toy.islandExpanded, "the grid is still up")
        toy.cardModel.popoverHold.note("stack:a", open: false)
        toy.collapseTimerFired()
        #expect(!toy.islandExpanded)
    }

    @Test("a card the person pinned with a click is not the hold's business")
    func pinnedCardIsUntouched() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: true)
        toy.cardModel.popoverHold.note("timerEntry", open: true)
        toy.cardModel.popoverHold.note("timerEntry", open: false)
        #expect(toy.collapseWork == nil, "a held card never waits on the leave check")
        pointerLeavesAndTheCheckFires(toy)
        #expect(toy.islandExpanded, "only Esc, a click away or a swipe lets it go")
    }

    @Test("folding the card by any other way clears the hold, so a stuck popover never wedges the next card")
    func foldingClearsTheHold() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expand(held: false)
        toy.cardModel.popoverHold.note("timerEntry", open: true)
        toy.collapseIsland()
        #expect(!toy.cardModel.popoverHold.isHeld)
        // The next hover-grown card folds normally.
        toy.expand(held: false)
        toy.setHovered(true)
        pointerLeavesAndTheCheckFires(toy)
        #expect(!toy.islandExpanded)
    }
}
