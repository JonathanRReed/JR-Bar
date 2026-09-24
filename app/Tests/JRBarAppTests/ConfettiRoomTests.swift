import AppKit
import Foundation
import SwiftUI
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
        var fired: [ConfettiPresentation] = []
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
        toy.presentOverride = { bursts.fired.append($0) }
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
        #expect(bursts.fired.first?.densityScale == ConfettiRoom.replayDensity)
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
        toy.presentOverride = { bursts.fired.append($0) }
        #expect(toy.fire(reason: .trigger, provider: "claude", at: t0))
        #expect(toy.held == nil, "presented, not held")
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first?.densityScale == 1)
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

    /// sRGB components, so two colours built different ways compare.
    private func same(_ a: Color, _ b: Color) -> Bool {
        let x = NSColor(a).usingColorSpace(.sRGB) ?? .black
        let y = NSColor(b).usingColorSpace(.sRGB) ?? .black
        return abs(x.redComponent - y.redComponent) < 0.002
            && abs(x.greenComponent - y.greenComponent) < 0.002
            && abs(x.blueComponent - y.blueComponent) < 0.002
    }

    @Test("a trigger with no provider wears the Toys tint, not the unknown grey")
    func providerlessTriggerIsNotGrey() {
        let (toy, store, bursts) = makeToy()
        store.state.confetti.triggers.sessionCompleted = true
        toy.noteEvent(CoreEvent(id: "done-1", kind: "completed"))
        #expect(bursts.fired.count == 1)
        #expect(bursts.fired.first.map { same($0.tint, ConfettiView.toysTint) } == true)
    }

    @Test("a held burst replays smaller even at the lowest density")
    func replayIsSmallerAtLowDensity() {
        let (toy, store, bursts) = makeToy()
        store.state.confetti.density = 0.5
        store.noteCallPresence(true)
        toy.fire(reason: .trigger, at: Date())
        store.noteCallPresence(false)
        let full = ConfettiView.pieceCount(settings: store.state.confetti)
        #expect(bursts.fired.count == 1)
        #expect((bursts.fired.first?.pieces ?? .max) < full,
                "the replay throws fewer pieces than a live burst at the same density")
    }

    @Test("Try it wears the focused session's colour, the one the link picks")
    func tryItUsesTheFocusedProvider() {
        let (toy, store, bursts) = makeToy(enabled: false)
        store.focusedProvider = { "codex" }
        toy.testBurst()
        store.focusedProvider = { nil }
        toy.testBurst()
        #expect(bursts.fired.count == 2)
        #expect(bursts.fired.first.map { same($0.tint, ProviderStyle.style(for: "codex").accent) } == true)
        #expect(bursts.fired.last.map { same($0.tint, ConfettiView.toysTint) } == true)
    }

    @Test("the pop goes through Settings › Sounds, at its volume")
    func popFollowsTheSoundsVolume() throws {
        let (toy, store, _) = makeToy()
        store.state.confetti.sound = true
        let player = SoundPlayer()
        player.preferences = {
            var preferences = SoundPreferences()
            preferences.volume = 0.3
            return preferences
        }
        player.microphoneLive = { false }
        player.synthesizedFolder = FileManager.default.temporaryDirectory
            .appending(path: "confetti-sound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: player.synthesizedFolder) }
        var plays: [SoundPlayer.SynthesizedPlay] = []
        player.synthesizedOutput = { plays.append($0) }
        toy.sounds = player
        toy.fire(reason: .test, at: t0)
        let play = try #require(plays.first)
        #expect(abs(Double(play.volume) - 0.3) < 1e-6)
        #expect(SoundPlayer.pitchSteps.contains(play.rate))
        #expect(FileManager.default.fileExists(atPath: play.file.path))
        store.state.confetti.sound = false
        toy.fire(reason: .test, at: t0)
        #expect(plays.count == 1, "Sound off plays nothing")
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

    private func makePlayer(volume: Double, quietOnCalls: Bool = true, micLive: Bool) -> (SoundPlayer, Box) {
        let player = SoundPlayer()
        player.preferences = {
            var preferences = SoundPreferences()
            preferences.volume = volume
            preferences.quietOnCalls = quietOnCalls
            return preferences
        }
        player.microphoneLive = { micLive }
        player.synthesizedFolder = FileManager.default.temporaryDirectory
            .appending(path: "confetti-sound-\(UUID().uuidString)")
        let box = Box()
        player.synthesizedOutput = { box.plays.append($0) }
        player.onHeldForCall = { box.held.append($0) }
        return (player, box)
    }

    final class Box {
        var plays: [SoundPlayer.SynthesizedPlay] = []
        var held: [String] = []
    }

    @Test("a synthesized sound plays at the Sounds volume times its own gain")
    func gainIsVolumeTimesBase() throws {
        let (player, box) = makePlayer(volume: 0.3, micLive: false)
        defer { try? FileManager.default.removeItem(at: player.synthesizedFolder) }
        let play = try #require(player.playSynthesized(ConfettiSound.wavData, key: "pop", gain: 0.5,
                                                       rate: 1.05, pan: 0.4))
        #expect(abs(Double(play.volume) - 0.15) < 1e-6)
        #expect(play.rate == 1.04 || play.rate == 1.06, "the nearest pitch step")
        #expect(abs(Double(play.pan) - 0.4) < 1e-6)
        #expect(box.plays == [play])
        // The file is written once, then only read.
        let written = try #require(try? Data(contentsOf: play.file))
        #expect(written.count == ConfettiSound.wavData.count)
        let again = try #require(player.playSynthesized(ConfettiSound.wavData, key: "pop", gain: 0.5,
                                                        rate: 1.05))
        #expect(again.file == play.file)
    }

    @Test("a live microphone holds the pop while sounds keep quiet on calls")
    func heldOnALiveMic() {
        let (player, box) = makePlayer(volume: 1, micLive: true)
        defer { try? FileManager.default.removeItem(at: player.synthesizedFolder) }
        #expect(player.playSynthesized(ConfettiSound.wavData, key: "pop") == nil)
        #expect(box.plays.isEmpty && box.held == ["pop"])
        let (open, openBox) = makePlayer(volume: 1, quietOnCalls: false, micLive: true)
        defer { try? FileManager.default.removeItem(at: open.synthesizedFolder) }
        #expect(open.playSynthesized(ConfettiSound.wavData, key: "pop") != nil)
        #expect(openBox.plays.count == 1)
    }

    @Test("a pitch step rewrites the WAV's rates, so the pitch moves with the speed")
    func retimedMovesThePitch() throws {
        let wav = ConfettiSound.wav(from: [0, 0.5, -0.5], sampleRate: 10_000)
        let faster = try #require(SoundPlayer.retimed(wav, rate: 1.06))
        func rate(_ data: Data, _ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * UInt32($1)) }
        }
        #expect(rate(faster, 24) == 10_600)
        #expect(rate(faster, 28) == 21_200)
        #expect(faster[44...] == wav[44...], "the samples themselves are untouched")
        #expect(SoundPlayer.retimed(Data("not a wav".utf8), rate: 1.02) == nil)
        #expect(SoundPlayer.pitchStep(0.5) == 0.94)
        #expect(SoundPlayer.pitchStep(1.3) == 1.06)
        #expect(SoundPlayer.pitchStep(1.004) == 1.0)
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
