import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The grown card's two pages: every open starts on Now, the shelf's
/// summons land on Shelf, a sideways swipe across the card turns it,
/// and the shelf's tab counts what waits there.
@Suite("Notch card pages")
@MainActor
struct NotchCardPageTests {
    @Test("an open starts on Now and a fold puts the shelf page away")
    func startsOnNow() {
        let card = makeTestCardModel()
        #expect(card.page == .now)
        card.pinned = true
        card.show(.shelf)
        #expect(card.page == .shelf)
        card.pinned = false
        #expect(card.page == .now, "the next open starts on Now")
    }

    @Test("a repeat unpin while away keeps a shelf summon's page")
    func summonSurvivesRepeatUnpin() {
        let card = makeTestCardModel()
        card.show(.shelf)
        card.pinned = false
        #expect(card.page == .shelf)
    }

    @Test("the Mirror lives on the shelf page")
    func mirrorLandsOnShelf() {
        let card = makeTestCardModel()
        card.mirrorEnabled = { true }
        card.summonMirror()
        #expect(card.page == .shelf)
    }

    @Test("the shelf tab counts timers and a fresh copy")
    func waiting() {
        let card = makeTestCardModel()
        let before = card.shelfWaiting
        card.timers.add(label: "Tea", duration: 180)
        #expect(card.shelfWaiting == before + 1)
    }

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

    @Test("across the grown card a sideways swipe turns the page")
    func swipeTurns() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        toy.islandSwipe(.left)
        #expect(toy.cardModel.page == .shelf)
        toy.islandSwipe(.right)
        #expect(toy.cardModel.page == .now)
    }

    @Test("⌃⌥D opens onto the shelf; a drag opens on Now and its drop turns to the shelf")
    func shelfSummonsLandOnShelf() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.toggleShelfFromHotkey()
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.page == .shelf)
        toy.toggleShelfFromHotkey()
        #expect(!toy.islandExpanded)
        toy.shelfSummon()
        #expect(toy.cardModel.page == .now, "the agents are drop targets on Now")
        toy.shelfDrop([])
        #expect(toy.cardModel.page == .shelf, "the drop shows where it landed")
    }
}
