import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Panel usage window columns", .serialized, .renderProofAppearance)
@MainActor
struct UsageWindowColumnsRenderProofTests {
    static let now = PanelCompositionTests.time

    static func providers() -> [CoreProviderUsage] {
        var codex = PanelCompositionTests.usage("codex")
        codex.windows = [CoreUsageWindow(name: "5h", usedPct: nil),
                         CoreUsageWindow(name: "7d", usedPct: 23, resetsAt: now + 172800)]
        var claude = PanelCompositionTests.usage("claude")
        claude.windows[0].usedPct = 4
        claude.windows[1].usedPct = 81
        let devin = CoreProviderUsage(id: "devin", windows: [
            CoreUsageWindow(key: "daily", name: "Daily", usedPct: 0, resetsAt: now + 7200),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 52, resetsAt: now + 172800),
        ], state: "ready")
        let grok = CoreProviderUsage(id: "grok", windows: [
            CoreUsageWindow(key: "credits", name: "Credits", usedPct: 28, resetsAt: now + 18000),
        ], state: "ready")
        let antigravity = CoreProviderUsage(id: "antigravity", windows: [
            CoreUsageWindow(key: "gemini-five-hour", name: "Gemini 5-Hour", usedPct: 30, resetsAt: now + 7200),
            CoreUsageWindow(key: "gemini-weekly", name: "Gemini Weekly", usedPct: 40, resetsAt: now + 172800),
            CoreUsageWindow(key: "claude-gpt-weekly", name: "Claude + GPT Weekly", usedPct: 50, resetsAt: now + 172800),
            CoreUsageWindow(key: "gemini-argon-weekly", name: "Gemini 4 Argon Weekly", usedPct: 60, resetsAt: now + 172800),
        ], state: "ready")
        let factory = CoreProviderUsage(id: "factory", windows: [
            CoreUsageWindow(key: "standard-5h", name: "Standard 5-hour", usedPct: 12, resetsAt: now + 7200),
            CoreUsageWindow(key: "standard-7d", name: "Standard 7-day", usedPct: 34, resetsAt: now + 172800),
            CoreUsageWindow(key: "standard-30d", name: "Standard Monthly", usedPct: 56),
            CoreUsageWindow(key: "core-5h", name: "Core 5-hour", usedPct: 23, resetsAt: now + 7200, bindable: false),
            CoreUsageWindow(key: "core-7d", name: "Core 7-day", usedPct: 45, resetsAt: now + 172800, bindable: false),
            CoreUsageWindow(key: "core-30d", name: "Core Monthly", usedPct: 67, bindable: false),
        ], state: "ready")
        return [codex, claude, devin, grok, antigravity, factory]
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelWindowsAtBothWidthsAndAppearances() async throws {
        let providers = Self.providers()
        let panel = PanelCompositionTests.store(usage: providers)
        let section = PanelProviderSection(store: panel, composition: PanelComposition(store: panel))
        for width: CGFloat in [320, 372] {
            for dark in [false, true] {
                // An expanded proof lists all six production rows. The real panel caps at four.
                let allRows = VStack(spacing: 0) {
                    SectionHeader("Usage").padding(.horizontal, 12).frame(height: 28)
                    UsageGaugeHeader(windowNames: panel.panelWindowNames).frame(height: 20)
                    ForEach(providers) { provider in
                        section.gauge(provider).frame(height: PanelComposition.usageHeight(provider))
                    }
                }
                try await U5Proof.render(allRows, name: "G2-windows-all-\(Int(width))", width: width, dark: dark)
                try await U5Proof.render(PanelView(store: panel, panelWidth: width),
                    name: "G2-panel-first-\(Int(width))", width: width, dark: dark)
                let pools = PanelCompositionTests.store(usage: Array(providers.suffix(2)))
                try await U5Proof.render(PanelView(store: pools, panelWidth: width),
                    name: "G2-panel-pools-\(Int(width))", width: width, dark: dark)
                let matrix = try UsageWindowMatrixTests.fixture()
                for id in ["cursor", "kiro"] {
                    let provider = try #require(matrix.cases.first { $0.provider.id == id }?.provider)
                    let ownPanel = PanelCompositionTests.store(usage: [provider])
                    ownPanel.now = Date(timeIntervalSince1970: matrix.now)
                    let ownSection = PanelProviderSection(store: ownPanel, composition: PanelComposition(store: ownPanel))
                    try await U5Proof.render(ownSection.gauge(provider),
                        name: "G2-\(id)-only-\(Int(width))", width: width, dark: dark)
                }
            }
        }
    }

    @Test func extraPoolsDoNotIncreasePanelRowHeight() {
        for provider in Self.providers() {
            #expect(UsageGaugeRow.panelAdditionalHeight(provider) == 16)
            for width: CGFloat in [320, 372] {
                let row = UsageGaugeRow(provider: provider, name: ProviderPalette.displayName(for: provider.id),
                    now: Self.now, style: .panel, windowNames: ["5h", "7d"])
                let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
                #expect(host.fittingSize.height == 52)
                #expect(PanelComposition.usageHeight(provider) == 52)
            }
        }
    }
}
