import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage Center offline readings")
struct UsageCenterOfflineTests {
    static func core(percentage: Double = 42, readAt: Double = 1_800_000_000) -> CoreModel {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-usage-offline.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: readAt, providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: percentage, resetsAt: readAt + 3600),
            ], fidelity: "official", state: "ready", observedAt: readAt),
        ]))))
        return core
    }

    @Test("disconnect keeps the last provider reading and its timestamp")
    func retainsReadings() {
        let core = Self.core()
        let store = UsageCenterStore(core: core)
        core.handle(.disconnected(reason: "Monitor restarted"))
        #expect(!store.isLive)
        #expect(core.usage.isEmpty)
        #expect(store.providers.first?.windows.first?.usedPct == 42)
        #expect(store.refreshedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("a new reading replaces the retained one and an empty reading removes old cards")
    func replacementAndRemoval() {
        let core = Self.core()
        let store = UsageCenterStore(core: core)
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: 1_800_000_100, providers: [
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 18),
            ], state: "ready"),
        ]))))
        store.coreDidChange()
        core.handle(.disconnected(reason: "Monitor restarted"))
        #expect(store.providers.map(\.id) == ["codex"])
        #expect(store.refreshedAt == Date(timeIntervalSince1970: 1_800_000_100))
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: []))))
        store.coreDidChange()
        core.handle(.disconnected(reason: "Monitor restarted"))
        #expect(store.providers.isEmpty)
        #expect(store.refreshedAt == nil)
    }

    @Test("without an earlier reading, an offline store has no invented providers")
    func coldOffline() {
        let store = UsageCenterStore(core: CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-offline.sock"))
        #expect(store.providers.isEmpty)
        #expect(store.refreshedAt == nil)
    }
}
