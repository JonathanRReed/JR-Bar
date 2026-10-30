import Foundation
import AppKit
@testable import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Provider sign-in recovery", .renderProofAppearance)
struct ProviderSignInRecoveryTests {
    static func reading(_ id: String) -> CoreProviderUsage {
        var value = CoreProviderUsage(id: id, windows: [], state: "needs_sign_in",
                                      action: id == "factory" ? "Connect Factory" : "Reconnect Devin browser session", reason: "browser_session_expired")
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
        #expect(lines[0].contains(provider == "factory" ? "Connect Factory" : "Reconnect"))
        let usageStore = UsageCenterStore(core: store.core)
        usageStore.runProviderAction(providerReading)
        #expect(usageStore.browserConnectRequests[providerReading.identity] == 1)
        #expect(usageStore.credentialConnectRequests.isEmpty)
        usageStore.didPresentBrowserConnection(providerReading.identity)
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

    @Test func menuAddsOnlyAccountsThatNeedConnection() {
        let healthy = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 30)], state: "ready")
        var secondary = healthy
        secondary.instance = "work"
        let signedOut = Self.reading("factory")
        let candidates = AppDelegate.usageMenuProviders(metered: [healthy], usage: [healthy, secondary, signedOut])
        #expect(candidates.map(\.identity) == [healthy.identity, signedOut.identity])
        let repeated = AppDelegate.usageMenuProviders(metered: [signedOut], usage: [signedOut])
        #expect(repeated.count == 1)
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

    @Test(arguments: ["factory", "devin"])
    func unavailableBrowserTokenOpensOnlyThatAccountsKeyEditor(provider: String) {
        var reading = Self.reading(provider)
        reading.instance = "work"
        reading.reason = "browser_token_unavailable"
        reading.action = "Add \(ProviderPalette.displayName(for: provider)) API key"
        let core = CoreModel(socketPath: "/tmp/jrbar-key-recovery-unused.sock")
        let store = UsageCenterStore(core: core)
        store.runProviderAction(reading)
        if provider == "factory" {
            #expect(store.browserConnectRequests[reading.identity] == 1)
            #expect(store.credentialConnectRequests.isEmpty)
            #expect(!store.presentKeyRecovery(reading))
        } else {
            #expect(store.credentialConnectRequests[reading.identity] == 1)
            #expect(store.browserConnectRequests.isEmpty)
            #expect(store.credentialConnectRequests[provider] == nil)
            store.didPresentCredentialConnection(reading.identity)
            #expect(store.credentialConnectRequests.isEmpty)
            #expect(store.presentKeyRecovery(reading))
        }
        var consent = reading
        consent.reason = "usage_consent_required"
        #expect(!store.presentKeyRecovery(consent))
    }

    @Test(arguments: ["factory", "devin"])
    func incompleteImportKeepsTheSheetOpenWithAKeyAction(provider: String) async {
        let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen test profile")
        let model = FactoryBrowserConnectionModel(provider: provider, available: false,
            load: { [profile] }, importSession: { _ in
                throw CoreReplyError(code: "browser_token_unavailable", message: "synthetic-private-value")
            }, disconnect: { "Unused." })
        await model.load()
        model.approved = true
        #expect(await model.connect() == false)
        #expect(model.needsAPIKey)
        #expect(model.message?.contains("API key") == true)
        #expect(model.message?.contains("expired") == false)
        #expect(model.message?.contains("synthetic-private-value") == false)
        #expect(!model.available)
        await model.load()
        #expect(!model.needsAPIKey)
        #expect(model.message == nil)
        model.beginEditing()
        #expect(!model.needsAPIKey)
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
                if provider == "devin" {
                    let sheet = DevinBrowserConnectionSheet(model: model, instance: "default", dismiss: {})
                        .frame(width: 480, height: 560).background(Color(nsColor: .windowBackgroundColor))
                    let sheetBitmap = try SettingsRenderProofTests.snapshot(sheet, size: CGSize(width: 480, height: 560), dark: dark)
                    let sheetPNG = try #require(sheetBitmap.representation(using: .png, properties: [:]))
                    try sheetPNG.write(to: directory.appendingPathComponent("signin-\(provider)-sheet-\(dark).png"))
                }
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func unavailableTokenAndKeyEditorProofs() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let editorModel = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
                available: false, save: { _ in }, remove: {}, onChanged: {})
            try await U5Proof.render(ProviderCredentialEditor(model: editorModel, dismiss: {}),
                name: "factory-key-editor", width: 420, dark: dark)
            var reading = Self.reading("factory")
            reading.reason = "browser_token_unavailable"
            reading.action = "Connect Factory"
            reading.statusText = "Connect Factory to allow browser sign-in renewal, or add an API key."
            let row = UsageGaugeRow(provider: reading, name: "Factory", now: PanelCompositionTests.time,
                                    connected: true, style: .compact, windowNames: [], onAction: {})
                .padding(16).frame(width: 380, height: 170).background(Color(nsColor: .windowBackgroundColor))
            let rowImage = try SettingsRenderProofTests.snapshot(row, size: CGSize(width: 380, height: 170), dark: dark)
            let rowPNG = try #require(rowImage.representation(using: .png, properties: [:]))
            try rowPNG.write(to: directory.appendingPathComponent("factory-key-recovery-row-\(dark).png"))
            let core = CoreModel(socketPath: "/tmp/jrbar-factory-consent-proof-unused.sock")
            core.handle(.connected)
            core.apply(.state(CoreState()))
            let store = UsageCenterStore(core: core)
            let providerRow = try JSONDecoder().decode(ProviderRow.self, from: Data(#"""
            {"id":"factory","instance":"work","label":"Factory","enabled":true,
             "credentials":[{"account":"web-session","available":true}],
             "usage_consent":{"granted":true,"question":"Show Factory usage?",
              "summary":"JR-Bar will ask Factory for your subscription usage limits with your saved API key first, or your connected browser sign-in. WorkOS renewal needs separate browser consent. Nothing else is sent.",
              "detail":"Asks api.factory.ai for Standard and Core usage windows with your saved API key first, or your connected browser sign-in. If you approve renewal in Connect Factory, JR-Bar sends its refresh token to api.workos.com and saves rotated tokens only in Keychain. Factory may ask you to sign in again in your browser. Connecting does not turn on usage. Save API key checks a key once; this switch controls ongoing requests.",
              "hosts":["api.factory.ai","api.workos.com"],"credential":"your connected Factory browser sign-in or API key in JR-Bar Keychain"}}
            """#.utf8))
            let connection = UsageProviderConnection(provider: reading, store: store, row: providerRow)
                .padding(16).frame(width: 560, height: 330).background(Color(nsColor: .windowBackgroundColor))
            let connectionImage = try SettingsRenderProofTests.snapshot(connection, size: CGSize(width: 560, height: 330), dark: dark)
            let connectionPNG = try #require(connectionImage.representation(using: .png, properties: [:]))
            try connectionPNG.write(to: directory.appendingPathComponent("factory-key-consent-\(dark).png"))
        }
    }

}
