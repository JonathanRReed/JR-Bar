import JRBarCore
import JRBarUI
import SwiftUI
import Testing

@Suite("Foundation render proof", .serialized)
@MainActor
struct FoundationRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func components() throws {
        let now: Double = 1_800_000_000
        let windows = [CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 3600),
                       CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: now + 86400)]
        let names = ["missing_recent": "Gemini", "source_idle": "Antigravity", "failing": "Codex", "not_found": "Kiro", "absent": "Devin"]
        try WindowsRenderProofTests.write("foundation-usage", size: CGSize(width: 372, height: 760)) {
            VStack(spacing: JRBarTokens.Space.md) {
                UsageGaugeRow(provider: CoreProviderUsage(id: "claude", windows: windows, state: "ready"),
                              name: "Claude", now: now)
                ForEach(["missing_recent", "source_idle", "failing", "not_found", "absent"], id: \.self) { state in
                    UsageGaugeRow(provider: fixture(state, windows: windows, now: now), name: names[state] ?? state, now: now, onAction: {})
                }
                UsageGaugeRow(provider: CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "5h", usedPct: 92, resetsAt: now - 1)],
                                                         state: "ready"), name: "Codex", now: now)
            }.padding(JRBarTokens.Space.lg)
        }
        try WindowsRenderProofTests.write("foundation-logo", size: CGSize(width: 600, height: 120)) {
            HStack(spacing: JRBarTokens.Space.lg) {
                ForEach(["claude", "codex", "gemini", "cursor", "grok", "devin", "opencode", "factory"], id: \.self) {
                    ProviderLogoTile(provider: $0)
                }
            }.padding(JRBarTokens.Space.lg)
        }
        try WindowsRenderProofTests.write("foundation-banner", size: CGSize(width: 600, height: 120)) {
            StatusBanner("The monitor isn't running", kind: .failure) { Button("Start Monitor") {} }
                .padding(JRBarTokens.Space.lg)
        }
        try WindowsRenderProofTests.write("foundation-settings", size: CGSize(width: 600, height: 120)) {
            SettingsRow("Open at login") { Toggle("Open at login", isOn: .constant(true)).labelsHidden().toggleStyle(.switch) }
                .padding(JRBarTokens.Space.lg)
        }
        try WindowsRenderProofTests.write("foundation-group", size: CGSize(width: 372, height: 280)) {
            VStack(spacing: JRBarTokens.Space.md) {
                AgentGroupRow(provider: "claude", name: "Claude", workerCount: 3, expanded: .constant(true)) {
                    Text("Codex · Working").font(JRBarTokens.TypeStyle.body.font)
                }
                AgentGroupRow(provider: "codex", name: "Codex", workerCount: 0, unlinked: true, expanded: .constant(false)) {
                    EmptyView()
                }
            }.padding(JRBarTokens.Space.lg)
        }
    }

    private func fixture(_ state: String, windows: [CoreUsageWindow], now: Double) -> CoreProviderUsage {
        let ids = ["missing_recent": "gemini", "source_idle": "antigravity", "failing": "codex", "not_found": "kiro", "absent": "devin"]
        var provider = CoreProviderUsage(id: ids[state] ?? "claude", windows: windows, state: "stale", readAt: now - 120)
        provider.availability = state
        provider.statusText = ["missing_recent": "Not found on this Mac", "source_idle": "Quota service is not running",
                               "failing": "Sign-in rejected", "not_found": "Not found on this Mac"][state]
        provider.action = ["source_idle": "Open", "not_found": "Hide", "failing": "Sign in"][state]
        provider.actionKind = ["source_idle": "open_app", "not_found": "hide"][state]
        provider.lastGoodAgeSeconds = 120
        return provider
    }
}
