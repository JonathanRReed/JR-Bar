import JRBarTestSupport
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory API key connection", .serialized, .renderProofAppearance)
struct FactoryBrowserConnectionRenderProofTests {
    nonisolated static let states: [(name: String, key: Bool, browser: Bool, reason: String)] = [
        ("no-key", false, false, "authentication_required"),
        ("key-saved", true, false, ""),
        ("refresh-only", false, true, "browser_token_unavailable"),
        ("legacy-expired", false, true, "browser_session_expired"),
    ]

    private func row(key: Bool, browser: Bool) throws -> ProviderRow {
        let data = Data("""
        {"id":"factory","instance":"work","label":"Factory","enabled":true,
         "credentials":[{"account":"api-key","available":\(key)},
                        {"account":"web-session","available":\(browser)}]}
        """.utf8)
        return try JSONDecoder().decode(ProviderRow.self, from: data)
    }

    private func model(key: Bool) -> ProviderCredentialEditorModel {
        ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
            available: key, save: { _ in }, remove: {})
    }

    @Test(arguments: Self.states)
    func onlyKeyControlsAreOffered(state: (name: String, key: Bool, browser: Bool, reason: String)) throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-factory-key-test-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        #expect(core.isLive)
        let providerRow = try row(key: state.key, browser: state.browser)
        let controls = NSHostingView(rootView: ProviderCredentialControls(row: providerRow, core: core, onChanged: {}))
        controls.frame.size = controls.fittingSize
        controls.layoutSubtreeIfNeeded()
        let rowLabels = PolishRound2Tests.buttonLabels(controls)
        #expect(rowLabels.contains(state.key ? "Replace Factory API key" : "Add Factory API key"))
        #expect(!rowLabels.contains { $0.localizedCaseInsensitiveContains("browser") })
        let editor = NSHostingView(rootView: ProviderCredentialEditor(model: model(key: state.key), dismiss: {}))
        editor.frame.size = editor.fittingSize
        editor.layoutSubtreeIfNeeded()
        let sheetLabels = PolishRound2Tests.buttonLabels(editor)
        if state.key {
            #expect(sheetLabels.contains("Replace"))
            #expect(sheetLabels.contains("Remove"))
            #expect(!sheetLabels.contains("Save API key"))
        } else {
            #expect(sheetLabels.contains("Save API key"))
        }
        #expect(!sheetLabels.contains("Import"))
        #expect(editor.fittingSize.height < 400)
        if !state.key {
            var reading = ProviderSignInRecoveryTests.reading("factory")
            reading.instance = "work"
            reading.reason = state.reason
            let store = UsageCenterStore(core: core)
            store.runProviderAction(reading)
            #expect(store.credentialConnectRequests[reading.identity] == 1)
            #expect(store.browserConnectRequests.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"), arguments: Self.states)
    func connectionProofs(state: (name: String, key: Bool, browser: Bool, reason: String)) async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-factory-proof-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        #expect(core.isLive)
        let providerRow = try row(key: state.key, browser: state.browser)
        let store = UsageCenterStore(core: core)
        var reading = ProviderSignInRecoveryTests.reading("factory")
        reading.instance = "work"
        reading.reason = state.reason
        if state.key {
            reading.state = "ready"
            reading.action = nil
            reading.actionKind = nil
        }
        for dark in [false, true] {
            try await U5Proof.render(ProviderCredentialEditor(model: model(key: state.key), dismiss: {}),
                name: "factory-\(state.name)-sheet", width: 420, dark: dark)
            try await U5Proof.render(ProviderCredentialControls(row: providerRow, core: core, onChanged: {}).padding(20),
                name: "factory-\(state.name)-settings", width: 420, dark: dark)
            try await U5Proof.render(UsageProviderConnection(provider: reading, store: store, row: providerRow).padding(20),
                name: "factory-\(state.name)-usage-center", width: 560, dark: dark)
        }
    }
}
