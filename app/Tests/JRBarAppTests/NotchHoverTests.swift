import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The island's hover path: the wink tells before the card opens, an
/// arrival down from the menu bar's row waits the longer floor while a
/// pointer straight onto the island answers quicker, and a space that
/// hides the menu bar keeps the grow down — the pointer up there is
/// reaching for a bar that is not there.
@Suite("Notch hover")
@MainActor
struct NotchHoverTests {
    /// A toy whose island the settings say is ours; `islandVisible`
    /// stands in for `reconcile`, which needs a real notched screen.
    private func makeToy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar,
                                    islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("a pointer straight onto the island grows the card on the fast floor")
    func directArrivalUsesFastFloor() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.setHovered(true)
        #expect(!toy.islandHoverPeek, "the breath waits out its intent delay")
        try await Task.sleep(for: .seconds(0.25))
        #expect(toy.islandExpanded, "the fast floor passed — the card is up")
    }

    @Test("the breath lands after the intent delay, not at once")
    func peekWaitsOutIntentDelay() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        store.state.notch.expandOnHover = false
        toy.setHovered(true)
        #expect(!toy.islandHoverPeek, "a fresh hover has earned nothing yet")
        try await Task.sleep(for: .seconds(0.2))
        #expect(toy.islandHoverPeek, "the rest earned the breath")
        #expect(!toy.islandExpanded, "the tell is only a tell — no card")
        toy.setHovered(false)
        #expect(!toy.islandHoverPeek, "leaving settles it back")
    }

    @Test("a bar-row arrival waits the third-of-a-second floor")
    func barArrivalUsesSlowFloor() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let start = ContinuousClock.now
        toy.bandHover(true, fromBar: true)
        #expect(!toy.islandHoverPeek, "the breath waits out the intent delay")
        // Measured, not slept: a 0.2 s sleep that overslept the floor
        // under a busy suite saw the card already up. The grow's
        // asyncAfter can land late but never early.
        let at = try #require(await expansionTime(toy, from: start))
        #expect(at > .milliseconds(260), "the menu-bar floor held (grew at \(at))")
        // The breath only lands while the card is down, and a grow does
        // not clear it — still up now means it came first, inside the
        // bar's floor.
        #expect(toy.islandHoverPeek, "the breath landed inside the bar's floor")
    }

    /// A mutable answer a closure can read — `@unchecked Sendable` so
    /// the toy's `@MainActor` closures take it without a capture warning.
    private final class Answer: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// Poll the expansion and report when it landed — measured time, so
    /// a slow `Task.sleep` cannot blur the floor the test is proving. The
    /// timeout is a generous upper bound for a congested main queue: the
    /// arm is an `asyncAfter` whose deadline can slide under a parallel
    /// suite — what matters is it did not fire before the bar's floor.
    /// Giving up takes one more poll past the timeout: a main thread held
    /// longer than that by a busy machine (2026-09-22: a 4.7 s stall ran
    /// this suite's 0.25 s tests to five seconds) wakes the poll ahead of
    /// the grow that came due meanwhile, and the next poll sees it land.
    private func expansionTime(_ toy: NotchToy, from start: ContinuousClock.Instant,
                             timeout: Duration = .seconds(4)) async throws -> Duration? {
        var timedOut = false
        while true {
            if toy.islandExpanded { return ContinuousClock.now - start }
            if timedOut { return nil }
            timedOut = ContinuousClock.now - start >= timeout
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("crossing from an ear onto the island keeps the arrival's deadline")
    func earToIslandKeepsDeadline() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let start = ContinuousClock.now
        toy.bandHover(true, fromBar: true)
        try await Task.sleep(for: .seconds(0.1))
        toy.setHovered(true)   // the island window's own hover, mid-pause
        // A crossing that restarted the clock would fire at ≈0.22 s;
        // the kept bar floor lands at ≈0.30 s from arrival.
        let at = try #require(await expansionTime(toy, from: start))
        #expect(at > .milliseconds(260), "the crossing must not restart the clock (grew at \(at))")
    }

    @Test("leaving the island window onto the tray is not a leave")
    func windowLeaveOntoBandKeepsHover() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let onBand = Answer(true)
        toy.pointerOnBand = { onBand.value }
        toy.setHovered(true)
        // The window's own leave while the pointer still sits on the
        // tray — the band's read outranks it, the armed grow survives.
        toy.setHovered(false)
        try await Task.sleep(for: .seconds(0.25))
        #expect(toy.islandExpanded)
        // The band itself saying "left" is the real leave.
        onBand.value = false
        toy.setHovered(false)
        try await Task.sleep(for: .seconds(0.3))
        #expect(!toy.islandExpanded)
    }

    @Test("a space that hides the menu bar keeps the grow down — the wink still answers")
    func fullscreenSuppressesHoverOpen() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let hidden = Answer(true)
        toy.menuBarHidden = { hidden.value }
        toy.setHovered(true)
        try await Task.sleep(for: .seconds(0.3))
        #expect(!toy.islandExpanded, "the floor passed but the grow stayed down")
        #expect(toy.islandHoverPeek, "the tell is only a tell — it still shows")
        // The spent arm is not deferred: a live space again grows only
        // on a new hover, not off the suppressed one's back.
        hidden.value = false
        try await Task.sleep(for: .seconds(0.3))
        #expect(!toy.islandExpanded)
        toy.setHovered(false)
        toy.setHovered(true)
        try await Task.sleep(for: .seconds(0.25))
        #expect(toy.islandExpanded, "a fresh hover in a live space grows")
    }

    @Test("a headless grow never reaches the system haptic")
    func headlessGrowSkipsHaptic() {
        let (toy, store) = makeToy()
        var ticks = 0
        toy.expandHaptic = { ticks += 1 }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        #expect(ticks == 0)
        store.state.notch.hapticTick = false
        toy.collapseFromBand()
        toy.expandFromBand()
        #expect(ticks == 0)
    }

    @Test("the bare wink grows the housing down, never sideways")
    func barePeekGrowsDown() {
        // The bare housing is exactly the notch: sideways paint would
        // reach past the hardware and sit under menu-bar clicks, so its
        // tell grows straight down — the island's own direction.
        let size = CGSize(width: 200, height: 32)
        #expect(NotchIslandLayout.peekAdjusted(size, bare: true)
            == CGSize(width: 200, height: 32 + NotchMotion.hoverGrowHeight))
        #expect(NotchIslandLayout.peekAdjusted(size, bare: false)
            == CGSize(width: 200 + NotchMotion.hoverGrowWidth,
                      height: 32 + NotchMotion.hoverGrowHeight))
    }

    @Test("a stored notch settings without hapticTick decodes it on")
    func hapticTickDecodesOn() throws {
        let json = #"{"enabled":true,"provider":"jrbar"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(NotchSettings.self, from: json)
        #expect(settings.hapticTick)
    }

    // MARK: lane utilities

    @Test("Open after sets both clocks: 0, 0.12 and 0.5 s, with the menu bar's floor kept")
    func openAfterClocks() {
        let now = NotchMotion.hoverDelays(openAfter: 0, fromBar: false)
        #expect(now.peek == 0 && now.expand == 0)
        let standard = NotchMotion.hoverDelays(openAfter: 0.12, fromBar: false)
        #expect(standard.peek == 0.12 && standard.expand == 0.12, "the default is today's timing")
        let slow = NotchMotion.hoverDelays(openAfter: 0.5, fromBar: false)
        #expect(slow.peek == NotchMotion.hoverDelay && slow.expand == 0.5, "the breath still tells first")
        #expect(NotchMotion.hoverDelays(openAfter: 0, fromBar: true).expand == NotchMotion.barArrivalFloor)
        #expect(NotchMotion.hoverDelays(openAfter: 0.5, fromBar: true).expand == 0.5)
        #expect(NotchMotion.hoverDelays(openAfter: .nan, fromBar: false).expand == NotchMotion.hoverDelay)
    }

    @Test("a half-second Open after holds the card back that long")
    func slowOpenAfterIsHonoured() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        store.state.notch.hoverOpenDelay = 0.5
        let start = ContinuousClock.now
        toy.setHovered(true)
        let at = try #require(await expansionTime(toy, from: start))
        #expect(at > .milliseconds(450), "grew at \(at)")
        #expect(toy.islandHoverPeek, "the breath came first, at the standard delay")
    }

    @Test("a zero Open after grows the card without a pause")
    func instantOpenAfterIsHonoured() async throws {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        store.state.notch.hoverOpenDelay = 0
        let start = ContinuousClock.now
        toy.setHovered(true)
        _ = try #require(await expansionTime(toy, from: start))
        #expect(toy.islandExpanded)
    }
}
