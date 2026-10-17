import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Effect Studio load recovery")
struct EffectStudioLoadTests {
    @Test("a failed initial load has a durable reason and permits another load")
    func failureSurvivesToast() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-effects-recovery.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = EffectStudioStore(core: core)
        let firstLoad = try #require(store.reload())
        await firstLoad.value
        let reason = try #require(store.loadError)
        #expect(!store.loading)
        #expect(store.catalog == nil)
        #expect(store.assignments == nil)
        store.lastError = nil
        #expect(store.loadError == reason)
        let retry = try #require(store.reload())
        #expect(store.loading)
        #expect(store.loadError == nil)
        await retry.value
        #expect(!store.loading)
        #expect(store.loadError == reason)
    }
}
