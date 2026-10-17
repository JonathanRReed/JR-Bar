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

    @Test("stop keeps cached facts but reconnect waits for its own state")
    func stoppedReconnectWaitsForState() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(Self.state(1)))
        core.apply(.lights(CoreLights()))
        let retiredGeneration = core.eventGeneration
        core.stop()
        #expect(!core.isLive)
        #expect(core.state?.generation == 1)
        #expect(core.sessions.map(\.id) == ["claude:a"])
        #expect(core.lights != nil)

        core.handle(.connecting(attempt: 1))
        core.handle(.connected)
        #expect(!core.isLive, "a cached state cannot make the replacement connection live")
        core.handle(.message(.state(Self.state(3))), generation: retiredGeneration)
        #expect(!core.isLive, "a queued state from the retired client cannot prove readiness")
        #expect(core.state?.generation == 1)
        #expect(wakes({ _ = core.isLive }, when: {
            core.handle(.message(.state(Self.state(2))))
        }))
        #expect(core.isLive)
    }

    @Test("a state received before connection does not prove readiness")
    func idleStateDoesNotProveReadiness() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.message(.state(Self.state(1))))
        #expect(!core.isLive)
        core.handle(.connected)
        #expect(!core.isLive)
        core.handle(.message(.state(Self.state(2))))
        #expect(core.isLive)
    }

    @Test("a replacement connection invalidates its predecessor's state")
    func replacementConnectionWaitsForState() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.handle(.message(.state(Self.state(1))))
        #expect(wakes({ _ = core.isLive }, when: { core.handle(.connected) }))
        #expect(!core.isLive)
        #expect(core.state?.generation == 1)
        core.handle(.message(.state(Self.state(2))))
        #expect(core.isLive)
    }

    @Test("rejected states wake readiness readers and keep the last good facts")
    func rejectedStateWakesReadiness() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.handle(.message(.state(Self.state(1))))
        #expect(wakes({ _ = core.isLive }, when: {
            core.handle(.stateRejected("unreadable state"))
        }))
        #expect(!core.isLive)
        #expect(core.connection.isConnected)
        #expect(core.state?.generation == 1)
        #expect(core.sessions.map(\.id) == ["claude:a"])
        #expect(wakes({ _ = core.isLive }, when: {
            core.handle(.message(.state(Self.state(2))))
        }))
        #expect(core.isLive)
        #expect(wakes({ _ = core.isLive }, when: {
            core.handle(.message(.unknown(type: "state", version: CoreProtocol.version + 1)))
        }))
        #expect(!core.isLive)
        #expect(core.state?.generation == 2)
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
    @Test("durable reset reoffers use only the receipt callback after first arrival")
    func durableResetReplayCallback() throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        var events: [String] = []
        var reoffers: [String] = []
        core.onEvent = { events.append($0.id) }
        core.onResetReplay = { reoffers.append($0.id) }
        let hello = try JSONDecoder().decode(CoreHello.self, from: Data(
            #"{"v":1,"core_version":"test","pid":1,"capabilities":[],"stream":"synthetic-stream","cursor":"synthetic-stream:ev-0"}"#.utf8))
        core.apply(.hello(hello))
        let reset = CoreEvent(id: "synthetic-reset", kind: "quota_reset", notify: false,
                              provider: "kimi", lane: "monthly", eventId: "synthetic-reset")
        #expect(reset.isDurableResetReplay)
        core.apply(.event(reset))
        let sequence = core.eventSequence
        let recent = core.recentEvents
        core.apply(.event(reset))
        #expect(events == ["synthetic-reset"])
        #expect(reoffers == ["synthetic-reset"])
        #expect(core.eventSequence == sequence && core.recentEvents == recent)

        core.handle(.disconnected(reason: "synthetic reconnect"))
        core.apply(.hello(hello))
        core.apply(.event(reset))
        #expect(events == ["synthetic-reset"])
        #expect(reoffers == ["synthetic-reset", "synthetic-reset"])
        let ordinary = CoreEvent(id: "ev-1", kind: "completed", cursor: "synthetic-stream:ev-1")
        core.apply(.event(ordinary))
        core.apply(.event(ordinary))
        #expect(events == ["synthetic-reset", "ev-1"])
        #expect(reoffers.count == 2)
    }

    @Test("only silent cursor-free stable reset facts qualify as durable reoffers")
    func durableResetReplayShape() {
        let reset = CoreEvent(id: "stable", kind: "quota_reset", notify: false, eventId: "stable")
        #expect(reset.isDurableResetReplay)
        var candidates: [CoreEvent] = []
        var edited = reset
        edited.cursor = "stream:ev-1"; candidates.append(edited)
        edited = reset; edited.notify = nil; candidates.append(edited)
        edited = reset; edited.notify = true; candidates.append(edited)
        edited = reset; edited.eventId = " "; candidates.append(edited)
        edited = reset; edited.eventId = nil; candidates.append(edited)
        edited = reset; edited.id = "different"; candidates.append(edited)
        edited = reset; edited.kind = "completed"; candidates.append(edited)
        #expect(candidates.allSatisfy { !$0.isDurableResetReplay })
    }

}
