import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Usage evidence render proof", .serialized)
@MainActor
struct UsageEvidenceRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func staleAndResetCards() throws {
        let stamp: Double = 1_800_000_000
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-usage-proof.sock")
        core.handle(.connected)
        let providers = [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 72, resetsAt: stamp + 3600)],
                fidelity: "stale", state: "stale", forecast: CoreUsageForecast(exhaustsAt: stamp + 600, pace: "ahead"),
                observedAt: stamp, readAt: stamp - 300),
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "5h", usedPct: 100, resetsAt: stamp - 60)],
                fidelity: "official", state: "ready", observedAt: stamp - 300),
        ]
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: stamp, providers: providers))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        #expect(store.forecast(for: providers[0], window: providers[0].windows[0]).verdict == .guarded(reason: "stale_samples"))
        #expect(store.forecast(for: providers[1], window: providers[1].windows[0]).verdict == .guarded(reason: "window_elapsed"))
        try WindowsRenderProofTests.write("usage-evidence-paused", size: CGSize(width: 800, height: 820)) {
            VStack(spacing: 16) {
                UsageProviderDetail(provider: providers[0], store: store, showCost: true)
                UsageProviderDetail(provider: providers[1], store: store, showCost: true)
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func mixedModelCacheCard() async throws {
        let stamp: Double = 1_800_000_000
        let provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: stamp + 3600)],
                                        fidelity: "official", state: "ready", observedAt: stamp)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-cache-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: stamp, providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        var history = UsageHistory(provider: "claude", range: "7d",
            days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 1_000_000, tokensOut: 500_000, cacheRead: 1_000_000, costUsd: 4.5)],
            pricing: UsagePricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, model: "fixture-model-a"), records: 2)
        history.models = [UsageHistoryModel(model: "fixture-model-a", tokens: 1_000_000, costUsd: 1.5, records: 1),
                          UsageHistoryModel(model: "fixture-model-b", tokens: 1_500_000, costUsd: 3, records: 1)]
        let fixture = history
        store.readHistory = { _, _ in fixture }
        let task = try #require(store.load(provider: provider))
        await task.value
        #expect(store.history(for: provider)?.cacheSavings == nil)
        #expect(store.history(for: provider)?.cacheShare == 0.5)
        try WindowsRenderProofTests.write("usage-evidence-mixed-cache", size: CGSize(width: 800, height: 860)) {
            UsageProviderDetail(provider: provider, store: store, showCost: true).padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), arguments: [false, true])
    func historyWithoutQuotaRead(quotaRead: Bool) async throws {
        let stamp: Double = 1_800_000_000
        let provider = CoreProviderUsage(id: "claude", windows: [], state: "source_not_found")
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-quota-status-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: quotaRead ? stamp - 30 : nil,
                                                    providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        store.readHistory = { _, _ in
            UsageHistory(provider: "claude", range: "7d",
                days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 12_000, tokensOut: 3_000, costUsd: 0.081)],
                records: 1)
        }
        let task = try #require(store.load(provider: provider))
        await task.value
        #expect(store.history(for: provider)?.totalTokens == 15_000)
        #expect((store.refreshedAt != nil) == quotaRead)
        let name = quotaRead ? "usage-history-quota-read" : "usage-history-no-quota-read"
        try WindowsRenderProofTests.write(name, size: CGSize(width: 800, height: 860)) {
            UsageCenterView(store: store)
        }
    }

}
