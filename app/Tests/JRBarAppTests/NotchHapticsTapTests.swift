import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// What the island taps, counted rather than felt: a swipe that turns the
/// card's page, a gesture that folds it, never a thing the island does by
/// itself, always behind the one switch.
@Suite("Notch haptic taps")
@MainActor
struct NotchHapticsTapTests {
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

    /// A live-seeming island: the switch on, the trackpad present, and the
    /// tap counted rather than felt.
    private func tapping() -> (NotchToy, ToysStore, taps: () -> [NotchHaptics.Pattern]) {
        let (toy, store) = makeToy()
        var heard: [NotchHaptics.Pattern] = []
        toy.hapticsLive = { true }
        toy.haptic = { heard.append($0) }
        return (toy, store, { heard })
    }

    @Test("a swipe that turns the page taps once, and one that hits the edge does not")
    func pageTurnTaps() {
        let (toy, store, taps) = tapping()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        #expect(taps() == [.generic], "the grow's own tap")
        toy.islandSwipe(.left)
        #expect(toy.cardModel.page == .shelf)
        #expect(taps() == [.generic, .alignment])
        toy.islandSwipe(.left)
        #expect(taps().count == 2, "past the last page is the nudge, silent")
        toy.islandSwipe(.right)
        #expect(taps().count == 3)
    }

    @Test("a swipe, a pinch or a pull that folds the card taps; a click or a hover leaving does not")
    func foldTaps() {
        let (toy, store, taps) = tapping()
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        toy.islandSwipe(.up)
        #expect(!toy.islandExpanded)
        #expect(taps() == [.generic, .alignment])
        toy.expandFromBand()
        toy.islandPinch(.fold)
        #expect(taps() == [.generic, .alignment, .generic, .alignment])
        toy.expandFromBand()
        toy.islandPullEnded(.commit)
        #expect(taps().suffix(2) == [.generic, .alignment])
        let before = taps().count
        toy.expandFromBand()
        toy.collapseFromBand()
        #expect(taps().count == before + 1, "only the grow; a click's fold is no swipe")
    }

    @Test("the one switch silences every tap, and Reduce Motion silences none")
    func switchAndReduceMotion() {
        let (toy, store, taps) = tapping()
        defer { withExtendedLifetime(store) {} }
        toy.reduceMotion = { true }
        toy.expandFromBand()
        toy.islandSwipe(.left)
        toy.islandSwipe(.up)
        #expect(taps() == [.generic, .alignment, .alignment], "Reduce Motion has no say over a tap")
        store.state.notch.hapticTick = false
        toy.expandFromBand()
        toy.islandSwipe(.left)
        toy.islandSwipe(.up)
        #expect(taps().count == 3, "switched off, nothing taps")
    }

    @Test("an ask arriving never taps: the island does nothing to a hand that did nothing")
    func newsNeverTaps() {
        let (toy, store, taps) = tapping()
        defer { withExtendedLifetime(store) {} }
        _ = toy.offer(AlcoveNotice(id: "a", kind: .completed, title: "Claude · review-patch",
                               subtitle: "finished", provider: "claude", key: "c"))
        #expect(taps().isEmpty)
    }
}
