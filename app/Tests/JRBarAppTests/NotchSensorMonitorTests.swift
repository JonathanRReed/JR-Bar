import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The island's sensor poller. The reads themselves are real — a test
/// machine's mic and camera state isn't ours to fake — so what is
/// pinned is the contract around them: reads never throw or hang,
/// start polls immediately, and stop always leaves the monitor quiet.
@Suite("Notch sensor monitor")
@MainActor
struct NotchSensorMonitorTests {
    @Test("the reads answer without opening a device")
    func readsAreSafe() {
        // Values depend on the machine — the contract is that asking
        // is free, honest, and captureless.
        _ = NotchSensorMonitor.microphoneInUse()
        _ = NotchSensorMonitor.cameraInUse()
        let snapshot = NotchSensorMonitor.read()
        #expect(snapshot.dotCount == (snapshot.cameraInUse ? 1 : 0)
                    + (snapshot.microphoneInUse ? 1 : 0))
    }

    @Test("the dot and the card's names count the same processes")
    func namesFollowTheDot() {
        typealias Client = MicrophoneCapture.Client
        let own: pid_t = 100
        let clients = [
            Client(pid: own, runningInput: true, microphoneDevices: 1),   // JR-Bar's own tap
            Client(pid: 200, runningInput: true, microphoneDevices: 1),   // the call
            Client(pid: 300, runningInput: true, microphoneDevices: 0),   // a visualizer's tap
            Client(pid: 400, runningInput: false, microphoneDevices: 0),  // music through AirPods
        ]
        #expect(MicrophoneCapture.capturing(clients, ownPID: own) == [200])
        #expect(MicrophoneCapture.isLive(clients, ownPID: own))
        // A headset that is only playing, beside a tap, is no call and
        // names nobody — the device-wide read called this a live mic.
        let quiet = Array(clients.dropFirst(2))
        #expect(MicrophoneCapture.capturing(quiet, ownPID: own).isEmpty)
        #expect(!MicrophoneCapture.isLive(quiet, ownPID: own))
    }

    @Test("the live names never include this process")
    func ownProcessNeverNamed() {
        // Read-only against the real audio system: whatever else is
        // capturing, JR-Bar's own tap is not a microphone.
        #expect(!NotchSensorMonitor.microphoneClientPIDs().contains(getpid()))
        #expect(!MicrophoneCapture.capturingPIDs().contains(getpid()))
    }

    @Test("start polls now, stop releases the timer and reports quiet")
    func lifecycle() {
        let monitor = NotchSensorMonitor()
        #expect(!monitor.running)
        monitor.start()
        #expect(monitor.running)
        monitor.stop()
        #expect(!monitor.running)
        #expect(monitor.state == NotchSensorState(),
                "a stopped monitor never leaves a stale dot")
        // Restarting is a fresh baseline — the first poll after it
        // lands whatever the hardware says, live or not.
        monitor.start()
        #expect(monitor.running)
        monitor.stop()
    }

    @Test("start arms the system listeners, stop removes every one")
    func listeners() {
        let monitor = NotchSensorMonitor()
        monitor.start()
        // The default-input and camera-list listeners register on any
        // Mac; the per-device ones depend on its hardware.
        #expect(monitor.armedListenerCount >= 2)
        monitor.stop()
        #expect(monitor.armedListenerCount == 0)
        monitor.stop()   // a second stop is harmless
        #expect(monitor.armedListenerCount == 0)
    }

    @Test("under the ears nothing watches the mic unless another surface asks")
    func drawableGate() {
        #expect(NotchToy.sensorsDrawable(earsDrawn: false, wantedElsewhere: false),
                "no ears: the island's own shoulders draw the dots")
        #expect(!NotchToy.sensorsDrawable(earsDrawn: true, wantedElsewhere: false),
                "a bare housing draws no dots, so nothing listens")
        #expect(NotchToy.sensorsDrawable(earsDrawn: true, wantedElsewhere: true))

        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        toy.screenBarShown = { false }
        #expect(toy.sensorsDrawable, "no bar, no ears")
    }

    @Test("the toggle's default is on and the toy honours the write")
    func toggleDefault() {
        let key = NotchToy.sensorIndicatorsDefaultsKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar,
                                    islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        #expect(toy.sensorIndicatorsEnabled,
                "absent key reads as on — the honest default")
        toy.sensorIndicatorsEnabled = false
        #expect(UserDefaults.standard.bool(forKey: key) == false)
        #expect(toy.sensorState == NotchSensorState(),
                "turning it off clears whatever dots were showing")
    }
}
