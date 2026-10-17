import Foundation
import Testing
@testable import JRBarCore

/// `dismiss_ask` against the mock core: an ask the daemon calls stale is
/// dismissed and leaves `state.asks`; a session with no ask is refused.
/// The mock stands in for the daemon's contract (docs/CORE-PROTOCOL.md).
@Suite("Dismissing a stale ask against the mock", .serialized)
struct MockDismissAskRoundTripTests {
    @Test("a stale ask says so, dismisses, and the agent is told nothing")
    @MainActor
    func staleAskDismisses() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--stale-ask"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.isLive && !(model.state?.asks.isEmpty ?? true) })

        let ask = try #require(model.state?.asks.first)
        #expect(ask.isStale && ask.isDismissible)
        #expect(ask.canAnswer, "stale or not, it is answerable where it was")
        let now = Date()
        #expect(ask.staleLine(now: now)?.hasPrefix("may be stale · asked 8 hours ago") == true)
        #expect((model.state?.aggregate.needsYou ?? 0) >= 1, "still counted as needing the person")

        let session = try #require(ask.session)
        let reply = try await model.dismissAsk(session: session, request: ask.request)
        #expect(reply.ok)
        #expect(reply.result?["dismissed"]?.boolValue == true)
        #expect(await MockCoreIntegrationTests.wait { model.state?.asks.isEmpty == true })
    }

    @Test("a session with no open ask has nothing to dismiss")
    @MainActor
    func nothingToDismiss() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.isLive && model.state != nil })

        // No ask is open on the mock's quiet start: nothing to dismiss.
        let missing = try await model.dismissAsk(session: "codex:session:none")
        #expect(!missing.ok)
        #expect(missing.error?.code == "not_found")
    }
}
