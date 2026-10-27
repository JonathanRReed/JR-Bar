import JRBarTestSupport
import Foundation
@testable import JRBarCore
import Observation
import Testing
@testable import JRBarApp

@Suite("Notch provider carousel", .temporaryDirectory)
struct NotchProviderCarouselTests {
    @Test("a six-second cadence leaves the default provider cadence at three seconds")
    func independentCadences() {
        var providers = NotchProviderCarousel()
        var awake = NotchProviderCarousel(interval: 6)
        for (time, expectedProvider, expectedMark) in [
            (0.0, "claude", "mark"), (3.0, "codex", "mark"),
            (6.0, "claude", "power"), (9.0, "codex", "power"),
            (12.0, "claude", "mark")] {
            let provider = providers.update(["claude", "codex"], now: time)
            let mark = awake.update(["mark", "power"], now: time)
            #expect(provider == expectedProvider)
            #expect(mark == expectedMark)
        }
        let lateMark = awake.update(["mark", "power"], now: 25)
        #expect(lateMark == "mark")
        #expect(awake.nextChange == 30)
        awake.update([], now: 25)
        #expect(awake.nextChange == nil)
        let resumedMark = awake.update(["mark", "power"], now: 26)
        #expect(resumedMark == "mark")
        #expect(awake.nextChange == 32)
    }

    @Test("one provider stays still without a scheduled change, including duplicate sessions")
    func oneProvider() {
        var carousel = NotchProviderCarousel()
        let initialProvider = carousel.update(["claude", "claude"], now: 0)
        #expect(initialProvider == "claude")
        #expect(carousel.nextChange == nil)
        let laterProvider = carousel.update(["claude"], now: 600)
        #expect(laterProvider == "claude")
        #expect(carousel.nextChange == nil)
    }

    @Test("Claude and Codex take three-second turns without resetting on reordered updates")
    func twoProviders() {
        var carousel = NotchProviderCarousel()
        let initialProvider = carousel.update(["codex", "claude"], now: 0)
        #expect(initialProvider == "claude")
        for update in 1...29 {
            let providers = update.isMultiple(of: 2) ? ["claude", "codex"] : ["codex", "claude", "claude"]
            let providerDuringTurn = carousel.update(providers, now: Double(update) / 10)
            #expect(providerDuringTurn == "claude")
            #expect(carousel.nextChange == 3)
        }
        let secondProvider = carousel.update(["codex", "claude"], now: 3)
        #expect(secondProvider == "codex")
        #expect(carousel.nextChange == 6)
        let thirdProvider = carousel.update(["claude", "codex"], now: 6)
        #expect(thirdProvider == "claude")
        let fourthProvider = carousel.update(["codex", "claude"], now: 9)
        #expect(fourthProvider == "codex")
    }

    @Test("five distinct providers receive equal turns across late updates")
    func fiveProviders() {
        var carousel = NotchProviderCarousel()
        let providers = ["claude", "codex", "gemini", "grok", "opencode"]
        var shown: [String] = []
        for turn in 0..<10 {
            if let provider = carousel.update(Array(providers.reversed()), now: Double(turn * 3)) {
                shown.append(provider)
            }
        }
        #expect(shown == providers + providers)
        let lateProvider = carousel.update(providers, now: 43)
        #expect(lateProvider == "opencode")
        #expect(carousel.nextChange == 45)
    }

    @Test("a new provider joins without stealing or resetting the current turn")
    func newProviderJoins() {
        var carousel = NotchProviderCarousel()
        carousel.update(["claude", "codex"], now: 0)
        let providerAfterJoining = carousel.update(["gemini", "codex", "claude"], now: 2)
        #expect(providerAfterJoining == "claude")
        #expect(carousel.nextChange == 3)
        let secondProvider = carousel.update(["gemini", "claude", "codex"], now: 3)
        #expect(secondProvider == "codex")
        let thirdProvider = carousel.update(["claude", "gemini", "codex"], now: 6)
        #expect(thirdProvider == "gemini")
    }

    @Test("removing the current provider selects its surviving successor for a full turn")
    func removal() {
        var carousel = NotchProviderCarousel()
        carousel.update(["claude", "codex", "gemini"], now: 0)
        carousel.update(["claude", "codex", "gemini"], now: 3)
        let successor = carousel.update(["gemini", "claude"], now: 4)
        #expect(successor == "gemini")
        #expect(carousel.nextChange == 7)
        let remainingProvider = carousel.update(["gemini"], now: 5)
        #expect(remainingProvider == "gemini")
        #expect(carousel.nextChange == nil)
        let emptyProvider = carousel.update([], now: 6)
        #expect(emptyProvider == nil)
        #expect(carousel.nextChange == nil)
    }

    @Test("a backward clock keeps the current provider and rebases its next turn")
    func backwardClock() {
        var carousel = NotchProviderCarousel()
        carousel.update(["claude", "codex"], now: 100)
        carousel.update(["claude", "codex"], now: 103)
        let providerAfterRewind = carousel.update(["codex", "claude"], now: 50)
        #expect(providerAfterRewind == "codex")
        #expect(carousel.nextChange == 53)
        let providerBeforeBoundary = carousel.update(["claude", "codex"], now: 51)
        #expect(providerBeforeBoundary == "codex")
        #expect(carousel.nextChange == 53)
        let providerAtBoundary = carousel.update(["claude", "codex"], now: 53)
        #expect(providerAtBoundary == "claude")
    }

    @Test("invalid clock readings keep the current provider without scheduling a wake")
    func invalidClocks() {
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            var carousel = NotchProviderCarousel()
            carousel.update(["claude", "codex"], now: 100)
            let providerAfterInvalidClock = carousel.update(["codex", "claude"], now: invalid)
            #expect(providerAfterInvalidClock == "claude")
            #expect(carousel.nextChange == nil)
            let providerAfterRecovery = carousel.update(["claude", "codex"], now: 101)
            #expect(providerAfterRecovery == "claude")
            #expect(carousel.nextChange == 104)
        }
    }

    @Test("a large valid clock jump schedules the next boundary strictly after now")
    func largeClockJump() throws {
        var carousel = NotchProviderCarousel()
        let providers = ["claude", "codex", "gemini", "grok", "opencode"]
        carousel.update(providers, now: Date.distantPast.timeIntervalSince1970)
        let now = Date.distantFuture.timeIntervalSince1970
        let providerAfterJump = carousel.update(providers, now: now)
        #expect(providerAfterJump != nil)
        let boundary = try #require(carousel.nextChange)
        #expect(boundary > now)
        #expect(boundary <= now + NotchProviderCarousel.interval)
        carousel.update(Array(providers.reversed()), now: now)
        #expect(carousel.nextChange == boundary)
    }

    @Test("late fractional updates keep the original cadence")
    func fractionalLateUpdate() {
        var carousel = NotchProviderCarousel()
        let providers = ["claude", "codex", "gemini"]
        carousel.update(providers, now: 0.25)
        let lateProvider = carousel.update(providers, now: 10.5)
        #expect(lateProvider == "claude")
        #expect(carousel.nextChange == 12.25)
        let repeatedProvider = carousel.update(Array(providers.reversed()), now: 10.5)
        #expect(repeatedProvider == "claude")
        #expect(carousel.nextChange == 12.25)
        let nextProvider = carousel.update(providers, now: 12.25)
        #expect(nextProvider == "codex")
    }

    @Test("a distant jump advances by whole cycles without an unbounded integer conversion")
    func distantJumpPreservesTurn() {
        var carousel = NotchProviderCarousel()
        let providers = ["claude", "codex", "gemini", "grok", "opencode"]
        carousel.update(providers, now: 0)
        let now = 60_000_000_004.0
        let distantProvider = carousel.update(providers, now: now)
        #expect(distantProvider == "codex")
        #expect(carousel.nextChange == 60_000_000_006)
        let repeatedProvider = carousel.update(Array(providers.reversed()), now: now)
        #expect(repeatedProvider == "codex")
        #expect(carousel.nextChange == 60_000_000_006)
    }
}

@Suite("Notch provider focus", .temporaryDirectory, .serialized)
@MainActor
struct NotchProviderFocusTests {
    private final class ObservationChange: @unchecked Sendable { var fired = false }

    private func makeCore() -> CoreModel {
        let core = CoreModel(socketPath: (TestTemporaryDirectory.currentURL.path + "/") + "jrbar-provider-carousel-fixture.sock")
        core.handle(.connected)
        return core
    }

    private func sessions(_ tick: Int = 0) -> [CoreSession] {
        [CoreSession(id: "claude:a", provider: "claude", label: "Claude work", mode: "working", since: Double(tick * 2)),
         CoreSession(id: "codex:a", provider: "codex", label: "Codex work", mode: "working", since: Double(tick * 2 + 1))]
    }

    @Test("focus reads stay quiet until the provider turn changes")
    func focusReadsDoNotObserveClockBookkeeping() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        core.apply(.state(CoreState(sessions: sessions())))
        #expect(store.screenBarFocus.focusSession == "claude:a")
        let change = ObservationChange()
        withObservationTracking {
            _ = store.screenBarFocus
            _ = store.screenBarWings
        } onChange: {
            change.fired = true
        }
        for tick in 1...29 {
            clock = 100 + Double(tick) / 10
            #expect(store.screenBarFocus.focusSession == "claude:a")
            #expect(store.screenBarWings.left?.provider == "claude")
            #expect(store.nextAskAgeTick(now: clock) == 103)
            #expect(!change.fired)
        }
        clock = 103
        #expect(store.screenBarFocus.focusSession == "codex:a")
        #expect(change.fired)
    }

    @Test("ordinary session recency and reorder churn leave the glyph, target and boundary stable")
    func recencyDoesNotSwitchProvider() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        for tick in 0..<30 {
            var roster = sessions(tick)
            if tick.isMultiple(of: 2) { roster.reverse() }
            core.apply(.state(CoreState(generation: tick, sessions: roster)))
            #expect(store.screenBarWings.left?.provider == "claude")
            #expect(store.screenBarFocus.clickSession == "claude:a")
            #expect(store.nextAskAgeTick(now: clock) == 103)
            clock += 0.05
        }
        clock = 103
        #expect(store.screenBarWings.left?.provider == "codex")
        #expect(store.screenBarFocus.focusSession == "codex:a")
        #expect(store.screenBarFocus.clickSession == "codex:a")
    }

    @Test("repeated identical feeds keep the turn boundary when clock reads advance during scheduling")
    func feedSchedulingUsesOneClockReading() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = {
            clock += 0.001
            return clock
        }
        for tick in 0...12 {
            clock = 100 + Double(tick) * 0.5
            core.apply(.state(CoreState(generation: tick, sessions: sessions())))
            let expectedProvider = tick < 6 || tick == 12 ? "claude" : "codex"
            let expectedBoundary = tick < 6 ? 103.001 : tick < 12 ? 106.001 : 109.001
            let boundary = store.nextAskAgeTick()
            #expect(boundary.map { abs($0 - expectedBoundary) < 0.00001 } == true)
            #expect(store.screenBarWings.left?.provider == expectedProvider)
            #expect(store.screenBarWings.left?.workingActivity == true)
            #expect(store.screenBarFocus.clickSession == "\(expectedProvider):a")
        }
    }

    @Test("five providers hosted by T3 keep their backend identities and turns")
    func t3HostDoesNotCollapseProviders() throws {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        let origin = try JSONDecoder().decode(CoreOrigin.self, from:
            Data(#"{"kind":"app","label":"T3 Code","bundle_id":"com.t3tools.t3code"}"#.utf8))
        let providers = ["claude", "codex", "gemini", "grok", "opencode"]
        let roster = providers.map { provider in
            CoreSession(id: "\(provider):t3-fixture", provider: provider, label: "Fixture work", mode: "working", origin: origin)
        }
        for turn in 0..<5 {
            clock = 100 + Double(turn * 3)
            core.apply(.state(CoreState(generation: turn, sessions: Array(roster.reversed()))))
            #expect(store.screenBarWings.left?.provider == providers[turn])
            #expect(store.screenBarFocus.clickSession == "\(providers[turn]):t3-fixture")
        }
    }

    @Test("another session of the same provider does not replace its chosen session or create another turn")
    func duplicateProviderSessions() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        core.apply(.state(CoreState(sessions: sessions())))
        #expect(store.screenBarFocus.focusSession == "claude:a")
        let another = CoreSession(id: "claude:0", provider: "claude", label: "New Claude work", mode: "working", since: 999)
        core.apply(.state(CoreState(sessions: [another] + sessions(1))))
        #expect(store.screenBarFocus.focusSession == "claude:a")
        clock = 103
        #expect(store.screenBarFocus.style?.id == "codex")
        clock = 106
        #expect(store.screenBarFocus.style?.id == "claude")
    }

    @Test("an unanswered ask and a failure retain priority over the working cycle")
    func urgencyWins() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        core.apply(.state(CoreState(sessions: sessions())))
        _ = store.screenBarWings
        let ask = CoreAsk(session: "codex:ask", openedAt: 90, summary: "Run tests?", answerable: true, request: "fixture-request")
        let asking = CoreSession(id: "codex:ask", provider: "codex", label: "Waiting work", ask: ask)
        let failed = CoreSession(id: "gemini:failed", provider: "gemini", label: "Failed work", mode: "failed", updatedAt: 200, failureSignalUntil: 205)
        clock = 200
        core.apply(.state(CoreState(sessions: sessions() + [asking, failed], asks: [ask])))
        #expect(store.screenBarWings.left?.provider == "codex")
        #expect(store.screenBarFocus.focusSession == "codex:ask")
        #expect(store.screenBarWings.left?.workingActivity == false)
        #expect(store.screenBarFocus.clickSession == "codex:ask")
        core.apply(.state(CoreState(sessions: sessions() + [failed])))
        #expect(store.screenBarFocus.focusSession == "gemini:failed")
        #expect(store.screenBarWings.left?.workingActivity == false)
        #expect(store.nextAskAgeTick(now: clock) == 205)
        clock = 205
        #expect(store.screenBarFocus.focusSession != "gemini:failed")
        #expect(store.screenBarWings.left?.workingActivity == true)
    }

    @Test("a manually selected working session is never overridden by a provider turn")
    func manualTargetWins() {
        let core = makeCore()
        var clock = 100.0
        let store = PanelStore(core: core, screenBarShown: false)
        store.providerClock = { clock }
        core.apply(.state(CoreState(sessions: sessions())))
        store.isOpen = true
        store.selectedID = "codex:a"
        for advance in [0.0, 3, 6, 30] {
            clock = 100 + advance
            #expect(store.screenBarFocus.focusSession == "codex:a")
            #expect(store.screenBarFocus.clickSession == "codex:a")
            #expect(store.nextAskAgeTick(now: clock) == nil)
        }
    }

    @Test("a pinned Notch header keeps its chosen session while incoming provider focus changes")
    func pinnedTargetWins() throws {
        let suite = ScratchDefaults.suiteName("NotchProviderFocusTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        let noBattery = AlcovePowerState(hasBattery: false, onAC: false, charging: false, percent: nil, fullyCharged: false)
        let card = NotchCardModel(timers: ShelfTimerModel(storeURL: url, schedulingEnabled: false),
            tray: ShelfTrayModel(defaults: defaults), utility: ShelfUtilityModel(power: noBattery), runtimeEnabled: false)
        let claude = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "Claude work", word: "Working",
                                   clickSession: "claude:a", focusSession: "claude:a")
        let codex = ScreenBarFocus(style: ProviderStyle.style(for: "codex"), label: "Codex work", word: "Working",
                                  clickSession: "codex:a", focusSession: "codex:a")
        let rows = [NotchIslandRow(id: "claude:a", label: "Claude work", provider: "claude", activity: .working),
                    NotchIslandRow(id: "codex:a", label: "Codex work", provider: "codex", activity: .working)]
        card.adoptFocus(claude, rows: rows)
        card.pinned = true
        card.adoptFocus(codex, rows: rows)
        #expect(card.focus.focusSession == "claude:a")
        #expect(card.focus.clickSession == "claude:a")
        card.pinned = false
        card.adoptFocus(codex, rows: rows)
        #expect(card.focus.focusSession == "codex:a")
    }
}
