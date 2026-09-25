import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The buddy's energy budget: the session list is reduced once per
/// document, not once per frame, and the timeline draws at 30 fps while
/// anything moves and a slow breath's worth while nothing does.
@Suite("Buddy pacing")
@MainActor
struct BuddyPacingTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeToy() -> (NotchBuddyToy, ToysStore, CoreModel) {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        return (store.notchBuddy, store, core)
    }

    private func working(_ id: String, provider: String = "claude") -> CoreSession {
        CoreSession(id: id, provider: provider, mode: "tool_running", lifecycle: "active")
    }

    @Test("asleep draws at four frames a second, awake at thirty")
    func restingAndActiveRates() {
        #expect(NotchBuddyToy.frameInterval(awake: true, lively: false, dragged: false, scale: 1)
                == 1.0 / 30.0)
        #expect(NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: 1)
                == 0.25)
        #expect(NotchBuddyToy.frameInterval(awake: false, lively: true, dragged: false, scale: 1)
                == 1.0 / 30.0, "a trick or a hop plays at the full rate")
        #expect(NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: true, scale: 1)
                == 1.0 / 30.0, "a carried buddy dangles at the full rate")
    }

    @Test("a bigger floating buddy breathes at a finer rate, never past thirty")
    func restingRateGrowsWithSize() {
        let small = NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: 1)
        let big = NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: 3)
        #expect(big < small)
        #expect(abs(big - 1.0 / 12.0) < 1e-9)
        #expect(NotchBuddyToy.frameInterval(awake: false, lively: false, dragged: false, scale: .nan)
                == 0.25, "a broken scale reads as the docked size")
        #expect(big > NotchBuddyToy.activeInterval)
    }

    @Test("the digest follows a new document at once, not on the next frame")
    func digestFollowsDocuments() {
        let (toy, store, core) = makeToy()
        #expect(toy.summary(at: t0).working == 0)
        #expect(toy.frameInterval(scale: 1) == 0.25)
        core.apply(.state(CoreState(generation: 1, sessions: [working("a"), working("b", provider: "codex")])))
        let busy = toy.summary(at: t0)
        #expect(busy.working == 2)
        #expect(busy.mood == .pacing)
        #expect(busy.workingProvider == nil, "two providers split the work")
        #expect(toy.frameInterval(scale: 1) == NotchBuddyToy.activeInterval)
        core.apply(.state(CoreState(generation: 2, sessions: [])))
        #expect(toy.summary(at: t0).working == 0)
        #expect(toy.frameInterval(scale: 1) == 0.25)
        _ = store
    }

    /// Waits, bounded, for the toy to follow the last document: the
    /// follow hops onto the main actor after the document lands.
    private func followed(_ toy: NotchBuddyToy, past version: Int) async {
        var tries = 0
        while toy.digestVersion == version, tries < 2_000 {
            await Task.yield()
            tries += 1
        }
    }

    @Test("falling asleep holds the full rate while the mood hands over")
    func fallingAsleepIsLively() async throws {
        let (toy, store, core) = makeToy()
        _ = toy.sessionDigest()     // arms the document observation
        var version = toy.digestVersion
        core.apply(.state(CoreState(generation: 1, sessions: [working("a")])))
        await followed(toy, past: version)
        #expect(toy.summary(at: Date()).mood == .pacing)
        #expect(toy.livelyUntil == nil, "waking needs no beat: awake is the full rate already")

        version = toy.digestVersion
        let asleepAt = Date()
        core.apply(.state(CoreState(generation: 2, sessions: [])))
        await followed(toy, past: version)
        #expect(toy.digestVersion > version)
        #expect(toy.summary(at: Date()).mood == .asleep)
        let lively = try #require(toy.livelyUntil)
        #expect(lively >= asleepAt.addingTimeInterval(BuddyHandoff.duration),
                "the handoff into sleep plays at the full rate")
        #expect(toy.frameInterval(scale: 1) == NotchBuddyToy.activeInterval)
        _ = store
    }

    @Test("an unchanged roster reuses the digest")
    func digestIsCached() {
        let (toy, store, core) = makeToy()
        core.apply(.state(CoreState(generation: 1, sessions: [working("a")])))
        let first = toy.sessionDigest()
        let second = toy.sessionDigest()
        #expect(first == second)
        #expect(first.working == 1)
        #expect(first.focus?.id == "a")
        _ = store
    }

    @Test("views hear about a document through the version bump")
    func digestVersionBumps() async throws {
        let (toy, store, core) = makeToy()
        _ = toy.sessionDigest()
        let before = toy.digestVersion
        core.apply(.state(CoreState(generation: 1, sessions: [working("a")])))
        try await Task.sleep(for: .milliseconds(30))
        #expect(toy.digestVersion > before)
        #expect(toy.sessionDigest().working == 1)
        _ = store
    }

    @Test("a tap keeps the timeline lively for the beat, then lets it rest")
    func beatsAreLively() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let (toy, store, _) = makeToy()
        #expect(toy.livelyUntil == nil)
        toy.tapped(at: Date())
        #expect(toy.livelyUntil != nil)
        #expect(toy.frameInterval(scale: 1) == NotchBuddyToy.activeInterval)
        try await Task.sleep(for: .seconds(NotchBuddyToy.livelyWindow + 0.3))
        #expect(toy.livelyUntil == nil)
        #expect(toy.frameInterval(scale: 1) == 0.25)
        _ = store
    }

    @Test("a completion's crumb and a treat both hold the full rate")
    func crumbAndTreatAreLively() {
        let (toy, store, _) = makeToy()
        store.state.notchBuddy.enabled = true
        toy.noteEvent(CoreEvent(id: "done-1", kind: "completed", session: "a"), at: Date())
        #expect(toy.livelyUntil != nil)
        let (fed, fedStore, _) = makeToy()
        fed.giveTreat(at: Date())
        #expect(fed.livelyUntil != nil)
        _ = (store, fedStore)
    }

    // MARK: Tempo

    private func stamped(_ id: String, at updated: Double, mode: String = "tool_running") -> CoreSession {
        CoreSession(id: id, provider: "claude", mode: mode, lifecycle: "active", updatedAt: updated)
    }

    @Test("each moved stamp on a working session is one tool event")
    func tempoCountsEvents() {
        var tempo = BuddyTempo()
        tempo.note(sessions: [stamped("a", at: 100)], now: t0)
        #expect(tempo.rate(at: t0) == 0, "a first sighting is a baseline, not a burst")
        for k in 1...8 {
            tempo.note(sessions: [stamped("a", at: 100 + Double(k))], now: t0.addingTimeInterval(Double(k)))
        }
        #expect(abs(tempo.rate(at: t0.addingTimeInterval(8)) - 8 / BuddyTempo.window) < 1e-9)
        tempo.note(sessions: [stamped("a", at: 108)], now: t0.addingTimeInterval(9))
        #expect(tempo.stamps.count == 8, "an unchanged stamp is a heartbeat, not an event")
        #expect(tempo.rate(at: t0.addingTimeInterval(9 + BuddyTempo.window)) == 0,
                "the window forgets")
    }

    @Test("an idle session's stamp moving is not tool work")
    func tempoIgnoresIdle() {
        var tempo = BuddyTempo()
        tempo.note(sessions: [stamped("a", at: 1, mode: "idle_ready")], now: t0)
        tempo.note(sessions: [stamped("a", at: 2, mode: "idle_ready")], now: t0)
        #expect(tempo.stamps.isEmpty)
    }

    @Test("the cadence runs from a stroll to a sprint, and clamps")
    func cadenceRange() {
        #expect(BuddyTempo.cadence(rate: 0) == BuddyTempo.strollCadence)
        #expect(BuddyTempo.cadence(rate: BuddyTempo.sprintRate) == BuddyTempo.sprintCadence)
        #expect(BuddyTempo.cadence(rate: 50) == BuddyTempo.sprintCadence)
        #expect(BuddyTempo.cadence(rate: .nan) == BuddyTempo.strollCadence)
        let mid = BuddyTempo.cadence(rate: BuddyTempo.sprintRate / 2)
        #expect(mid > BuddyTempo.strollCadence && mid < BuddyTempo.sprintCadence)
    }

    @Test("the walk clock only ever moves forward, faster under load")
    func walkClockAdvances() {
        let (idle, idleStore, _) = makeToy()
        let (busy, busyStore, busyCore) = makeToy()
        let start = Date()
        busyCore.apply(.state(CoreState(generation: 1, sessions: [stamped("a", at: 1)])))
        _ = busy.sessionDigest()
        for k in 2...20 {
            busyCore.apply(.state(CoreState(generation: k, sessions: [stamped("a", at: Double(k))])))
            _ = busy.sessionDigest()
        }
        let idle0 = idle.walkPhase(at: start)
        let busy0 = busy.walkPhase(at: start)
        var idleLast = idle0, busyLast = busy0
        for step in 1...40 {
            let now = start.addingTimeInterval(Double(step) * 0.1)
            let i = idle.walkPhase(at: now), b = busy.walkPhase(at: now)
            #expect(i >= idleLast && b >= busyLast)
            idleLast = i
            busyLast = b
        }
        #expect(busyLast - busy0 > idleLast - idle0, "hammered tools walk faster")
        _ = (idleStore, busyStore)
    }

    @Test("the pure digest counts, tints and picks the focus")
    func digestOfSessions() {
        let asking = CoreSession(id: "ask", provider: "codex", mode: "waiting_for_user",
                                 lifecycle: "active", nextActor: "user")
        let digest = NotchBuddyToy.digest(of: [working("a"), working("b"), asking])
        #expect(digest.working == 2)
        #expect(digest.dominantProvider == "claude")
        #expect(digest.workingProvider == "claude")
        #expect(digest.isAwake)
        #expect(NotchBuddyToy.digest(of: []).isAwake == false)
    }
}
