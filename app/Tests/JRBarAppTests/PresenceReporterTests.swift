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
}
