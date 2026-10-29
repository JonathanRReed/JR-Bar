import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Usage reset budget render proof", .serialized, .renderProofAppearance)
@MainActor
struct UsageResetBudgetRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func quotaComparisons() throws {
        let now: Double = 1_800_000_000
        let rows = [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 72, resetsAt: now + 4 * 3600)],
                              fidelity: "official", state: "ready", forecast: CoreUsageForecast(pace: "under", ratePctPerHour: 4), readAt: now - 60),
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "5h", usedPct: 72, resetsAt: now + 4 * 3600)],
                              fidelity: "official", state: "ready", forecast: CoreUsageForecast(exhaustsAt: now + 28 / 9 * 3600, pace: "ahead", ratePctPerHour: 9), readAt: now - 60),
        ]
        let sessions = rows.map { CoreSession(id: $0.id + ":fixture", provider: $0.id, label: "Fixture task", mode: "working") }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-budget-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: sessions, usage: CoreUsage(refreshedAt: now, providers: rows))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: now)
        for provider in rows {
            let window = try #require(provider.windows.first)
            #expect(UsageResetBudget.make(provider: provider, window: window, forecast: store.forecast(for: provider, window: window),
                                         isLive: store.isLive, now: now) != nil)
        }
        try WindowsRenderProofTests.write("usage-reset-budget", size: CGSize(width: 800, height: 820)) {
            VStack(spacing: 16) {
                ForEach(rows, id: \.id) { UsageProviderDetail(provider: $0, store: store, showCost: true) }
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func pausedReading() throws {
        let now: Double = 1_800_000_000
        let provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 72, resetsAt: now + 4 * 3600)],
                                         fidelity: "stale", state: "stale", forecast: CoreUsageForecast(pace: "under", ratePctPerHour: 4), readAt: now - 3600)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-budget-paused-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(refreshedAt: now, providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: now)
        let window = try #require(provider.windows.first)
        #expect(UsageResetBudget.make(provider: provider, window: window, forecast: store.forecast(for: provider, window: window),
                                     isLive: store.isLive, now: now) == nil)
        try WindowsRenderProofTests.write("usage-reset-budget-paused", size: CGSize(width: 800, height: 440)) {
            UsageProviderDetail(provider: provider, store: store, showCost: true).padding(24)
        }
    }
}
