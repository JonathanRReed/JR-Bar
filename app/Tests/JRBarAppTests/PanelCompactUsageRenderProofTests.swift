import JRBarTestSupport
import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Compact panel usage", .serialized, .renderProofAppearance)
@MainActor
struct PanelCompactUsageRenderProofTests {
    private typealias Fixture = PanelCompositionTests

    private func ownerReadings() -> [CoreProviderUsage] {
        var codex = Fixture.usage("codex")
        codex.windows = [CoreUsageWindow(name: "7d", usedPct: 23, resetsAt: Fixture.time + 172_800)]
        var claude = Fixture.usage()
        claude.windows[0].usedPct = 4
        claude.windows[1].usedPct = 81
        var devin = Fixture.usage("devin")
        devin.windows = [CoreUsageWindow(name: "7d", usedPct: 52, resetsAt: Fixture.time + 86_400)]
        var grok = Fixture.usage("grok")
        grok.windows = []
        return [codex, claude, devin, grok]
    }

    @Test func normalRowsFitTheirReservationsAtBothWidths() {
        for provider in ownerReadings() {
            for width: CGFloat in [372, 320] {
                let row = UsageGaugeRow(provider: provider, name: ProviderPalette.displayName(for: provider.id),
                    now: Fixture.time, style: .panel, windowNames: ["5h", "7d"])
                let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
                let expected: CGFloat = provider.windows.isEmpty ? 36 : 52
                #expect(host.fittingSize.height == expected)
                #expect(host.fittingSize.width == width)
                #expect(PanelComposition.usageHeight(provider) == expected)
            }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func ownerAndHonestyStatesAtBothWidthsAndAppearances() async throws {
        let extra = ["gemini", "cursor", "factory", "kiro"].map { Fixture.usage($0) }
        let owner = Fixture.store([Fixture.session("codex:sample", provider: "codex")], usage: ownerReadings() + extra)
        #expect(PanelComposition(store: owner).usageLimit == 4)
        #expect(owner.panelUsage.count == 8)
        var stale = Fixture.usage("codex", availability: "missing_recent")
        stale.statusText = nil
        var failed = Fixture.usage("claude", availability: "failing", action: "Sign in…")
        failed.lastGoodAgeSeconds = 10_800
        var unreadFailure = Fixture.usage("grok", availability: "failing")
        unreadFailure.windows = []
        unreadFailure.statusText = nil
        let states = Fixture.store(usage: [stale, failed, Fixture.usage("devin", elapsed: true), unreadFailure])
        for width: CGFloat in [372, 320] {
            for dark in [false, true] {
                try await U5Proof.render(PanelView(store: owner, panelWidth: width),
                    name: "compact-usage-owner-\(Int(width))", width: width, dark: dark)
                try await U5Proof.render(PanelView(store: states, panelWidth: width),
                    name: "compact-usage-states-\(Int(width))", width: width, dark: dark)
            }
        }
    }
}
