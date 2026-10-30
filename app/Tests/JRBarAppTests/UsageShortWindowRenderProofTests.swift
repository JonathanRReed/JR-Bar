import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Panel short and cycle windows", .serialized, .renderProofAppearance)
@MainActor
struct UsageShortWindowRenderProofTests {
    static let now = PanelCompositionTests.time

    static func ownerProviders() -> [CoreProviderUsage] {
        let forecast = CoreUsageForecast(exhaustsAt: now + 52 * 3600, pace: "ahead", ratePctPerHour: 55.0 / 52)
        let codex = CoreProviderUsage(id: "codex", windows: [
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 45, resetsAt: now + 4 * 86400,
                            forecast: forecast),
        ], state: "ready")
        let claude = CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 16, resetsAt: now + 2400),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 35, resetsAt: now + 4 * 86400),
            CoreUsageWindow(key: "fable-only", name: "7d Fable", usedPct: 0, resetsAt: now + 4 * 86400),
        ], state: "ready")
        let devin = CoreProviderUsage(id: "devin", windows: [
            CoreUsageWindow(key: "daily", name: "Daily", usedPct: 0, resetsAt: now + 7200),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 71, resetsAt: now + 2 * 86400),
        ], state: "ready")
        let grok = CoreProviderUsage(id: "grok", windows: [
            CoreUsageWindow(key: "credits", name: "Credits", usedPct: 1, resetsAt: now + 18000),
        ], state: "ready")
        return [codex, claude, devin, grok]
    }

    static func adaptiveProviders() -> [CoreProviderUsage] {
        var pro = ownerProviders()[0]
        pro.instance = "sample-pro"
        pro.instanceLabel = "Codex · Pro"
        pro.account = UsageAccount(plan: "Pro")
        let plus = CoreProviderUsage(id: "codex", windows: [
            CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 30, resetsAt: now + 2400),
            CoreUsageWindow(key: "weekly", name: "7d", usedPct: 62, resetsAt: now + 4 * 86400),
        ], state: "ready", account: UsageAccount(plan: "Plus"), instance: "sample-plus", instanceLabel: "Codex · Plus")
        return [pro, plus, ownerProviders()[3]]
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func ownerAndPoolsAtBothWidthsAndAppearances() async throws {
        let phase = "after"
        let fixtures: [(String, [CoreProviderUsage])] = [
            ("owner", Self.ownerProviders()),
            ("pools", Array(UsageWindowColumnsRenderProofTests.providers().suffix(2))),
            ("adaptive", Self.adaptiveProviders()),
        ]
        for (name, providers) in fixtures {
            let session = CoreSession(id: "codex:sample", provider: "codex", label: "Sample task", mode: "working")
            let panel = PanelCompositionTests.store([session], usage: providers)
            let section = PanelProviderSection(store: panel, composition: PanelComposition(store: panel))
            if name == "owner" {
                let codex = try #require(providers.first)
                let window = try #require(codex.windows.first)
                #expect(section.gauge(codex).reading(for: window).footnote == "Runs out in 2d 4h")
            }
            for width: CGFloat in [320, 372] {
                for dark in [false, true] {
                    try await U5Proof.render(section, name: "P-\(phase)-\(name)-\(Int(width))", width: width, dark: dark)
                    if name == "owner" && phase == "after" {
                        let sharedHeaders = VStack(spacing: 0) {
                            SectionHeader("Usage").padding(.horizontal, 12).frame(height: 28)
                            UsageGaugeHeader(windowNames: ["Short", "Cycle"]).frame(height: 20)
                            ForEach(providers) { provider in
                                section.gauge(provider).frame(height: PanelComposition.usageHeight(provider))
                            }
                        }
                        try await U5Proof.render(sharedHeaders, name: "P-alternative-headers-\(Int(width))", width: width, dark: dark)
                    }
                }
            }
        }
    }
}
