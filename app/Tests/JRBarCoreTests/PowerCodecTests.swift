import Foundation
import Testing
@testable import JRBarCore

@Suite("state.power decodes")
struct PowerCodecTests {
    static func state(_ json: String) throws -> CoreState {
        guard case .state(let state) = try CoreCodec.decode(frame: Data(json.utf8)) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return state
    }

    @Test("a lease, its yield and the closed-lid facts decode")
    func leaseAndLid() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":7,"aggregate":{"mode":"working"},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":true,
                  "closed_lid":{"policy":"agents","holding":true,"helper_installed":true,
                                "lid_closed":true,"sleeps_on_release":true,"last_sleep_at":null,"sleep_error":null},
                  "hold":{"state":"manual","agents":0,"active":false,"display":true,"grace_until":null,
                          "lease":{"kind":"duration","started_at":1000,"until":4600,"sessions":[],"display":true,"source":"chip"},
                          "suspended":"thermal","thermal":"serious"},
                  "last_release":{"kind":"suspended","reason":"thermal","at":2000,"duration":null}}}
        """)
        let power = try #require(state.power)
        #expect(power.keepAwake == true)
        #expect(power.closedLid?.lidClosed == true)
        #expect(power.closedLid?.sleepsOnRelease == true)
        let hold = try #require(power.hold)
        #expect(hold.isManual)
        #expect(!hold.isHeldByAgents && !hold.isOff)
        #expect(hold.suspended == "thermal")
        #expect(hold.thermal == "serious")
        #expect(hold.display == true)
        let lease = try #require(hold.lease)
        #expect(lease.source == "chip")
        #expect(lease.remaining(now: 1600) == 3000)
        #expect(lease.remaining(now: 9000) == 0)
        #expect(!lease.waitsOnAgents)
        #expect(power.lastRelease?.reason == "thermal")
        #expect(power.lastRelease?.at == 2000)
    }

    @Test("an agents lease has no countdown, and an older daemon's power still decodes")
    func agentsLeaseAndOlderDaemon() throws {
        let agents = CoreAwakeLease(kind: "agents", startedAt: 0, until: 43_200, sessions: ["claude:a"], display: false, source: "app")
        #expect(agents.waitsOnAgents)
        #expect(agents.remaining(now: 10) == nil)

        let state = try Self.state("""
        {"t":"state","v":1,"generation":1,"aggregate":{},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":false,"closed_lid":{"policy":"never","holding":false,"helper_installed":false}}}
        """)
        #expect(state.power?.hold == nil)
        #expect(state.power?.closedLid?.lidClosed == nil)
        #expect(CoreAwakeHold().isOff)
    }
}
