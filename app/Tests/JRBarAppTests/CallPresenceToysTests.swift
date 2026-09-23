import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The call fact reaches the toys: the reporter's edge is the one the
/// delegate hands `ToysStore.noteCallPresence`, so a camera going live
/// holds Confetti's burst and the call's end plays it smaller — from the
/// app's own reading, or from the daemon's presence alone.
@Suite("Call presence in the toys")
@MainActor
struct CallPresenceToysTests {
    private final class Bursts { var fired: [Double] = [] }

    private func makeRoom() -> (PresenceReporter, ToysStore, Bursts, (CorePresence?) -> Void) {
        let core = CoreModel()
        var state = ToysState()
        state.confetti.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let bursts = Bursts()
        store.confetti.screensForBurst = { [nil] }
        store.confetti.presentOverride = { _, density in bursts.fired.append(density) }
        final class Daemon { var presence: CorePresence? }
        let daemon = Daemon()
        let reporter = PresenceReporter(isConnected: { false }, presence: { daemon.presence },
                                        send: { _ in true })
        // The delegate's wiring, exactly.
        reporter.onCallChanged = { [weak store] in store?.noteCallPresence($0) }
        return (reporter, store, bursts, { daemon.presence = $0; reporter.coreChanged() })
    }

    @Test("a live camera holds the burst; the call's end plays it smaller")
    func cameraHolds() {
        let (reporter, store, bursts, _) = makeRoom()
        reporter.noteSensors(NotchSensorState(cameraInUse: true))
        #expect(store.onCall)
        #expect(store.hushReason() == .call)
        #expect(store.confetti.fire(reason: .trigger, provider: "claude", at: Date()))
        #expect(bursts.fired.isEmpty, "held while on a call")
        #expect(store.confetti.status == .paused("Holding a burst — on a call"))
        reporter.noteSensors(NotchSensorState())
        #expect(!store.onCall)
        #expect(bursts.fired == [ConfettiRoom.replayDensity])
    }

    @Test("the daemon's call fact hushes the toys on its own")
    func daemonFact() throws {
        let (reporter, store, _, setPresence) = makeRoom()
        setPresence(try JSONDecoder().decode(CorePresence.self,
                                             from: Data(#"{"on_call":true,"celebrations_held":true}"#.utf8)))
        #expect(store.hushReason() == .call)
        setPresence(nil)
        #expect(store.hushReason() == nil)
        _ = reporter
    }
}
