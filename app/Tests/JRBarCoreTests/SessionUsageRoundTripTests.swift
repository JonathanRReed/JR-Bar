import Foundation
import Testing
@testable import JRBarCore

/// X15 end to end: the monitor's `session_usage` carries each session's
/// `window_tokens` (tokens since its provider's primary usage window
/// opened) and the client hands it to the Agent Overview's window share,
/// null staying nil. The mock answers as the daemon does
/// (`src/jrbar/session_usage.py`; `tests/test_session_usage.py` holds the
/// two to the same keys).
@Suite("session_usage round trip", .serialized)
struct SessionUsageRoundTripTests {
    @Test("window_tokens reaches the client, and null stays nil")
    @MainActor
    func windowTokens() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }

        let claude = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
        let worker = claude + ":worker:1"
        let codex = "codex:session:0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c"
        let gemini = "gemini:session:8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a"
        let document = try await model.sessionUsage(ids: [claude, worker, codex, gemini, "ghost"])

        #expect(document.sessions[claude]?.windowTokens == 340_000)
        #expect(document.sessions[worker]?.windowTokens == 60_000)
        #expect(document.sessions[codex] != nil)
        #expect(document.sessions[codex]?.windowTokens == nil)
        #expect(document.gaps[gemini] == "unsupported_provider")
        #expect(document.gaps["ghost"] == "not_found")
        #expect(document.sessions[claude]?.tokensSince == nil, "no since asked, no tokens_since")
    }
}
