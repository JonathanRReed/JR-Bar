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

    @Test("a slice is assigned only when its part of the frame changed")
    func slicesAssignOnChange() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        let usage = CoreUsage(providers: [CoreProviderUsage(id: "claude")])
        func frame(_ generation: Int, sessions: [CoreSession], health: Double) -> CoreMessage {
            .state(CoreState(generation: generation, now: 1_790_000_000 + Double(generation),
                             sessions: sessions, usage: usage,
                             health: .object(["sources": .object(["claude": .object([
                                 "heard_age_seconds": .number(health)])])])))
        }
        let a = [Self.session("claude:a")]
        core.apply(frame(1, sessions: a, health: 1))
        #expect(!wakes({ _ = core.sessions; _ = core.usage }, when: { core.apply(frame(2, sessions: a, health: 2)) }),
                "a new generation and a health age leave the sessions and usage alone")
        #expect(wakes({ _ = core.health }, when: { core.apply(frame(3, sessions: a, health: 3)) }))
        let b = [Self.session("claude:a", mode: "waiting")]
        #expect(wakes({ _ = core.sessions }, when: { core.apply(frame(4, sessions: b, health: 3)) }))
        #expect(!wakes({ _ = core.usage }, when: { core.apply(frame(5, sessions: a, health: 3)) }))
        #expect(core.sessions.map(\.mode) == ["working"])
        #expect(wakes({ _ = core.sessions }, when: { core.handle(.disconnected(reason: "gone")) }))
        #expect(core.sessions.isEmpty && core.usage.isEmpty, "a disconnect clears the slices with the state")
    }

    @Test("main sessions are filtered once per frame, workers kept apart")
    func mainSessionsSplit() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        let worker = CoreSession(id: "claude:w", provider: "claude", kind: "worker", parent: "claude:a")
        core.apply(.state(CoreState(generation: 1, sessions: [Self.session("claude:a"), worker])))
        #expect(core.sessions.map(\.id) == ["claude:a"])
        #expect(core.allSessions.map(\.id) == ["claude:a", "claude:w"])
    }

    @Test("a source's age is measured from heard_at when the daemon sends it")
    func heardAtAge() {
        let health: JSONValue = .object(["sources": .object([
            "claude": .object(["fresh": .bool(false), "heard_at": .number(1_790_000_000),
                               "heard_age_seconds": .number(12)]),
            "codex": .object(["fresh": .bool(true), "heard_age_seconds": .number(7)]),
        ])])
        let state = CoreState(now: 1_790_000_030, health: health)
        #expect(state.sourceHealth(for: "claude")?.heardAgeSeconds == 30, "against the document's own now")
        #expect(state.sourceHealth(for: "claude", now: 1_790_000_300)?.heardAgeSeconds == 300,
                "and against the caller's clock, which keeps counting between frames")
        #expect(state.sourceHealth(for: "codex", now: 1_790_000_300)?.heardAgeSeconds == 7,
                "an older daemon's age is read as sent")
        #expect(state.sourceHealth(for: "claude")?.fresh == false)
    }
}
