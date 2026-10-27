import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Consistency render proofs", .serialized)
@MainActor
struct ConsistencyRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func surfaces() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        let now = WindowsRenderProofTests.t
        let usage = WindowsRenderProofTests.usage(heavy: true)
        let core = fixture.core
        core.handle(.connected)
        core.apply(.state(CoreState(now: now, sessions: [
            CoreSession(id: "codex:sample", provider: "codex", label: "Sample check", mode: "working"),
        ], devices: WindowsRenderProofTests.devices, usage: usage)))
        let panel = WindowsRenderProofTests.panelStore(core.state!)
        let center = UsageCenterStore(core: core)
        var ask = DecidedAskFixture.openAsk()
        ask.openedAt = now - 75
        ask.decision?.holdUntil = now + 300
        let asking = WindowsRenderProofTests.panelStore(DecidedAskFixture.state(holding: ask))
        let unsupported = CoreProviderUsage(id: "grok", windows: [], quotaSource: false)
        let suite = ScratchDefaults.suiteName("consistency-studio")
        defer { ScratchDefaults.remove(suite) }
        let studio = EffectStudioStore(core: core, defaults: ScratchDefaults.open(suite), settings: fixture.settings)
        studio.covered = true
        studio.mode = .mix
        studio.lightsStudio.requestPlan = {
            StudioLightPlan(mixes: [StudioMix(id: "weave", name: "Weave", parameters: [])], devices: [])
        }
        studio.lightsStudio.requestPreview = { _, _ in
            StudioFleetPreview(program: "#1288FF", label: "Two agents working", played: "weave",
                reason: "Weave plays because Codex and Claude are working.", warnings: [], ledCount: 8)
        }
        await studio.lightsStudio.refreshPlan()
        await studio.lightsStudio.refreshPreviews()
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            func render<V: View>(_ view: V, _ name: String, _ width: CGFloat) throws {
                try ProofRender.write(view.padding(16).background(Color(nsColor: .windowBackgroundColor)),
                    size: CGSize(width: width, height: 1), name: "\(name)-\(look)", dark: dark, settle: 0)
            }
            try render(PanelView(store: panel, panelWidth: 372), "panel", 404)
            try render(PanelView(store: asking, panelWidth: 372), "panel-ask", 404)
            try render(UsageGaugeRow(provider: unsupported, name: "Grok", now: now, style: .compact, windowNames: ["5h", "7d"]),
                       "no-quota-source", 320)
            try render(UsageOverviewTable(store: center, showCost: true, select: { _ in }), "usage-overview", 1000)
            try render(UsageProviderDetail(provider: usage.providers[0], store: center, showCost: true), "usage-detail", 780)
            for page in [SettingsStore.Page.devices, .integrations, .utilities, .agents, .remote] {
                try render(SettingsPageContainer(store: fixture.settings, page: page), "settings-\(page.rawValue)", 620)
            }
            try render(EffectStudioView(store: studio), "studio-mix", 1160)
            try render(WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {}), "whats-new", WhatsNewView.width + 32)
            try render(StatusBanner("The monitor is not connected.", detail: "Reconnecting…"), "notice", 560)
            let icon = StatusIconRenderer().image(for: StatusIconSpec(style: .orbit, ringFraction: 0.42))
            try render(Image(nsImage: icon).frame(width: 32, height: 24), "menu-bar-item", 64)
            // Render the real catalog items offscreen. Opening NSMenu would put it on the desktop.
            let sections = AppMenuCatalog.sections(creatorMicro: true).map { verbs in
                verbs.map { $0.menuItem(action: nil, target: nil) }
            }
            try render(VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sections.enumerated()), id: \.offset) { section, items in
                    if section > 0 { Divider() }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(item.keyEquivalent.isEmpty ? "" : "⌘" + item.keyEquivalent.uppercased())
                                .foregroundStyle(.secondary)
                        }
                        .jrbarType(.body)
                    }
                }
            }, "menu-bar-menu", 300)
        }
    }
}
