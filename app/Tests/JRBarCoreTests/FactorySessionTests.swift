import Foundation
import Testing
@testable import JRBarCore

@Suite("Factory browser-session commands", .serialized)
struct FactorySessionTests {
    @MainActor
    @Test("browser connection commands preserve profile, confirmation and selected account across the socket")
    func roundTrip() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "86400"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let core = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { core.stop() }
        let profiles = try await core.factorySessionProfiles()
        let selected = try #require(profiles.first)
        #expect(profiles.count == 1)
        #expect(selected.browser == "zen")
        #expect(selected.profile == "synthetic.default")
        let imported = try await core.importFactorySession(selected, instance: "work")
        #expect(imported == "Imported Factory browser sign-in for work.")
        let disconnected = try await core.disconnectFactorySession(instance: "work")
        #expect(disconnected == "Factory browser sign-in removed.")
        do {
            _ = try await core.importFactorySession(selected, instance: "wrong-reply")
            Issue.record("a reply naming another account was accepted")
        } catch { #expect((error as? CoreReplyError)?.code == "bad_reply") }
        let unconfirmed = try await core.send("factory_session_import", args: [
            "browser": .string(selected.browser), "profile": .string(selected.profile),
            "instance": .string("work"),
        ])
        #expect(!unconfirmed.ok)
        #expect(unconfirmed.error?.code == "invalid_args")
    }

    @MainActor
    @Test("offline browser operations fail without claiming a connection")
    func offline() async {
        let core = CoreModel()
        await #expect(throws: CoreClientError.notConnected) { try await core.factorySessionProfiles() }
        await #expect(throws: CoreClientError.notConnected) {
            try await core.importFactorySession(.init(browser: "zen", profile: "synthetic.default", label: "Zen"), instance: "work")
        }
        await #expect(throws: CoreClientError.notConnected) { try await core.disconnectFactorySession(instance: "work") }
    }
}
