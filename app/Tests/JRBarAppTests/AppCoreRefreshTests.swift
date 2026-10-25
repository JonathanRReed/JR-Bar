import Foundation
import Observation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("App refresh dependencies")
@MainActor
struct AppCoreRefreshTests {
    @Test("ten thousand clock and health frames do not fan out to app refreshers")
    func calmFrames() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        core.handle(.connected)
        var refresh = AppCoreRefresh()
        core.apply(.state(CoreState(generation: 1)))
        #expect(refresh.take(core) == .all)
        var calls = 0
        for generation in 2...10_001 {
            core.apply(.state(CoreState(generation: generation, now: Double(generation),
                                       health: .object(["age": .number(Double(generation))]))))
            calls += refresh.take(core).rawValue.nonzeroBitCount
        }
        #expect(calls == 0)
        core.apply(.state(CoreState(generation: 10_002, sessions: [
            CoreSession(id: "fixture", provider: "claude", mode: "working")
        ])))
        #expect(refresh.take(core) == .roster)
        core.apply(.settings(CoreSettings(generation: 1, document: .object([:]))))
        #expect(refresh.take(core) == .settings)
        core.apply(.lights(CoreLights()))
        #expect(refresh.take(core) == .lights)
        core.handle(.disconnected(reason: "fixture"))
        #expect(refresh.take(core).contains(.connection))
    }

    @Test("health frames do not rearm the app observation")
    func observationStaysCalm() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { AppDelegate.observedAppFacts(core) } onChange: { flag.fired = true }
        for generation in 1...10_000 {
            core.apply(.state(CoreState(generation: generation, now: Double(generation))))
        }
        #expect(!flag.fired)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude")])))
        #expect(flag.fired)
    }

    @Test("device and quota changes keep their own refreshers")
    func usage() {
        let core = CoreModel(socketPath: "/tmp/jrbar-refresh-unused.sock")
        var refresh = AppCoreRefresh()
        core.apply(.state(CoreState()))
        _ = refresh.take(core)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude")]))))
        #expect(refresh.take(core) == .usage)
    }
}
