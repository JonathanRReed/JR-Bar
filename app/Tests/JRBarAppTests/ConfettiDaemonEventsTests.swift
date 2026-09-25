import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The daemon's two routes into the burst, end to end through the toy: a
/// `confetti` event (`jrbar confetti`, a hook, CI) is an outside request,
/// and a `milestone` event (the odometer crossing a step) is a trigger
/// under the Milestones switch. Overlays are replaced by a counter.
@Suite("Confetti from the daemon")
@MainActor
struct ConfettiDaemonEventsTests {
    private final class Bursts {
        var fired: [ConfettiPresentation] = []
    }

    /// A connected daemon with nothing quiet in effect (`focus.mode` "off").
    private func makeToy(enabled: Bool = true, milestones: Bool = false) throws -> (ConfettiToy, ToysStore, Bursts) {
        let core = CoreModel()
        let off = try JSONDecoder().decode(CoreFocus.self, from: Data(#"{"mode": "off", "source": null, "until": null}"#.utf8))
        core.apply(.state(CoreState(focus: off)))
        var state = ToysState()
        state.confetti.enabled = enabled
        state.confetti.triggers.milestones = milestones
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy = store.confetti
        let bursts = Bursts()
        toy.screensForBurst = { [nil] }
        toy.presentOverride = { bursts.fired.append($0) }
        return (toy, store, bursts)
    }

    private func event(_ json: String) throws -> CoreEvent {
        try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8))
    }

    @Test("a journaled confetti request bursts once, and a repeat inside the cooldown does not")
    func requestEvent() throws {
        let (toy, store, bursts) = try makeToy()
        toy.noteEvent(try event(#"{"id":"ev-1","kind":"confetti","provider":"codex","cursor":"s:ev-1"}"#))
        #expect(bursts.fired.count == 1)
        toy.noteEvent(try event(#"{"id":"ev-2","kind":"confetti","cursor":"s:ev-2"}"#))
        #expect(bursts.fired.count == 1, "one burst per cooldown, however eager the script")
        _ = store
    }

    @Test("a request never fires while the toy is off; only the card's test does")
    func requestNeedsTheToy() throws {
        let (toy, store, bursts) = try makeToy(enabled: false)
        toy.noteEvent(try event(#"{"id":"ev-1","kind":"confetti"}"#))
        #expect(bursts.fired.isEmpty)
        _ = store
    }

    @Test("an odometer milestone bursts under the Milestones trigger, once per crossing")
    func milestoneEvent() throws {
        let milestone = try event(#"{"id":"ev-7","kind":"milestone","provider":"claude","count":50,"cursor":"s:ev-7"}"#)
        let (quiet, quietStore, quietBursts) = try makeToy()
        quiet.noteEvent(milestone)
        #expect(quietBursts.fired.isEmpty, "the Milestones trigger is opt-in")
        _ = quietStore

        let (toy, store, bursts) = try makeToy(milestones: true)
        toy.noteEvent(milestone)
        #expect(bursts.fired.count == 1)
        #expect(store.state.confetti.firedKeys.contains("event:s:ev-7"))
        toy.noteEvent(milestone)
        #expect(bursts.fired.count == 1, "a replayed crossing is already in the ring")
    }
}
