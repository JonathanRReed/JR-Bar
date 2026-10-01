import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Esc lets a held card go, but only an Esc nobody else owns. The local
/// monitor sees the key of every JR-Bar window, and it used to take them
/// all: Esc pressed in a Settings sheet, a text field or a popover was
/// swallowed and folded the card instead of reaching the window the person
/// was in. Here the keyboard is a fake: nothing listens to the real one.
@Suite("Card Esc watch")
@MainActor
struct CardEscapeWatchTests {
    /// The keyboard stand-in: it hands out monitor tokens and delivers
    /// presses to whatever listens, the way AppKit's monitors would.
    @MainActor
    final class FakeKeys {
        private var local: [Int: @MainActor (CardEscapeWatch.Press) -> Bool] = [:]
        private var global: [Int: @MainActor (CardEscapeWatch.Press) -> Void] = [:]
        private var next = 0
        private(set) var removed = 0

        var liveLocal: Int { local.count }
        var liveGlobal: Int { global.count }

        var source: CardEscapeWatch.Source {
            CardEscapeWatch.Source(
                addLocal: { handler in
                    self.next += 1
                    self.local[self.next] = handler
                    return self.next
                },
                addGlobal: { handler in
                    self.next += 1
                    self.global[self.next] = handler
                    return self.next
                },
                remove: { token in
                    guard let id = token as? Int else { return }
                    if self.local.removeValue(forKey: id) != nil { self.removed += 1 }
                    if self.global.removeValue(forKey: id) != nil { self.removed += 1 }
                })
        }

        /// A key delivered to this app, in `window`. True when a monitor
        /// consumed it (AppKit would then not deliver it on).
        @discardableResult
        func press(_ keyCode: UInt16 = CardEscapeWatch.escapeKeyCode, in window: AnyObject?) -> Bool {
            let press = CardEscapeWatch.Press(keyCode: keyCode, window: window)
            var consumed = false
            for handler in Array(local.values) where handler(press) { consumed = true }
            return consumed
        }

        /// A key delivered to another app: the global monitors hear it.
        func pressElsewhere(_ keyCode: UInt16 = CardEscapeWatch.escapeKeyCode) {
            let press = CardEscapeWatch.Press(keyCode: keyCode, window: nil)
            for handler in Array(global.values) { handler(press) }
        }
    }

    /// A stand-in for a window: only identity matters.
    private final class FakeWindow {}

    private func makeWatch(_ keys: FakeKeys, card: FakeWindow, escapes: Counter) -> CardEscapeWatch {
        CardEscapeWatch(source: keys.source, ownWindows: { [card] }, onEscape: { escapes.count += 1 })
    }

    private final class Counter { var count = 0 }

    // MARK: The watch

    @Test("Esc in the card's own window, or in no window of ours, is taken and lets the card go")
    func escapeThatBelongsToTheCardIsTaken() {
        let keys = FakeKeys()
        let card = FakeWindow()
        let escapes = Counter()
        let watch = makeWatch(keys, card: card, escapes: escapes)
        watch.start()
        #expect(keys.press(in: card), "the card's own window")
        #expect(keys.press(in: nil), "no window owns it: JR-Bar is active with nothing key")
        #expect(escapes.count == 2)
    }

    @Test("Esc in a Settings sheet, a field or a popover passes through and the card stays")
    func escapeInAnotherWindowIsLeftAlone() {
        let keys = FakeKeys()
        let escapes = Counter()
        let watch = makeWatch(keys, card: FakeWindow(), escapes: escapes)
        watch.start()
        let settingsSheet = FakeWindow()
        let popover = FakeWindow()
        #expect(!keys.press(in: settingsSheet), "the sheet gets its own Esc")
        #expect(!keys.press(in: popover), "the entry popover gets its own Esc")
        #expect(escapes.count == 0, "and the card is not folded under it")
    }

    @Test("no other key is ever taken, in any window")
    func otherKeysPassThrough() {
        let keys = FakeKeys()
        let card = FakeWindow()
        let escapes = Counter()
        let watch = makeWatch(keys, card: card, escapes: escapes)
        watch.start()
        for code: UInt16 in [0, 36, 48, 49, 123, 126] {
            #expect(!keys.press(code, in: card))
            #expect(!keys.press(code, in: nil))
        }
        #expect(escapes.count == 0)
    }

    @Test("Esc in another app still lets the card go: a global monitor only listens")
    func globalEscapeLetsTheCardGo() {
        let keys = FakeKeys()
        let escapes = Counter()
        let watch = makeWatch(keys, card: FakeWindow(), escapes: escapes)
        watch.start()
        keys.pressElsewhere()
        keys.pressElsewhere(36)
        #expect(escapes.count == 1, "only Esc counts")
    }

    @Test("stop takes both monitors down, and a repeated start never doubles them")
    func monitorsComeAndGo() {
        let keys = FakeKeys()
        let card = FakeWindow()
        let escapes = Counter()
        let watch = makeWatch(keys, card: card, escapes: escapes)
        #expect(!watch.isListening)
        watch.start()
        watch.start()
        #expect(watch.isListening)
        #expect(keys.liveLocal == 1 && keys.liveGlobal == 1, "one of each, however often it starts")
        watch.stop()
        #expect(!watch.isListening)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0)
        #expect(!keys.press(in: card), "nothing listens once it has stopped")
        #expect(escapes.count == 0)
    }

    @Test("the belonging rule: the card's windows and no window, and nothing else")
    func belongingRule() {
        let card = FakeWindow()
        let other = FakeWindow()
        #expect(CardEscapeWatch.belongsToCard(window: card, cardWindows: [card]))
        #expect(CardEscapeWatch.belongsToCard(window: nil, cardWindows: [card]))
        #expect(CardEscapeWatch.belongsToCard(window: nil, cardWindows: []))
        #expect(!CardEscapeWatch.belongsToCard(window: other, cardWindows: [card]))
        #expect(!CardEscapeWatch.belongsToCard(window: other, cardWindows: []))
        #expect(!CardEscapeWatch.belongsToCard(window: other, cardWindows: [nil]),
                "a card window that is not up yet owns nothing")
    }

    // MARK: The owners

    /// A presenter whose card is pinned without anything being shown: with
    /// no anchor to hang from, `pin` installs the Esc watch and draws nothing.
    private func pinnedPresenter(_ keys: FakeKeys) -> NotchCardPresenter {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.keySource = keys.source
        presenter.surface = { .glass }
        presenter.focus = { ScreenBarFocus(style: nil, label: "JR-Bar", word: "Working", clickSession: nil) }
        presenter.anchor = { nil }
        presenter.pin()
        return presenter
    }

    @Test("a pinned glass card ignores an Esc meant for another window, and goes on Esc in none")
    func presenterTakesOnlyItsOwnEscape() {
        let keys = FakeKeys()
        let presenter = pinnedPresenter(keys)
        #expect(presenter.isPinned && presenter.listensForEscape)

        #expect(!keys.press(in: FakeWindow()), "a Settings sheet's Esc is the sheet's")
        #expect(presenter.isPinned, "the card is still up")

        #expect(keys.press(in: nil))
        #expect(!presenter.isPinned, "an Esc nobody else owns lets it go")
        #expect(!presenter.listensForEscape)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0)
    }

    @Test("an Esc delivered to the glass card's own window is taken and lets it go")
    func presenterTakesEscapeInItsOwnWindow() {
        let keys = FakeKeys()
        let presenter = pinnedPresenter(keys)
        #expect(presenter.isPinned)
        #expect(keys.press(in: presenter.panel), "the card's own window is the card's to answer")
        #expect(!presenter.isPinned)
        #expect(!presenter.listensForEscape)
    }

    @Test("a pinned glass card still goes on an Esc pressed in another app")
    func presenterGoesOnGlobalEscape() {
        let keys = FakeKeys()
        let presenter = pinnedPresenter(keys)
        keys.pressElsewhere()
        #expect(!presenter.isPinned)
    }

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

    @Test("a grown island card ignores an Esc meant for another window, and folds on Esc in none")
    func islandTakesOnlyItsOwnEscape() {
        let keys = FakeKeys()
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.cardKeySource = keys.source
        toy.expand(held: true)
        #expect(toy.islandExpanded)
        // The state machine runs with the runtime off; switch it on just
        // long enough for the card to install its Esc watch, then off
        // again so folding touches no real reader.
        toy.runtimeEnabled = true
        toy.syncCardKeyMonitors()
        toy.runtimeEnabled = false
        #expect(toy.listensForEscape)

        #expect(!keys.press(in: FakeWindow()), "Esc in a Settings sheet or a text field passes through")
        #expect(toy.islandExpanded, "the card is not folded under it")
        #expect(toy.listensForEscape)

        #expect(keys.press(in: nil))
        #expect(!toy.islandExpanded, "an Esc nobody else owns lets the card go")
        #expect(!toy.listensForEscape)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0, "the watch went with the card")
    }

    @Test("an Esc delivered to the island's own window is taken and folds the card")
    func islandTakesEscapeInItsOwnWindow() {
        let keys = FakeKeys()
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.cardKeySource = keys.source
        toy.expand(held: true)
        // The island window exists but is never shown: it is assigned after
        // the grow, which would otherwise order it onto the screen.
        let window = NotchIslandWindow(toy: toy)
        toy.island = window
        defer {
            toy.island = nil
            window.close()
        }
        toy.runtimeEnabled = true
        toy.syncCardKeyMonitors()
        toy.runtimeEnabled = false
        #expect(toy.listensForEscape)
        #expect(!keys.press(in: FakeWindow()), "another window's Esc still passes through")
        #expect(toy.islandExpanded)
        #expect(keys.press(in: window), "the island's own window is the card's to answer")
        #expect(!toy.islandExpanded)
    }

    @Test("a grown island card still folds on an Esc pressed in another app")
    func islandFoldsOnGlobalEscape() {
        let keys = FakeKeys()
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.cardKeySource = keys.source
        toy.expand(held: true)
        toy.runtimeEnabled = true
        toy.syncCardKeyMonitors()
        toy.runtimeEnabled = false
        keys.pressElsewhere()
        #expect(!toy.islandExpanded)
    }

    @Test("a card that was never grown listens for nothing")
    func parkedCardListensForNothing() {
        let keys = FakeKeys()
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.cardKeySource = keys.source
        toy.runtimeEnabled = true
        toy.syncCardKeyMonitors()
        toy.runtimeEnabled = false
        #expect(!toy.listensForEscape)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0)
    }
}
