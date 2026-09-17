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
                              state: state, cardModel: makeTestCardModel())
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("a pointer straight onto the island grows the card on the fast floor")
    func directArrivalUsesFastFloor() async throws {
        let (toy, store) = makeToy()
        _ = store
        toy.setHovered(true)
        #expect(toy.islandHoverPeek, "the wink lands at once")
        try await Task.sleep(for: .seconds(0.25))
        #expect(toy.islandExpanded, "the fast floor passed — the card is up")
    }

    @Test("a bar-row arrival waits the third-of-a-second floor")
    func barArrivalUsesSlowFloor() async throws {
        let (toy, store) = makeToy()
        _ = store
        toy.bandHover(true, fromBar: true)
        #expect(toy.islandHoverPeek, "the tell still lands at once")
        try await Task.sleep(for: .seconds(0.2))
        #expect(!toy.islandExpanded, "the menu-bar floor has not landed yet")
        try await Task.sleep(for: .seconds(0.25))
        #expect(toy.islandExpanded)
    }

    /// A mutable answer a closure can read — `@unchecked Sendable` so
    /// the toy's `@MainActor` closures take it without a capture warning.
    private final class Answer: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// Poll the expansion and report when it landed — measured time, so
    /// a slow `Task.sleep` cannot blur the floor the test is proving. The
    /// timeout has slack for a congested main queue: the arm is an
    /// `asyncAfter` whose deadline can slide under a parallel suite —
    /// what matters is it did not fire before the bar's floor.
    private func expansionTime(_ toy: NotchToy, from start: ContinuousClock.Instant,
                             timeout: Duration = .seconds(1.5)) async throws -> Duration? {
        while ContinuousClock.now - start < timeout {
            if toy.islandExpanded { return ContinuousClock.now - start }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test("crossing from an ear onto the island keeps the arrival's deadline")
    func earToIslandKeepsDeadline() async throws {
        let (toy, store) = makeToy()
        _ = store
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
        _ = store
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
        _ = store
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

    @Test("the grow's haptic tick fires on open — and the setting silences it")
    func hapticTickOnOpen() {
        let (toy, store) = makeToy()
        var ticks = 0
        toy.expandHaptic = { ticks += 1 }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        #expect(ticks == 1)
        store.state.notch.hapticTick = false
        toy.collapseFromBand()
        toy.expandFromBand()
        #expect(ticks == 1, "the toggle is the user's say over the tick")
    }

    @Test("the bare wink grows the housing down, never sideways")
    func barePeekGrowsDown() {
        // The bare housing is exactly the notch: sideways paint would
        // reach past the hardware and sit under menu-bar clicks, so its
        // tell grows straight down — the island's own direction.
        let size = CGSize(width: 200, height: 32)
        #expect(NotchIslandLayout.peekAdjusted(size, bare: true)
            == CGSize(width: 200, height: 32 + NotchIslandLayout.peekGrow))
        #expect(NotchIslandLayout.peekAdjusted(size, bare: false)
            == CGSize(width: 200 + 2 * NotchIslandLayout.peekGrow, height: 32))
    }

    @Test("a stored notch settings without hapticTick decodes it on")
    func hapticTickDecodesOn() throws {
        let json = #"{"enabled":true,"provider":"jrbar"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(NotchSettings.self, from: json)
        #expect(settings.hapticTick)
    }
}
