import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Agent watching replies")
@MainActor
struct AgentWatchingReplyTests {
    private static let session = "codex:synthetic"

    @MainActor
    private final class Replies {
        var pending: [CheckedContinuation<Bool?, Never>] = []
        var returned = 0

        func read() async -> Bool? {
            let reply = await withCheckedContinuation { pending.append($0) }
            returned += 1
            return reply
        }

        func resolve(_ index: Int, _ reply: Bool?) {
            pending[index].resume(returning: reply)
        }
    }

    @MainActor
    private final class Harness {
        let core = CoreModel()
        let replies = Replies()
        let coordinator: EventCoordinator
        var frontPID: Int32 = 41
        var soundDecisions = 0

        init() {
            core.apply(.state(Self.state(request: "r1")))
            coordinator = EventCoordinator(core: core, hudAnchor: { nil })
            coordinator.frontmostApp = { [weak self] in ("dev.jr.synthetic-terminal", self?.frontPID) }
            coordinator.sessionInFront = { [replies] _ in await replies.read() }
            // Observe the decision only. No banner, sound, hardware or daemon.
            coordinator.deliveryRules = { [weak self] delivery, _ in
                if delivery.sound != nil { self?.soundDecisions += 1 }
                return .nothing
            }
        }

        static func state(request: String) -> CoreState {
            CoreState(
                sessions: [CoreSession(id: AgentWatchingReplyTests.session, provider: "codex", mode: "waiting",
                                       terminal: CoreTerminal(app: "Synthetic", bundleId: "dev.jr.synthetic-terminal"))],
                asks: [CoreAsk(session: AgentWatchingReplyTests.session, summary: "Synthetic ask", request: request)])
        }

        func open(_ request: String = "r1") {
            coordinator.handle(CoreEvent(id: "open-\(request)", kind: "ask_opened",
                                         session: AgentWatchingReplyTests.session, request: request))
        }
    }

    /// All replies are controlled continuations. Bound actor turns rather
    /// than waiting for a timer or a wall-clock sleep.
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { break }
            await Task.yield()
        }
        try #require(condition())
        // The reader has returned; let its caller finish the same reply.
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("a current reply restores the sound when the ask is in another tab")
    func currentReply() async throws {
        let harness = Harness()
        harness.open()
        try await settle { harness.replies.pending.count == 1 }
        #expect(harness.soundDecisions == 0)
        harness.replies.resolve(0, false)
        try await settle { harness.replies.returned == 1 }
        #expect(harness.coordinator.inFrontVerdict?.inFront == false)
        #expect(harness.soundDecisions == 1)
    }

    @Test("resolution discards the pending reply even before its next state arrives")
    func resolvedReply() async throws {
        let harness = Harness()
        harness.open()
        try await settle { harness.replies.pending.count == 1 }
        harness.coordinator.handle(CoreEvent(id: "resolve", kind: "ask_resolved", session: Self.session, request: "r1"))
        harness.replies.resolve(0, false)
        try await settle { harness.replies.returned == 1 }
        #expect(harness.coordinator.inFrontVerdict == nil)
        #expect(harness.soundDecisions == 0)
    }

    @Test("a replacement ask in state makes the earlier reply obsolete")
    func replacedReply() async throws {
        let harness = Harness()
        harness.open()
        try await settle { harness.replies.pending.count == 1 }
        harness.core.apply(.state(Harness.state(request: "r2")))
        harness.replies.resolve(0, false)
        try await settle { harness.replies.returned == 1 }
        #expect(harness.coordinator.inFrontVerdict == nil)
        #expect(harness.soundDecisions == 0)
    }

    @Test("reset discards a reply from before the monitor disconnected")
    func resetReply() async throws {
        let harness = Harness()
        harness.open()
        try await settle { harness.replies.pending.count == 1 }
        harness.coordinator.reset()
        harness.replies.resolve(0, false)
        try await settle { harness.replies.returned == 1 }
        #expect(harness.coordinator.inFrontVerdict == nil)
        #expect(harness.soundDecisions == 0)
    }

    @Test("a newer frontmost check survives an older reply arriving last")
    func frontmostReplyOrder() async throws {
        let harness = Harness()
        harness.open()
        try await settle { harness.replies.pending.count == 1 }
        harness.frontPID = 42
        harness.coordinator.handle(CoreEvent(id: "stage", kind: "escalation_stage", session: Self.session, stage: 2))
        try await settle { harness.replies.pending.count == 2 }
        harness.replies.resolve(1, true)
        try await settle { harness.replies.returned == 1 }
        #expect(harness.coordinator.inFrontVerdict?.frontmostPID == 42)
        #expect(harness.coordinator.inFrontVerdict?.inFront == true)
        harness.replies.resolve(0, false)
        try await settle { harness.replies.returned == 2 }
        #expect(harness.coordinator.inFrontVerdict?.frontmostPID == 42)
        #expect(harness.coordinator.inFrontVerdict?.inFront == true)
        #expect(harness.soundDecisions == 0)
    }
}
