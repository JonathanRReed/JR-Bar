import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// A pinned Screen Bar peek folds on Esc, but its local monitor took every
/// Esc in the app, so Esc pressed in a Settings sheet or a text field folded
/// the peek and never reached the sheet. It reads the same rule as the notch
/// card (`CardEscapeWatch`): an Esc the peek's own window or no window owns
/// is taken, and any other JR-Bar window keeps its own. The keyboard is a
/// fake and nothing is shown.
@Suite("Screen Bar peek Esc")
@MainActor
struct ScreenBarPeekEscapeTests {
    @Test("a pinned peek ignores an Esc meant for another window and folds on Esc in none")
    func peekTakesOnlyItsOwnEscape() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        peek.installKeyMonitors()
        #expect(peek.listensForEscape)

        #expect(!keys.press(in: NSObject()), "a Settings sheet's Esc is the sheet's")
        #expect(peek.listensForEscape, "the peek is still pinned")

        #expect(keys.press(in: nil), "an Esc nobody else owns folds it")
        #expect(!peek.listensForEscape)
        #expect(keys.liveLocal == 0 && keys.liveGlobal == 0)
    }

    @Test("an Esc delivered to the peek's own window is taken")
    func peekTakesEscapeInItsOwnWindow() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        // The panel exists but is never ordered in.
        let panel = peek.makePanel()
        defer { panel.close() }
        peek.installKeyMonitors()
        #expect(!keys.press(in: NSObject()))
        #expect(keys.press(in: panel))
        #expect(!peek.listensForEscape)
    }

    @Test("a pinned peek still folds on an Esc pressed in another app, and no other key is taken")
    func peekGoesOnGlobalEscape() {
        let keys = CardEscapeWatchTests.FakeKeys()
        let peek = ScreenBarPeek()
        peek.keySource = keys.source
        peek.installKeyMonitors()
        #expect(!keys.press(36, in: nil), "Return is never taken")
        #expect(peek.listensForEscape)
        keys.pressElsewhere()
        #expect(!peek.listensForEscape)
    }

    @Test("a peek that was never pinned listens for nothing")
    func unpinnedPeekListensForNothing() {
        let peek = ScreenBarPeek()
        #expect(!peek.listensForEscape)
    }
}
