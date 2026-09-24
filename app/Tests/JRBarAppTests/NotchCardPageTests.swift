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
        toy.toggleShelf()
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.page == .shelf)
        toy.toggleShelf()
        #expect(!toy.islandExpanded)
        toy.shelfSummon()
        #expect(toy.cardModel.page == .now, "the agents are drop targets on Now")
        toy.shelfDrop([])
        #expect(toy.cardModel.page == .shelf, "the drop shows where it landed")
    }

    @Test("jrbar://shelf opens onto the shelf, not the page the card last showed")
    func shelfLinkLandsOnShelf() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        // The router's hand is the key's own toggle, as the delegate wires it.
        let router = AppCommandRouter()
        router.toggleShelf = { toy.toggleShelf() }
        let link = URL(string: "jrbar://shelf")!
        // The card was last up on Now, from a band click.
        toy.expandFromBand()
        #expect(toy.cardModel.page == .now)
        toy.collapseFromBand()
        #expect(router.open(link) == .done)
        #expect(toy.islandExpanded)
        #expect(toy.cardModel.page == .shelf)
        // Still a toggle: a second link folds the card it opened.
        #expect(router.open(link) == .done)
        #expect(!toy.islandExpanded)
        #expect(toy.cardModel.page == .now, "the next band open starts on Now")
    }

    @Test("the delegate hands the shelf link the key's own toggle")
    func delegateWiresTheShelfToggle() throws {
        let delegate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/AppDelegate.swift")
        let text = try String(contentsOf: delegate, encoding: .utf8)
        let start = try #require(text.range(of: "router.toggleShelf = {"))
        let end = try #require(text.range(of: "\n        }\n", range: start.upperBound..<text.endIndex))
        let wiring = String(text[start.upperBound..<end.lowerBound])
        #expect(wiring.contains("return notch.toggleShelf()"))
        #expect(!wiring.contains("expandFromBand"), "a bare expand opens on Now")
    }

    @Test("with no island drawn the shelf goes to the band's glass card, and only an off utility refuses")
    func shelfWithoutIslandUsesTheGlassCard() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.islandVisible = false
        #expect(toy.notchSurface == .glass)
        var glassToggles = 0
        toy.toggleGlassShelf = {
            glassToggles += 1
            return nil
        }
        #expect(toy.toggleShelf() == nil)
        #expect(glassToggles == 1)
        #expect(!toy.islandExpanded)
        #expect(toy.cardModel.page == .now, "the island's card is not the one that opened")
        // The glass card's own answer is the link's.
        toy.toggleGlassShelf = { "The Shelf card has nowhere to open right now." }
        #expect(toy.toggleShelf() == "The Shelf card has nowhere to open right now.")
        store.state.notch.enabled = false
        #expect(toy.toggleShelf() == "The Notch utility is off — turn it on in Utilities.")
        #expect(glassToggles == 1)
    }

    @Test("the delegate hands the glass card's shelf to the band's own toggle")
    func delegateWiresTheGlassShelf() throws {
        let delegate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/AppDelegate.swift")
        let text = try String(contentsOf: delegate, encoding: .utf8)
        let start = try #require(text.range(of: "toysStore.notch.toggleGlassShelf = {"))
        let end = try #require(text.range(of: "\n        }\n", range: start.upperBound..<text.endIndex))
        let wiring = String(text[start.upperBound..<end.lowerBound])
        #expect(wiring.contains("interaction?.toggleShelfCard()"))
    }

    @Test("a glass card with nothing to hang from says so and leaves no pin or Shelf page")
    func glassShelfWithNowhereToOpen() {
        let idle = ScreenBarFocus(style: nil, label: "JR-Bar", word: "Idle", clickSession: nil)
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.surface = { .glass }
        presenter.focus = { idle }
        // No anchor: the pin lands, and nothing is ever ordered in.
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { idle })
        #expect(interaction.toggleShelfCard() == "The Shelf card has nowhere to open right now.")
        #expect(!presenter.isShown)
        #expect(!presenter.isPinned)
        #expect(presenter.model.page == .now, "the next band open starts on Now")
    }
}
