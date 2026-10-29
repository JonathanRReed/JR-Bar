import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Pictures of what the second audit round changed on screen: the panel's
/// usage section with two accounts, a stale provider at 0 % and a source
/// with no quota, and History saying why it has no rows. (Swift Charts
/// draws nothing under `ImageRenderer`, so the Quota chart's change is
/// held by `UsageGraphViewTests` instead.) Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Screen bar, usage and history render proof", .serialized, .renderProofAppearance)
@MainActor
struct ScreenBarUsageUIRenderProofTests {
    private static let t = WindowsRenderProofTests.t

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelUsageSection() throws {
        var stale = CoreProviderUsage(id: "gemini", windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: 0, resetsAt: Self.t + 4000)],
                                      fidelity: "official", state: "stale", action: "Reconnect Gemini")
        stale.readAt = Self.t - 7 * 3600
        let usage = CoreUsage(refreshedAt: Self.t - 30, providers: [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 99.6, resetsAt: Self.t + 1500),
                CoreUsageWindow(key: "7d", name: "7d", usedPct: 40, resetsAt: Self.t + 3 * 86_400),
            ], fidelity: "official", state: "ready", observedAt: Self.t - 20),
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 18, resetsAt: Self.t + 9000),
            ], fidelity: "official", state: "ready", instance: "work", observedAt: Self.t - 20),
            stale,
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(key: "5h", name: "5h", usedPct: 0)], state: "ready"),
            CoreProviderUsage(id: "opencode", windows: [], state: "ready", quotaSource: false),
        ])
        let state = CoreState(now: Self.t, aggregate: CoreAggregate(mode: "idle"), sessions: [],
                              devices: [WindowsRenderProofTests.devices[2]], usage: usage)
        let store = WindowsRenderProofTests.panelStore(state)
        try WindowsRenderProofTests.write("screenbar-usage-panel", size: WindowsRenderProofTests.panelSize(store),
                                          plate: .glass) { WindowsRenderProofTests.panel(store) }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func historyThatCouldNotLoad() throws {
        let core = WindowsRenderProofTests.liveCore(CoreState(now: Self.t, aggregate: CoreAggregate(mode: "idle")))
        let store = HistoryStore(core: core)
        store.now = WindowsRenderProofTests.now
        store.error = HistoryStore.loadFailurePrefix
            + UsageCenterStore.describe(CoreReplyError(code: "busy", message: "The monitor is busy reading transcripts"))
        try WindowsRenderProofTests.write("history-load-error", size: CGSize(width: 720, height: 420)) { HistoryView(store: store) }
    }
}
