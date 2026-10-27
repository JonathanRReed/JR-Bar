import JRBarTestSupport
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The reporter between the notch's sensor monitor and the daemon: what
/// it sends and when, whether it asks the monitor to run, and the call
/// fact it hands the toys. The daemon is a closure that records.
@Suite("Presence reporter", .temporaryDirectory, .timeLimit(.minutes(2)))
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
        await presence.sendTask?.value
        #expect(daemon.sent == [CorePresenceReport(mic: true, camera: false)])
        presence.noteSensors(NotchSensorState(microphoneInUse: true, cameraInUse: true))
        await presence.sendTask?.value
        presence.noteSensors(NotchSensorState())
        await presence.sendTask?.value
        #expect(daemon.sent.map(\.camera) == [false, true, false])
        #expect(daemon.sent.last?.sensingCall == false, "the call's end is said, not left to go stale")
        // Nothing more is owed for a quiet reading.
        await presence.sendTask?.value
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
        await presence.sendTask?.value
        // The daemon's frames keep coming; none of them is a reason to
        // repeat the report inside the minute.
        for _ in 0..<5 {
            clock.now += 10
            presence.coreChanged()
        }
        await presence.sendTask?.value
        #expect(daemon.sent.count == 1)
        clock.now += 11
        presence.coreChanged()
        await presence.sendTask?.value
        #expect(daemon.sent.count == 2)
        #expect(daemon.sent.filter { !$0.mic }.isEmpty)
    }

    @Test("the Focus rides the first report, and a Focus edge goes at once")
    func focusEdges() async {
        let daemon = FakeDaemon()
        final class Focus { var on: Bool? = true }
        let focus = Focus()
        let presence = PresenceReporter(isConnected: { daemon.connected }, presence: { nil },
                                        send: { daemon.sent.append($0); return true },
                                        readFocus: { focus.on })
        daemon.connected = true
        presence.coreChanged()
        await presence.sendTask?.value
        #expect(daemon.sent == [CorePresenceReport(focus: true)])
        presence.focusMayHaveChanged()
        await presence.sendTask?.value
        #expect(daemon.sent.count == 1, "an unchanged Focus owes nothing inside the minute")
        focus.on = false
        presence.focusMayHaveChanged()
        await presence.sendTask?.value
        #expect(daemon.sent.last == CorePresenceReport(focus: false))
        focus.on = nil
        presence.focusMayHaveChanged()
        await presence.sendTask?.value
        #expect(daemon.sent.last?.arguments["focus"] == nil, "access withdrawn: the key goes, the daemon reads its own")
    }

    @Test("a reconnect sends the reading again, even a quiet one")
    func reconnect() async {
        let daemon = FakeDaemon()
        let presence = reporter(daemon)
        daemon.connected = true
        presence.coreChanged()
        await presence.sendTask?.value
        daemon.connected = false
        presence.coreChanged()
        daemon.connected = true
        presence.coreChanged()
        await presence.sendTask?.value
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
        presence.ownCameraDelay = { _ in }
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        await presence.sendTask?.value
        // A slow runner may renew the report before the next step; every
        // report so far still leaves the person's own look out.
        #expect(!daemon.sent.isEmpty)
        #expect(daemon.sent.allSatisfy { $0 == CorePresenceReport(mic: false, camera: false) })
        #expect(!presence.onCall, "the toys stay awake for the person's own look")
        // The Mirror closes while another app still holds the lens: the
        // device flag has no edge, so the close itself looks again. Wait
        // for that report itself, not for a count a renewal can reach.
        daemon.mirror = false
        presence.ownCameraChanged()
        let held = CorePresenceReport(mic: false, camera: true)
        await presence.ownCameraSettling?.value
        await presence.sendTask?.value
        #expect(daemon.sent.last == held)
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
        await presence.sendTask?.value
        // Closed: the flag still reads the Mirror's session for a beat,
        // then drops.
        daemon.mirror = false
        presence.ownCameraChanged()
        await presence.sendTask?.value
        presence.noteSensors(NotchSensorState())
        await presence.sendTask?.value
        #expect(daemon.sent.allSatisfy { !$0.camera }, "no call the length of a stopRunning")
        #expect(heard.isEmpty)
        // A camera another app starts after the beat is a call at once.
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        await presence.sendTask?.value
        #expect(daemon.sent.last?.camera == true)
        #expect(heard == [true])
    }

    @Test("a card's Mirror is watched: asked for on a pinned card, the lens is ours")
    func mirrorOnACard() async {
        let suite = ScratchDefaults.suiteName("presence-mirror")
        defer { ScratchDefaults.remove(suite) }
        let timers = ShelfTimerModel(storeURL: TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-presence-timers-\(UUID().uuidString).json"))
        let mirror = ShelfMirrorModel(driver: ShelfMirrorStateTests.Driver(), authorization: { .authorized })
        let noBattery = AlcovePowerState(hasBattery: false, onAC: false, charging: false,
                                         percent: nil, fullyCharged: false)
        let card = NotchCardModel(timers: timers, tray: ShelfTrayModel(defaults: ScratchDefaults.open(suite)),
                                 utility: ShelfUtilityModel(power: noBattery), mirror: mirror, runtimeEnabled: false)
        card.mirrorEnabled = { true }
        let presence = PresenceReporter(core: CoreModel(), cards: { [card] })
        let callChanges = TestEvents<Bool>()
        presence.onCallChanged = { callChanges.send($0) }
        presence.noteSensors(NotchSensorState(cameraInUse: true))
        #expect(presence.onCall, "no Mirror: a live camera is someone's call")
        #expect(!PresenceReporter.mirrorHasCamera(card))
        card.pinned = true
        card.summonMirror()
        mirror.sync(enabled: true)
        // Summoned before its session is up: the lens can light first.
        #expect(PresenceReporter.mirrorHasCamera(card))
        _ = try? await callChanges.next(where: { !$0 })
        #expect(!presence.onCall, "the Mirror's own lens, seen without a sensor edge")
        card.pinned = false
        mirror.sync(enabled: false)
        #expect(!PresenceReporter.mirrorHasCamera(card), "folding the card puts the lens away")
    }

    @Test("waiting for permission does not claim another app's live camera")
    func permissionWaitingIsNotSelfCapture() {
        let suite = ScratchDefaults.suiteName("presence-mirror-permission")
        defer { ScratchDefaults.remove(suite) }
        let mirror = ShelfMirrorModel(driver: ShelfMirrorStateTests.Driver(), authorization: { .notDetermined },
                                     requestAccess: { _ in })
        let noBattery = AlcovePowerState(hasBattery: false, onAC: false, charging: false,
                                         percent: nil, fullyCharged: false)
        let card = NotchCardModel(timers: ShelfTimerModel(storeURL: TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-presence-timers-\(UUID().uuidString).json")),
                                 tray: ShelfTrayModel(defaults: ScratchDefaults.open(suite)),
                                 utility: ShelfUtilityModel(power: noBattery),
                                 mirror: mirror, runtimeEnabled: false)
        card.pinned = true
        card.mirrorEnabled = { true }
        card.summonMirror()
        mirror.sync(enabled: true)
        #expect(mirror.state == .requestingPermission)
        #expect(!PresenceReporter.mirrorHasCamera(card))
        mirror.sync(enabled: false)
        card.pinned = false
    }
}

/// The Focus re-read's cache: a granted answer is asked for once a minute,
/// not on every 15 s beat.
@Suite("Focus read cache", .temporaryDirectory)
@MainActor
struct FocusReadCacheTests {
    /// The clock and the two system probes, counted.
    final class Probes {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var authorized = true
        var focused: Bool? = false
        var authorizationReads = 0
        var focusReads = 0
    }

    private func read(_ cache: FocusReadCache, _ probes: Probes) -> Bool? {
        cache.read(authorized: { probes.authorizationReads += 1; return probes.authorized },
                   focused: { probes.focusReads += 1; return probes.focused })
    }

    @Test("a granted answer is asked for once a minute, the Focus on every read")
    func grantedAnswerLives() {
        let probes = Probes()
        let cache = FocusReadCache(clock: { probes.now })
        for beat in 0..<4 {
            probes.now = Date(timeIntervalSince1970: 1_800_000_000 + Double(beat) * 15)
            probes.focused = beat >= 2
            #expect(read(cache, probes) == (beat >= 2))
        }
        #expect(probes.authorizationReads == 1)
        #expect(probes.focusReads == 4)

        probes.now = Date(timeIntervalSince1970: 1_800_000_000 + FocusReadCache.authorizationLifetime)
        _ = read(cache, probes)
        #expect(probes.authorizationReads == 2, "the minute's end asks the system again")
    }

    @Test("not being authorized is asked every time and reads nothing")
    func deniedIsNotRemembered() {
        let probes = Probes()
        probes.authorized = false
        let cache = FocusReadCache(clock: { probes.now })
        #expect(read(cache, probes) == nil)
        #expect(read(cache, probes) == nil)
        #expect(probes.authorizationReads == 2)
        #expect(probes.focusReads == 0)

        probes.authorized = true
        probes.focused = true
        #expect(read(cache, probes) == true, "a grant just given is seen at the next beat")
    }

    @Test("forgetting asks the system at the next read")
    func forgetting() {
        let probes = Probes()
        let cache = FocusReadCache(clock: { probes.now })
        _ = read(cache, probes)
        probes.authorized = false
        cache.forget()
        #expect(read(cache, probes) == nil)
        #expect(probes.authorizationReads == 2)
    }
}
