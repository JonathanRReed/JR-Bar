import Foundation
import Testing
@testable import JRBarCore

/// Fix sign-in, Update and the update check, end to end through the real client
/// against the mock daemon. Nothing here touches a provider tool or the network:
/// the mock answers from a table, as the daemon's own tests do with fake tools.
@Suite("Mock core provider round trips", .serialized)
struct MockProviderRoundTripTests {
    @Test("Fix sign-in answers with the daemon's own sentence")
    @MainActor
    func signIn() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "86400"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }

        let grok = try await model.signInProvider("grok")
        #expect(grok.outcome == .openedTerminal)
        #expect(grok.command == "grok login")
        #expect(grok.message.hasPrefix("Opened Ghostty on `grok login`"))
        #expect(grok.provider == "grok")

        let claude = try await model.signInProvider("claude")
        #expect(claude.outcome == .renewed)
        #expect(claude.command == nil)

        let devin = try await model.signInProvider("devin")
        #expect(devin.outcome == .unavailable)
        #expect(devin.signInURL == "https://app.devin.ai")

        await #expect(throws: CoreReplyError.self) { _ = try await model.signInProvider("nonsense") }
    }

    @Test("Update returns at once and the result lands in the state")
    @MainActor
    func update() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "86400"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }
        #expect(model.providerUpdates.isEmpty, "nothing has run, so nothing is said")

        let start = try await model.updateProvider("claude")
        #expect(start.started)
        let finished = await MockCoreIntegrationTests.wait { model.providerUpdates["claude"]?.phase == .updated }
        #expect(finished, "the daemon's worker reports a phase change")
        let record = try #require(model.providerUpdates["claude"])
        #expect(record.fromVersion == "2.1.285")
        #expect(record.toVersion == "2.1.290")
        #expect(record.message == "Updated 2.1.285 to 2.1.290")
        #expect(record.finishedAt != nil)

        // Gemini CLI has no updater: a sentence to show, and no state to read.
        let gemini = try await model.updateProvider("gemini")
        #expect(!gemini.started)
        #expect(gemini.reason == "no_updater")
        #expect(gemini.message.contains("brew upgrade gemini-cli"))
        #expect(model.providerUpdates["gemini"] == nil)
        await #expect(throws: CoreReplyError.self) { _ = try await model.updateProvider("nonsense") }
    }

    @Test("the update check asks nothing until the setting is on")
    @MainActor
    func updateCheck() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "86400"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }

        // Off by default: the daemon says so and nothing is offered.
        let off = try await model.send("provider_update_check")
        #expect(off.result?["enabled"]?.boolValue == false)
        #expect(off.result?["started"]?.boolValue == false)
        #expect(model.providerUpdates["claude"]?.latestVersion == nil)
        #expect(model.settings?.document["provider_update_checks_enabled"]?.boolValue == false)

        _ = try await model.setSetting("provider_update_checks_enabled", value: .bool(true))
        let on = try await model.send("provider_update_check")
        #expect(on.result?["enabled"]?.boolValue == true)
        let offered = await MockCoreIntegrationTests.wait { model.providerUpdates["claude"]?.latestVersion == "2.1.290" }
        #expect(offered, "a newer version is known once the person has turned the check on")
        #expect(model.providerUpdates["claude"]?.updateAvailable == true)
    }
}
