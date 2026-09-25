import Foundation
import Observation
import Testing
@testable import JRBarCore

/// What a `CoreModel` change wakes. Every `state` frame replaces the
/// whole document, so a reader that only needs one fact must not be
/// woken by the rest: these tests count observer fires, never time.
@Suite("CoreModel observation")
@MainActor
struct CoreModelObservationTests {
    final class Tripped: @unchecked Sendable { var fired = false }

    /// Whether `change` wakes an observer that ran `read`.
    func wakes(_ read: () -> Void, when change: () -> Void) -> Bool {
        let tripped = Tripped()
        withObservationTracking(read) { tripped.fired = true }
        change()
        return tripped.fired
    }

    static func session(_ id: String, mode: String = "working") -> CoreSession {
        CoreSession(id: id, provider: "claude", kind: "main", mode: mode)
    }

    static func state(_ generation: Int, sessions: [CoreSession] = [session("claude:a")]) -> CoreState {
        CoreState(generation: generation, now: 1_790_000_000 + Double(generation), sessions: sessions)
    }

    @Test("isLive flips on connect, the first state and a disconnect")
    func liveFlips() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        #expect(core.isLive == false)
        core.handle(.connected)
        #expect(core.isLive == false, "connected, but no state yet")
        core.apply(.state(Self.state(1)))
        #expect(core.isLive)
        core.handle(.disconnected(reason: "gone"))
        #expect(core.isLive == false)
        core.handle(.connecting(attempt: 1))
        #expect(core.isLive == false)
        core.handle(.connected)
        core.handle(.message(.state(Self.state(2))))
        #expect(core.isLive)
        core.stop()
        #expect(core.isLive == false, "an idle client is not live even with a state kept")
    }

    @Test("a state frame does not wake a reader of isLive once live")
    func livePushIsQuiet() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        #expect(wakes({ _ = core.isLive }, when: { core.apply(.state(Self.state(1))) }),
                "the first state makes the monitor live")
        #expect(!wakes({ _ = core.isLive }, when: { core.apply(.state(Self.state(2))) }),
                "a second state changes nothing isLive says")
        #expect(wakes({ _ = core.isLive }, when: { core.handle(.disconnected(reason: "gone")) }))
    }
}
