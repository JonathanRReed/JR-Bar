import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage window inspection render proof", .serialized)
struct UsageWindowInspectionRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func liveWindowEvidence() throws {
        let stamp: Double = 1_800_000_000
        let fiveHour = CoreUsageWindow(name: "5h", usedPct: 20, resetsAt: stamp + 3600,
                                       forecast: CoreUsageForecast(pace: "under", samples: 30, ratePctPerHour: 1))
        let weekly = CoreUsageWindow(name: "7d", usedPct: 53, resetsAt: stamp + 86400,
                                     forecast: CoreUsageForecast(pace: "guarded", reason: "insufficient_span", samples: 2))
        let provider = CoreProviderUsage(id: "claude", windows: [fiveHour, weekly], fidelity: "official", state: "ready", readAt: stamp - 60)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-inspection-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "working")],
                                   usage: CoreUsage(providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        try WindowsRenderProofTests.write("usage-window-inspection-live", size: CGSize(width: 800, height: 840)) {
            VStack(alignment: .leading, spacing: 24) {
                ProviderUsageCard(provider: provider, store: store)
                HStack(alignment: .top, spacing: 16) {
                    inspector(provider, window: fiveHour, store: store)
                    inspector(provider, window: weekly, store: store)
                }
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func retainedAndUnknownReadings() throws {
        let stamp: Double = 1_800_000_000
        let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: stamp + 3600,
                                     forecast: CoreUsageForecast(pace: "under", samples: 12, ratePctPerHour: 1))
        let unknown = CoreUsageWindow(name: "7d", usedPct: nil)
        let provider = CoreProviderUsage(id: "claude", windows: [window, unknown], fidelity: "official", state: "ready", readAt: stamp - 3600)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-inspection-offline-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        core.handle(.disconnected(reason: "Fixture disconnect"))
        #expect(store.providers.count == 1)
        try WindowsRenderProofTests.write("usage-window-inspection-offline", size: CGSize(width: 800, height: 840)) {
            VStack(alignment: .leading, spacing: 24) {
                ProviderUsageCard(provider: provider, store: store)
                HStack(alignment: .top, spacing: 16) {
                    inspector(provider, window: window, store: store)
                    inspector(provider, window: unknown, store: store)
                }
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func fiveIndependentPools() throws {
        let stamp: Double = 1_800_000_000
        let keys = ["gemini-argon-weekly", "gemini-weekly", "gemini-five-hour",
                    "claude-gpt-weekly", "claude-gpt-five-hour"]
        let names = ["Gemini 4 Argon Weekly", "Gemini Weekly", "Gemini 5h",
                     "Claude + GPT Weekly", "Claude + GPT 5h"]
        let windows = zip(keys, names).enumerated().map { index, pair in
            CoreUsageWindow(key: pair.0, name: pair.1, usedPct: Double(15 + index * 12),
                            resetsAt: stamp + (pair.0.hasSuffix("weekly") ? 432000 : 7200))
        }
        let provider = CoreProviderUsage(id: "antigravity", windows: windows, fidelity: "official",
                                         state: "ready", readAt: stamp - 30)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-five-pools-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: stamp)
        for width in [800, 1100] {
            try WindowsRenderProofTests.write("usage-five-pools-\(width)", size: CGSize(width: width, height: 620)) {
                ProviderUsageCard(provider: provider, store: store).padding(24)
            }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func factoryBillingWindows() throws {
        let usage = try UsageHistoryScopeTests.factoryUsageFixture()
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-factory-billing-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: usage)))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = try #require(store.providers.first)
        #expect(provider.windows.count == 6)
        for width in [800, 1100] {
            try WindowsRenderProofTests.write("usage-factory-six-windows-\(width)", size: CGSize(width: width, height: 650)) {
                ProviderUsageCard(provider: provider, store: store).padding(24)
            }
        }
    }

    private func inspector(_ provider: CoreProviderUsage, window: CoreUsageWindow, store: UsageCenterStore) -> some View {
        let model = UsageWindowInspection(provider: provider, window: window, forecast: store.forecast(for: provider, window: window),
                                          isLive: store.isLive, now: store.now)
        return UsageWindowInspectionView(inspection: model)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
