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

    /// Past the leave grace — a fold that was going to land has landed
    /// unless the main queue is badly backed up, in which case the
    /// "stays up" claims pass without proving anything, never falsely.
    private func settle() async {
        try? await Task.sleep(for: .seconds(NotchToy.shelfDragLeaveGrace + 0.3))
    }

    private func waitForFold(_ toy: NotchToy, timeout: Duration = .seconds(10)) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if !toy.islandExpanded { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("a drag crossing from the notch onto a session row keeps the card up")
    func crossingOntoRowKeepsCard() async {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.shelfDragAtIsland()
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.page == .now, "the rows are the targets")

        // AppKit's order: the hosting view's exit, then the row's enter.
        toy.shelfDragLeftIsland()
        toy.cardModel.setDropHover("row:claude:s1", true)
        await settle()
        #expect(toy.islandExpanded, "the card stays under a drag heading for an agent")

        // Row to catch-all and back is still inside the island.
        toy.cardModel.setDropHover("row:claude:s1", false)
        toy.cardModel.setDropHover("card", true)
        await settle()
        #expect(toy.islandExpanded)

        // Off the card's edge and away: nothing has the drag.
        toy.cardModel.setDropHover("card", false)
        #expect(await waitForFold(toy), "a drag carried away folds the card it summoned")
    }

    @Test("a drag that leaves the notch without reaching the card folds it")
    func leavingFolds() async {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.shelfDragAtIsland()
        toy.shelfDragLeftIsland()
        #expect(await waitForFold(toy))
    }

    @Test("a drop on the card lands in the tray, turns to the shelf, and keeps the card")
    func dropOnCardKeepsCard() async {
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
        await settle()
        #expect(toy.islandExpanded, "a delivery is not an abandoned drag")
        #expect(!toy.shelfSummoned)
    }

    @Test("a card the person pinned stays pinned when a drag passes through")
    func pinnedCardStays() async {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        toy.shelfDragAtIsland()
        toy.cardModel.setDropHover("card", true)
        toy.shelfDragLeftIsland()
        toy.cardModel.setDropHover("card", false)
        await settle()
        #expect(toy.islandExpanded)
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
