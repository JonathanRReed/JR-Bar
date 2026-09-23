import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Confetti minds the room: the one `fire(reason:)` entry point, the
/// hold while a call or quiet has the room, the smaller replay once it
/// clears, and fullscreen screens skipped. The overlay windows are
/// replaced by a counter, so nothing lands on the test machine's screen.
@Suite("Confetti room")
@MainActor
struct ConfettiRoomTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Bursts {
        var fired: [(screens: Int, density: Double)] = []
    }

    private func makeToy(enabled: Bool = true, freeScreens: Int = 1)
        -> (ConfettiToy, ToysStore, Bursts) {
        let core = CoreModel()
        var state = ToysState()
        state.confetti.enabled = enabled
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy = store.confetti
        let bursts = Bursts()
        toy.screensForBurst = { Array(repeating: nil, count: freeScreens) }
        toy.presentOverride = { screens, density in bursts.fired.append((screens, density)) }
        return (toy, store, bursts)
    }

    @Test("the card's test fires even while the toy is off")
    func testAlwaysFires() {
        let (toy, store, bursts) = makeToy(enabled: false)
        #expect(toy.fire(reason: .test, at: t0))
        #expect(bursts.fired.count == 1)
        _ = store
    }

    @Test("an outside request needs the toy on, and a loop is not a strobe")
    func requestIsGatedAndCooled() {
        let (off, offStore, offBursts) = makeToy(enabled: false)
        #expect(off.fire(reason: .request, at: t0) == false)
        #expect(offBursts.fired.isEmpty)
        let (toy, store, bursts) = makeToy()
        #expect(toy.fire(reason: .request, provider: "codex", at: t0))
        #expect(toy.fire(reason: .request, at: t0.addingTimeInterval(1)) == false,
                "inside the cooldown")
        #expect(toy.fire(reason: .request, at: t0.addingTimeInterval(ConfettiRoom.requestCooldown)))
        #expect(bursts.fired.count == 2)
        _ = (offStore, store)
    }

    @Test("a daemon-relayed confetti event is an outside request")
    func relayedRequest() {
        let (toy, store, bursts) = makeToy()
        toy.noteEvent(CoreEvent(id: "e1", kind: ConfettiToy.requestEventKind, provider: "codex"))
        #expect(bursts.fired.count == 1)
        toy.noteEvent(CoreEvent(id: "e2", kind: ConfettiToy.requestEventKind))
        #expect(bursts.fired.count == 1, "the request cooldown holds for relayed asks too")
        let (off, offStore, offBursts) = makeToy(enabled: false)
        off.noteEvent(CoreEvent(id: "e3", kind: ConfettiToy.requestEventKind))
        #expect(offBursts.fired.isEmpty)
        _ = (store, offStore)
    }

    @Test("a milestone needs its trigger ticked")
    func milestoneNeedsTrigger() {
        let (toy, store, bursts) = makeToy()
        #expect(toy.fire(reason: .milestone, at: t0) == false)
        store.state.confetti.triggers.milestones = true
        #expect(toy.fire(reason: .milestone, at: t0))
        #expect(bursts.fired.count == 1)
    }

    @Test("a call holds the burst, and it plays smaller once the call ends")
    func callHoldsThenReplays() {
        let (toy, store, bursts) = makeToy()
        store.noteCallPresence(true)
        // Held now: the call's end re-checks at the real clock.
        #expect(toy.fire(reason: .trigger, provider: "claude", at: Date()))
        #expect(bursts.fired.isEmpty, "held, not fired")
        #expect(toy.held?.why == .call)
        #expect(toy.status == .paused("Holding a burst — on a call"))
        store.noteCallPresence(false)
        #expect(toy.held == nil)
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first?.density == ConfettiRoom.replayDensity)
    }

    @Test("let go means let go")
    func dropWhenHeld() {
        let (toy, store, bursts) = makeToy()
        store.state.confetti.whenHeld = .drop
        store.noteCallPresence(true)
        toy.fire(reason: .trigger, at: t0)
        #expect(toy.held == nil)
        store.noteCallPresence(false)
        #expect(bursts.fired.isEmpty)
    }

    @Test("a hold older than the limit is dropped, not replayed")
    func staleHoldDrops() {
        let (toy, store, bursts) = makeToy()
        store.noteCallPresence(true)
        toy.fire(reason: .trigger, at: t0)
        #expect(toy.held != nil)
        store.noteCallPresence(false)   // re-checks at the real clock,
        // years past t0, so the burst is old news.
        #expect(toy.held == nil)
        #expect(bursts.fired.isEmpty)
    }

    @Test("with the page's switch off the room is ignored")
    func switchOffIgnoresTheRoom() {
        let (toy, store, bursts) = makeToy(freeScreens: 0)
        store.state.hushDuringQuiet = false
        store.noteCallPresence(true)
        toy.fire(reason: .trigger, at: t0)
        #expect(bursts.fired.count == 1, "fires on every screen, as it always did")
        #expect(toy.held == nil)
    }

    @Test("every screen fullscreen holds; a free screen gets the burst alone")
    func fullscreenScreens() {
        let (toy, store, bursts) = makeToy(freeScreens: 0)
        toy.fire(reason: .trigger, at: Date())
        #expect(toy.held?.why == .fullscreen)
        toy.screensForBurst = { [nil] }
        toy.roomChanged()
        #expect(toy.held == nil)
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first?.screens == 1)
        _ = store
    }

    @Test("switching the toy off lets a held burst go")
    func offDropsHeld() {
        let (toy, store, bursts) = makeToy()
        store.noteCallPresence(true)
        toy.fire(reason: .trigger, at: Date())
        #expect(toy.held != nil)
        toy.isOn = false
        #expect(toy.held == nil)
        store.noteCallPresence(false)
        #expect(bursts.fired.isEmpty)
    }

    @Test("the daemon's own \"off\" is a clear room: bursts fire and the buddy hops")
    func daemonOffIsClear() throws {
        let core = CoreModel()
        // What a connected daemon sends while nothing quiet is in effect
        // (docs/CORE-PROTOCOL.md): the literal `off`, never null.
        let off = try JSONDecoder().decode(CoreFocus.self, from: Data(#"""
            {"mode": "off", "source": null, "until": null}
            """#.utf8))
        core.apply(.state(CoreState(focus: off)))
        var state = ToysState()
        state.confetti.enabled = true
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        #expect(store.state.hushDuringQuiet, "the default switch")
        #expect(store.hushReason() == nil)
        let toy = store.confetti
        let bursts = Bursts()
        toy.screensForBurst = { [nil] }
        toy.presentOverride = { screens, density in bursts.fired.append((screens, density)) }
        #expect(toy.fire(reason: .trigger, provider: "claude", at: t0))
        #expect(toy.held == nil, "presented, not held")
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first?.density == 1)
        let buddy = store.notchBuddy
        buddy.noteEvent(CoreEvent(id: "c1", kind: "completed", session: "s"), at: t0)
        #expect(buddy.hopUntil == t0.addingTimeInterval(1.1))
    }

    @Test("hushed, the buddy eats its crumb without the hop")
    func buddyKeepsItsHop() {
        let core = CoreModel()
        var state = ToysState()
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        store.noteCallPresence(true)
        let buddy = store.notchBuddy
        buddy.noteEvent(CoreEvent(id: "c1", kind: "completed", session: "s"), at: t0)
        #expect(buddy.hopUntil == nil)
        #expect(buddy.crumbAt == t0)
        #expect(store.state.notchBuddy.care.crumbsEaten == 1)
        store.noteCallPresence(false)
        buddy.noteEvent(CoreEvent(id: "c2", kind: "completed", session: "s"), at: t0)
        #expect(buddy.hopUntil == t0.addingTimeInterval(1.1))
    }
}

/// The burst's optional voice, synthesized: short, normalized under
/// full scale, fading to silence, and a well-formed WAV.
@Suite("Confetti sound")
@MainActor
struct ConfettiSoundTests {
    @Test("the mix is short, quiet and ends in silence")
    func mixShape() {
        let samples = ConfettiSound.samples(sampleRate: 22_050)
        #expect(samples.count == Int(ConfettiSound.duration * 22_050))
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(abs(Double(peak) - ConfettiSound.gain) < 1e-4)
        #expect(abs(samples.last ?? 1) < 1e-6)
        #expect(ConfettiSound.samples(sampleRate: 22_050) == samples, "deterministic")
    }

    @Test("the WAV header describes 16-bit mono PCM")
    func wavHeader() {
        let data = ConfettiSound.wav(from: [0, 0.5, -0.5], sampleRate: 8_000)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
    }
}
