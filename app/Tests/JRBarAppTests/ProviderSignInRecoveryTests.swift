import Foundation
import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Provider sign-in recovery")
struct ProviderSignInRecoveryTests {
    static func reading(_ id: String) -> CoreProviderUsage {
        var value = CoreProviderUsage(id: id, windows: [], state: "needs_sign_in",
                                      action: "Reconnect \(id.capitalized) browser session", reason: "browser_session_expired")
        value.actionKind = "manage"
        value.availability = "available"
        value.quotaSource = false
        return value
    }

    @Test(arguments: ["factory", "devin"])
    func signedOutProvidersStayVisibleAndOpenTheirOwnControls(provider: String) {
        let providerReading = Self.reading(provider)
        let store = PanelCompositionTests.store(usage: [providerReading])
        var opened: String?
        store.onOpenUsageCenter = { opened = $0 }
        #expect(store.panelUsage.map(\.id) == [provider])
        #expect(UsageStatus.provider(providerReading) == .needsSignIn)
        let gauge = UsageGaugeRow(provider: providerReading, name: provider, now: PanelCompositionTests.time)
        #expect(gauge.accessibilityValue.contains(UsageStatus.needsSignIn.word))
        #expect(!gauge.accessibilityValue.contains(UsageStatus.noQuotaSource.word))
        store.panelUsageAction(providerReading)
        #expect(opened == providerReading.identity)
        let lines = StatusMenuLines.usage([providerReading], live: true, now: PanelCompositionTests.time)
        #expect(lines.count == 1)
        #expect(lines[0].contains("Reconnect"))
        let usageStore = UsageCenterStore(core: store.core)
        usageStore.runProviderAction(providerReading)
        #expect(usageStore.browserConnectRequests[providerReading.identity] == 1)
        usageStore.didPresentBrowserConnection(providerReading.identity)
        #expect(usageStore.browserConnectRequests[providerReading.identity] == nil)
        var consentReading = providerReading
        consentReading.reason = "usage_consent_required"
        usageStore.runProviderAction(consentReading)
        #expect(usageStore.browserConnectRequests[providerReading.identity] == nil)
        #expect(usageStore.notice?.text.contains("Show usage") == true)
    }

    @Test(arguments: ["factory", "devin"])
    func profileApprovalAndResultsAreVisible(provider: String) async {
        let selectedProfile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen test profile")
        var imported: [FactorySessionProfile] = []
        let model = FactoryBrowserConnectionModel(provider: provider, available: false,
            load: { [selectedProfile] }, importSession: { profile in
                imported.append(profile)
                return "Browser session imported."
            }, disconnect: { "Unused." })
        await model.load()
        #expect(!model.canConnect)
        #expect(await model.connect() == false)
        #expect(imported.isEmpty)
        model.approved = true
        #expect(await model.connect())
        #expect(imported == [selectedProfile])
        #expect(model.message == "Browser session imported.")
        #expect(model.available)
    }

    @Test(arguments: ["factory", "devin", "opencode", "gemini"])
    func noQuotaAnswersKeepTheirNeutralCaption(provider: String) {
        var answer = Self.reading(provider)
        answer.state = "unsupported"
        answer.reason = "no_separable_quota"
        answer.action = nil
        answer.actionKind = nil
        let gauge = UsageGaugeRow(provider: answer, name: provider, now: PanelCompositionTests.time)
        #expect(gauge.accessibilityValue.contains(UsageStatus.noQuotaSource.word))
        #expect(!gauge.accessibilityValue.contains(UsageStatus.needsSignIn.word))
    }

    @Test func devinImportFailureShowsTheFix() async {
        let selectedProfile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen test profile")
        let fix = "Sign in at app.devin.ai in Zen using the selected profile, then Import again."
        let model = FactoryBrowserConnectionModel(provider: "devin", available: false,
            load: { [selectedProfile] }, importSession: { _ in
                throw CoreReplyError(code: "browser_import_failed", message: fix)
            }, disconnect: { "Unused." })
        await model.load()
        model.approved = true
        #expect(await model.connect() == false)
        #expect(model.message == fix)
        #expect(!model.available)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func rowsAndImportSheets() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen test profile")
        for provider in ["factory", "devin"] {
            for dark in [false, true] {
                let providerReading = Self.reading(provider)
                let row = UsageGaugeRow(provider: providerReading, name: ProviderPalette.displayName(for: provider),
                                        now: PanelCompositionTests.time, connected: true, style: .compact,
                                        windowNames: ["5h", "7d"], onAction: {})
                    .padding(16).frame(width: 380, height: 150)
                    .background(Color(nsColor: .windowBackgroundColor))
                let rowBitmap = try SettingsRenderProofTests.snapshot(row, size: CGSize(width: 380, height: 150), dark: dark)
                let rowPNG = try #require(rowBitmap.representation(using: .png, properties: [:]))
                try rowPNG.write(to: directory.appendingPathComponent("signin-\(provider)-row-\(dark).png"))
                let model = FactoryBrowserConnectionModel(provider: provider, available: false,
                    load: { [profile] }, importSession: { _ in "Unused." }, disconnect: { "Unused." })
                await model.load()
                let sheet = FactoryBrowserConnectionSheet(model: model, instance: "default", dismiss: {})
                    .frame(width: 480, height: 560).background(Color(nsColor: .windowBackgroundColor))
                let sheetBitmap = try SettingsRenderProofTests.snapshot(sheet, size: CGSize(width: 480, height: 560), dark: dark)
                let sheetPNG = try #require(sheetBitmap.representation(using: .png, properties: [:]))
                try sheetPNG.write(to: directory.appendingPathComponent("signin-\(provider)-sheet-\(dark).png"))
                let core = CoreModel(socketPath: "/tmp/jrbar-signin-proof-unused.sock")
                core.handle(.connected)
                core.apply(.state(CoreState()))
                let usageStore = UsageCenterStore(core: core)
                let account = provider == "devin" ? "token" : "web-session"
                let rowData = Data("""
                {"id":"\(provider)","instance":"default","label":"\(provider)","enabled":true,
                 "credentials":[{"account":"\(account)","available":true}]}
                """.utf8)
                let providerRow = try JSONDecoder().decode(ProviderRow.self, from: rowData)
                let controls = UsageProviderConnection(provider: providerReading, store: usageStore, row: providerRow)
                    .padding(16).frame(width: 560, height: 280)
                    .background(Color(nsColor: .windowBackgroundColor))
                let controlsBitmap = try SettingsRenderProofTests.snapshot(controls, size: CGSize(width: 560, height: 280), dark: dark)
                let controlsPNG = try #require(controlsBitmap.representation(using: .png, properties: [:]))
                try controlsPNG.write(to: directory.appendingPathComponent("signin-\(provider)-controls-\(dark).png"))
            }
        }
    }
}
