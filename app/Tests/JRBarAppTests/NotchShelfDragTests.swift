import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A file dragged to the notch against the toy. The island's hosting
/// view hears the drag leave as soon as it crosses onto one of the
/// card's own drop targets (a session row, the tray catch-all), which
/// AppKit hands it to as destinations of their own. The summoned card
/// must stay up for that crossing and fold only when nothing in the
/// island has the drag.
@Suite("Notch shelf drag")
@MainActor
struct NotchShelfDragTests {
    private func makeToy() -> (NotchToy, ToysStore) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("a drag crossing from the notch onto a session row keeps the card up")
    func crossingOntoRowKeepsCard() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.shelfDragAtIsland()
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.page == .now, "the rows are the targets")

        // AppKit's order: the hosting view's exit, then the row's enter.
        toy.shelfDragLeftIsland()
        toy.cardModel.setDropHover("row:claude:s1", true)
        #expect(!toy.shelfDragLeavePending, "no fold waits under a drag heading for an agent")
        #expect(toy.islandExpanded, "the card stays under a drag heading for an agent")

        // Row to catch-all and back is still inside the island.
        toy.cardModel.setDropHover("row:claude:s1", false)
        toy.cardModel.setDropHover("card", true)
        #expect(!toy.shelfDragLeavePending)
        #expect(toy.islandExpanded)

        // Off the card's edge and away: nothing has the drag.
        toy.cardModel.setDropHover("card", false)
        #expect(toy.shelfDragLeavePending, "the fold waits out its grace")
        toy.fireShelfDragLeave()
        #expect(!toy.islandExpanded, "a drag carried away folds the card it summoned")
    }

    @Test("a drag that leaves the notch without reaching the card folds it")
    func leavingFolds() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.shelfDragAtIsland()
        toy.shelfDragLeftIsland()
        #expect(toy.shelfDragLeavePending)
        toy.fireShelfDragLeave()
        #expect(!toy.islandExpanded)
    }

    @Test("a drop on the card lands in the tray, turns to the shelf, and keeps the card")
    func dropOnCardKeepsCard() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.shelfDragAtIsland()
        toy.shelfDragLeftIsland()
        toy.cardModel.setDropHover("card", true)
        // The catch-all's perform: the tray takes it, then the target's
        // hover goes as the drag ends.
        toy.cardModel.shelve([])
        toy.cardModel.onDropLanded?()
        toy.cardModel.setDropHover("card", false)
        #expect(toy.cardModel.page == .shelf, "the drop shows where it landed")
        #expect(!toy.shelfDragLeavePending, "a delivery is not an abandoned drag")
        toy.fireShelfDragLeave()
        #expect(toy.islandExpanded, "a delivery is not an abandoned drag")
        #expect(!toy.shelfSummoned)
    }

    @Test("a card the person pinned stays pinned when a drag passes through")
    func pinnedCardStays() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        toy.shelfDragAtIsland()
        toy.cardModel.setDropHover("card", true)
        toy.shelfDragLeftIsland()
        toy.cardModel.setDropHover("card", false)
        toy.fireShelfDragLeave()
        #expect(toy.islandExpanded, "a pinned card outlives any fold the drag queued")
    }

    @Test("a fold forgets which targets had the drag")
    func foldClearsHover() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        toy.cardModel.setDropHover("row:claude:s1", true)
        toy.collapseFromBand()
        #expect(toy.cardModel.dropHover.isEmpty,
                "a stale row would read as a drag still over the card on the next summon")
    }
}
