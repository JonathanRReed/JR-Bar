import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The reporter between the notch's sensor monitor and the daemon: what
/// it sends and when, whether it asks the monitor to run, and the call
/// fact it hands the toys. The daemon is a closure that records.
@Suite("Presence reporter")
@MainActor
struct PresenceReporterTests {
    /// The daemon side: connected or not, its presence document, and
    /// every report it was sent.
    final class FakeDaemon {
        var connected = false
        var presence: CorePresence?
        var takes = true
        var sent: [CorePresenceReport] = []
        /// JR-Bar's own Mirror has the camera.
        var mirror = false
    }

    private func reporter(_ daemon: FakeDaemon) -> PresenceReporter {
        PresenceReporter(isConnected: { daemon.connected },
                         presence: { daemon.presence },
                         send: { report in
                             daemon.sent.append(report)
                             return daemon.takes
                         })
    }

    /// Lets the send tasks run.
    private func settle(_ until: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !until(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("the monitor runs for the report exactly while the daemon is there")
    func demand() {
        let daemon = FakeDaemon()
        let presence = reporter(daemon)
        var demandChanges = 0
        presence.onDemandChanged = { demandChanges += 1 }
        #expect(!presence.wantsSensors)
        daemon.connected = true
        presence.coreChanged()
        #expect(presence.wantsSensors)
        #expect(demandChanges == 1)
        presence.coreChanged()
        #expect(demandChanges == 1, "only a real change re-syncs the monitor")
        daemon.connected = false
        presence.coreChanged()
        #expect(!presence.wantsSensors)
        #expect(demandChanges == 2)
    }

    @Test("a connection sends the reading, then each edge, in order")
    func edges() async {
        let daemon = FakeDaemon()
        let presence = reporter(daemon)
        presence.noteSensors(NotchSensorState(microphoneInUse: true))
        #expect(daemon.sent.isEmpty, "nothing goes while the daemon is away")
        daemon.connected = true
        presence.coreChanged()
        await settle { daemon.sent.count == 1 }
        #expect(daemon.sent == [CorePresenceReport(mic: true, camera: false)])
        presence.noteSensors(NotchSensorState(microphoneInUse: true, cameraInUse: true))
        await settle { daemon.sent.count == 2 }
        presence.noteSensors(NotchSensorState())
        await settle { daemon.sent.count == 3 }
        #expect(daemon.sent.map(\.camera) == [false, true, false])
        #expect(daemon.sent.last?.sensingCall == false, "the call's end is said, not left to go stale")
        // Nothing more is owed for a quiet reading.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(daemon.sent.count == 3)
    }

    @Test("a live call is renewed on the minute, and state frames between add nothing")
    func renewal() async {
        let daemon = FakeDaemon()
        daemon.connected = true
        final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let presence = PresenceReporter(isConnected: { daemon.connected }, presence: { nil },
                                        send: { daemon.sent.append($0); return true },
                                        clock: { clock.now })
        presence.noteSensors(NotchSensorState(microphoneInUse: true))
        await settle { daemon.sent.count == 1 }
        // The daemon's frames keep coming; none of them is a reason to
        // repeat the report inside the minute.
        for _ in 0..<5 {
            clock.now += 10
            presence.coreChanged()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(daemon.sent.count == 1)
        clock.now += 11
        presence.coreChanged()
        await settle { daemon.sent.count == 2 }
        #expect(daemon.sent.count == 2)
        #expect(daemon.sent.filter { !$0.mic }.isEmpty)
    }

    @Test("a reconnect sends the reading again, even a quiet one")
    func reconnect() async {
        let daemon = FakeDaemon()
        let presence = reporter(daemon)
        daemon.connected = true
        presence.coreChanged()
        await settle { daemon.sent.count == 1 }
        daemon.connected = false
        presence.coreChanged()
        daemon.connected = true
        presence.coreChanged()
        await settle { daemon.sent.count == 2 }
        #expect(daemon.sent.count == 2)
        #expect(daemon.sent.allSatisfy { !$0.sensingCall })
    }

    @Test("the toys hear the call from the reading, and from the daemon's fact")
    func callFact() throws {
        let daemon = FakeDaemon()
        let presence = reporter(daemon)
        var heard: [Bool] = []
        presence.onCallChanged = { heard.append($0) }
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        #expect(presence.onCall)
        presence.noteSensors(NotchSensorState())
        #expect(!presence.onCall)
        daemon.presence = try JSONDecoder().decode(CorePresence.self, from: Data(#"{"on_call":true}"#.utf8))
        presence.coreChanged()
        #expect(presence.onCall)
        presence.coreChanged()
        #expect(heard == [true, false, true], "edges only")
    }

    /// A reporter whose Mirror is a switch the test flips.
    private func mirrored(_ daemon: FakeDaemon, grace: TimeInterval) -> PresenceReporter {
        PresenceReporter(isConnected: { daemon.connected },
                         presence: { daemon.presence },
                         send: { report in
                             daemon.sent.append(report)
                             return daemon.takes
                         },
                         ownCameraLive: { daemon.mirror },
                         ownCameraGrace: grace)
    }

    @Test("JR-Bar's own Mirror is not a call, and a lens still held after it closes is")
    func ownMirror() async {
        let daemon = FakeDaemon()
        daemon.connected = true
        daemon.mirror = true
        let presence = mirrored(daemon, grace: 0.05)
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        await settle { daemon.sent.count == 1 }
        #expect(daemon.sent == [CorePresenceReport(mic: false, camera: false)])
        #expect(!presence.onCall, "the toys stay awake for the person's own look")
        // The Mirror closes while another app still holds the lens: the
        // device flag has no edge, so the close itself looks again.
        daemon.mirror = false
        presence.ownCameraChanged()
        await settle { daemon.sent.count == 2 }
        #expect(daemon.sent.last == CorePresenceReport(mic: false, camera: true))
        #expect(presence.onCall)
    }

    @Test("the beat while the Mirror's session winds down reports no call")
    func ownMirrorWindsDown() async {
        let daemon = FakeDaemon()
        daemon.connected = true
        daemon.mirror = true
        let presence = mirrored(daemon, grace: 60)
        var heard: [Bool] = []
        presence.onCallChanged = { heard.append($0) }
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        await settle { daemon.sent.count == 1 }
        // Closed: the flag still reads the Mirror's session for a beat,
        // then drops.
        daemon.mirror = false
        presence.ownCameraChanged()
        try? await Task.sleep(nanoseconds: 50_000_000)
        presence.noteSensors(NotchSensorState())
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(daemon.sent.allSatisfy { !$0.camera }, "no call the length of a stopRunning")
        #expect(heard.isEmpty)
        // A camera another app starts after the beat is a call at once.
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        await settle { daemon.sent.count == 2 }
        #expect(daemon.sent.last?.camera == true)
        #expect(heard == [true])
    }

    @Test("a card's Mirror is watched: asked for on a pinned card, the lens is ours")
    func mirrorOnACard() async {
        let timers = ShelfTimerModel(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-presence-timers-\(UUID().uuidString).json"))
        let card = NotchCardModel(timers: timers, tray: ShelfTrayModel(), runtimeEnabled: false)
        card.mirrorEnabled = { true }
        let presence = PresenceReporter(core: CoreModel(), cards: { [card] })
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        #expect(presence.onCall, "no Mirror: a live camera is someone's call")
        #expect(!PresenceReporter.mirrorHasCamera(card))
        card.pinned = true
        card.summonMirror()
        // Summoned before its session is up: the lens can light first.
        #expect(PresenceReporter.mirrorHasCamera(card))
        await settle { !presence.onCall }
        #expect(!presence.onCall, "the Mirror's own lens, seen without a sensor edge")
        card.pinned = false
        #expect(!PresenceReporter.mirrorHasCamera(card), "folding the card puts the lens away")
    }
}
