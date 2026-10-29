import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the usage switches: the Usage Center card of a provider
/// that is off (and the same card once the person turned it on), Settings ›
/// Usage's per-provider switches, and Setup's per-provider question. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write PNGs into
/// `JRBAR_RENDER_PROOF_DIR`, using the mock daemon's `consent` usage scenario.
@Suite("Usage consent render proof", .serialized, .renderProofAppearance)
@MainActor
struct UsageConsentRenderProofTests {
    private func write(_ name: String, size: CGSize, _ view: some View) throws {
        try FileManager.default.createDirectory(at: SettingsRenderProofTests.directory,
                                                withIntermediateDirectories: true)
        for dark in [false, true] {
            let rep = try SettingsRenderProofTests.snapshot(view, size: size, dark: dark)
            let image = try #require(SettingsRenderProofTests.cropped(rep))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: SettingsRenderProofTests.directory
                .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func usageCenterCards() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6, extra: ["--usage-scenario", "consent"])
        defer { process.terminate(); core.stop() }
        let store = UsageCenterStore(core: core)
        store.windowDidOpen()
        try await WindowsRenderProofTests.settle {
            store.providers.count == 4 && store.providerRows.count == 4
        }
        let claude = try #require(store.providers.first { $0.id == "claude" })
        #expect(claude.usageIsOff)
        #expect(claude.windows.isEmpty, "no lane is invented for a provider that is off")
        let row = try #require(store.row(for: "claude"))
        #expect(row.usageConsent?.granted == false)
        try write("usage-consent-center-off", size: CGSize(width: 780, height: 1500), UsageCenterView(store: store))

        // The person reads the sentence on the card and turns Claude on.
        store.setUsageConsent(row, true)
        try await WindowsRenderProofTests.settle {
            store.providers.first { $0.id == "claude" }?.usageIsOff == false
        }
        let on = try #require(store.providers.first { $0.id == "claude" })
        #expect(!on.usageIsOff && !on.windows.isEmpty)
        #expect(store.providers.first { $0.id == "cursor" }?.usageIsOff == true, "only Claude changed")
        try write("usage-consent-center-claude-on", size: CGSize(width: 780, height: 1500), UsageCenterView(store: store))
        store.windowDidClose()
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func settingsUsagePage() async throws {
        let (core, process) = try await WindowsRenderProofTests.mock(startAt: 6, extra: ["--usage-scenario", "consent"])
        defer { process.terminate(); core.stop() }
        let settings = SettingsStore(core: core)
        settings.open(chapter: .usage)
        let model = ProviderUsageSwitchesModel()
        model.refresh(core: core)
        try await WindowsRenderProofTests.settle { model.switchRows.count == 4 }
        try write("usage-consent-settings-usage",
                  size: CGSize(width: SettingsRenderProofTests.paneWidth, height: 900),
                  Form {
                      Section { SettingsPageHeader(page: .agents) }
                      ProviderUsageSwitchesGroup(store: settings, model: model)
                  }
                  .formStyle(.grouped)
                  .environment(settings))
        // Turning one on changes that provider's row and no other.
        let cursor = try #require(model.switchRows.first { $0.id == "cursor" })
        model.set(cursor, on: true, core: core)
        try await WindowsRenderProofTests.settle {
            model.switchRows.first { $0.id == "cursor" }?.usageConsent?.granted == true
        }
        #expect(model.switchRows.filter { $0.usageConsent?.granted == true }.map(\.id) == ["cursor"])
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func setupAgentsStep() async throws {
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = {
            [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok"),
             SetupAgent(id: "cursor", name: "Cursor", detected: true, hookStatus: "missing"),
             SetupAgent(id: "codex", name: "Codex", detected: true, hookStatus: "ok"),
             SetupAgent(id: "grok", name: "Grok", detected: false, hookStatus: "missing")]
        }
        model.usageOffers = {
            [SetupUsageOffer(
                id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "JR-Bar will ask Anthropic for your usage with the sign-in Claude Code already has. Nothing else is sent.",
                isOn: false),
             SetupUsageOffer(
                id: "cursor", name: "Cursor", question: "Show Cursor usage?",
                summary: "JR-Bar will ask Cursor for your plan usage with the sign-in the Cursor app already has. Nothing else is sent.",
                isOn: false),
             SetupUsageOffer(
                id: "codex", name: "Codex", question: "Show Codex usage?",
                summary: "JR-Bar will ask OpenAI for your Codex limits, by running Codex's own app server with the sign-in Codex already has. Nothing else is sent.",
                isOn: false)]
        }
        model.setUsage = { _, _ in SetupNote("Usage on", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        // Claude: yes. Cursor: not now. Codex: still asking.
        await store.turnOnUsage(for: "claude")?.value
        store.declineUsage(for: "cursor")
        try write("usage-consent-setup-agents", size: CGSize(width: 680, height: 760), VStack(alignment: .leading, spacing: 8) {
            Text("Connect your agents").font(.system(size: 24, weight: .semibold)).padding(.horizontal, 24)
            SetupAgentsStep(store: store)
        }.padding(.top, 24))
    }
}
