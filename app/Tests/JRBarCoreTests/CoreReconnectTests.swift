import Foundation
import Testing
@testable import JRBarCore

/// A daemon restart must never hand the app the dead daemon's asks: the
/// socket dropping clears the facts it carried, and a new socket stays
/// not-live until the new daemon sends its own state.
@Suite("Core reconnect")
@MainActor
struct CoreReconnectTests {
    static func liveModel() -> CoreModel {
        let model = CoreModel(socketPath: "/nonexistent/jrbar-test.sock")
        model.handle(.connected)
        model.apply(.hello(CoreHello(coreVersion: "old", pid: 1)))
        model.apply(.settings(CoreSettings(generation: 3)))
        model.apply(.lights(CoreLights()))
        model.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:a", provider: "claude", mode: "waiting")],
            asks: [CoreAsk(session: "claude:a", kind: "permission", summary: "Run", answerable: true)])))
        return model
    }

    @Test("a dropped socket clears the dead daemon's asks, rows and lights")
    func disconnectClears() {
        let model = Self.liveModel()
        #expect(model.isLive)
        #expect(model.openAsks.count == 1)

        model.handle(.disconnected(reason: "eof"))
        #expect(!model.isLive)
        #expect(model.openAsks.isEmpty)
        #expect(model.sessions.isEmpty)
        #expect(model.lights == nil)
        #expect(model.lastStateAt == nil)
        #expect(model.stateAge() == nil)
        #expect(model.settings?.generation == 3, "the settings document outlives the socket")
    }

    @Test("a reconnect before the first state is not live, and forgets the old hello")
    func reconnectWaitsForState() {
        let model = Self.liveModel()
        model.handle(.disconnected(reason: "eof"))
        model.handle(.connecting(attempt: 1))
        model.handle(.connected)
        #expect(model.connection.isConnected)
        #expect(!model.isLive, "connected without a state is not live")
        #expect(model.hello == nil, "the old daemon's version is not the new one's")
        #expect(model.openAsks.isEmpty)

        model.apply(.state(CoreState(sessions: [], asks: [])))
        #expect(model.isLive)
    }
}
