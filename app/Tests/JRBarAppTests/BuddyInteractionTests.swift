import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Notch Buddy's pet half: taps pet it and cycle the trick
/// repertoire, treats feed it and burst hearts, completed sessions land
/// as crumbs, and the summary line names it. `CoreModel` without a
/// daemon has no sessions, so the ask-opening half of `tapped()` is a
/// no-op here rather than faked.
@Suite("Buddy interaction")
@MainActor
struct BuddyInteractionTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makeToy(state: ToysState = ToysState()) -> (NotchBuddyToy, ToysStore) {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state)
        return (store.notchBuddy, store)
    }

    @Test("a tap is a pet and cycles the tricks")
    func tapPetsAndTricks() {
        let (toy, store) = makeToy()
        toy.tapped(at: t0)
        #expect(store.state.notchBuddy.care.petCount == 1)
        #expect(store.state.notchBuddy.care.lastInteractionAt == t0.timeIntervalSince1970)
        guard !reducedMotion else { return }
        #expect(toy.trickStartedAt == t0)
        #expect(toy.trickKind == .hop)
        toy.tapped(at: t0)
        #expect(toy.trickKind == .spin, "the repertoire cycles, never repeating")
        toy.tapped(at: t0)
        #expect(toy.trickKind == .wave)
    }

    @Test("a treat feeds, bursts hearts, and hops when motion is on")
    func treatFeeds() {
        let (toy, store) = makeToy()
        toy.giveTreat(at: t0)
        #expect(store.state.notchBuddy.care.treatsGiven == 1)
        #expect(store.state.notchBuddy.care.petCount == 1, "a treat is also a pat")
        #expect(store.state.notchBuddy.care.mood(at: t0) == .fed)
        #expect(toy.treatBurstAt == t0)
        if reducedMotion {
            #expect(toy.hopUntil == nil)
        } else {
            #expect(toy.hopUntil == t0.addingTimeInterval(1.1))
        }
    }

    @Test("the name field writes through and the summary names the buddy")
    func naming() {
        let (toy, store) = makeToy()
        #expect(toy.buddyName == "Dot")
        #expect(toy.summary(at: t0).statusLine == "Dot is asleep.")
        toy.nameBinding.wrappedValue = "Pixel"
        #expect(store.state.notchBuddy.buddyName == "Pixel")
        #expect(toy.buddyName == "Pixel")
        #expect(toy.summary(at: t0).statusLine == "Pixel is asleep.")
        toy.nameBinding.wrappedValue = "   "
        #expect(toy.buddyName == "Dot", "spaces are not a name")
        store.state.notchBuddy.character = "crab"
        #expect(toy.buddyName == "Pinch")
    }

    @Test("a day of quiet turns the summary to missing, and says so")
    func missing() {
        var state = ToysState()
        state.notchBuddy.care.pet(at: t0.addingTimeInterval(-BuddyCare.lonelyAfter - 60))
        let (toy, store) = makeToy(state: state)
        let summary = toy.summary(at: t0)
        #expect(summary.care == .missing)
        #expect(summary.statusLine == "Dot misses you — tap it to say hi.")
        _ = store  // the toy's link to the store is weak; hold it
    }

    @Test("the card's friendship line reports pets and crumbs")
    func careLineReports() {
        let (toy, store) = makeToy()
        #expect(toy.careLine == "Never petted. It doesn't mind yet.")
        store.state.notchBuddy.care.pet(at: Date())
        store.state.notchBuddy.care.eat(at: Date(), count: 3)
        #expect(toy.careLine == "1 pet · 3 crumbs")
        store.state.notchBuddy.care.feed(at: Date())
        #expect(toy.careLine.hasPrefix("Blissed out"))
    }
}
