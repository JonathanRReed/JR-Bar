import JRBarTestSupport
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory browser connection consent", .serialized, .renderProofAppearance)
struct FactoryBrowserConnectionRenderProofTests {
    nonisolated static let states: [(name: String, key: Bool, browser: Bool, reason: String)] = [
        ("not-connected", false, false, "authentication_required"),
        ("key-saved", true, false, ""),
        ("refresh-only", false, true, "browser_token_unavailable"),
        ("expired", false, true, "browser_session_expired"),
    ]

    private func row(key: Bool, browser: Bool) throws -> ProviderRow {
        let data = Data("""
        {"id":"factory","instance":"work","label":"Factory","enabled":true,
         "credentials":[{"account":"api-key","available":\(key)},
                        {"account":"web-session","available":\(browser)}]}
        """.utf8)
        return try JSONDecoder().decode(ProviderRow.self, from: data)
    }

    private func model(available: Bool) async -> FactoryBrowserConnectionModel {
        let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen · synthetic.default")
        let connection = FactoryBrowserConnectionModel(available: available, load: { [profile] },
            importSession: { _ in "Factory browser sign-in saved. Turn on Show Factory usage to check this account." },
            disconnect: { "Factory browser sign-in disconnected." })
        await connection.load()
        return connection
    }

    @Test(arguments: Self.states)
    func browserConnectionIsPrimary(state: (name: String, key: Bool, browser: Bool, reason: String)) async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-factory-test-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let providerRow = try row(key: state.key, browser: state.browser)
        let controls = NSHostingView(rootView: ProviderCredentialControls(row: providerRow, core: core, onChanged: {}))
        controls.frame.size = controls.fittingSize
        controls.layoutSubtreeIfNeeded()
        let rowLabels = PolishRound2Tests.buttonLabels(controls)
        #expect(rowLabels.contains("Connect Factory"))
        let connection = await model(available: state.browser)
        let sheet = NSHostingView(rootView: FactoryConnectionSheet(model: connection, instance: "work", dismiss: {}, onAddAPIKey: {}))
        sheet.frame.size = sheet.fittingSize
        sheet.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(sheet)
        #expect(labels.contains("Use API key…"))
        #expect(labels.contains("Connect"))
        #expect(!connection.canConnect)
        connection.approved = true
        #expect(connection.canConnect)
        connection.selected = nil
        #expect(!connection.approved && !connection.canConnect)
        if !state.key {
            var reading = ProviderSignInRecoveryTests.reading("factory")
            reading.instance = "work"
            reading.reason = state.reason
            let store = UsageCenterStore(core: core)
            store.runProviderAction(reading)
            #expect(store.browserConnectRequests[reading.identity] == 1)
            #expect(store.credentialConnectRequests.isEmpty)
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
            let connection = await model(available: state.browser)
            connection.approved = state.name == "refresh-only"
            if state.name == "refresh-only" { #expect(await connection.connect()) }
            try await U5Proof.render(FactoryConnectionSheet(model: connection, instance: "work", dismiss: {}, onAddAPIKey: {}),
                name: "factory-\(state.name)-sheet", width: 480, dark: dark)
            try await U5Proof.render(ProviderCredentialControls(row: providerRow, core: core, onChanged: {}).padding(20),
                name: "factory-\(state.name)-settings", width: 520, dark: dark)
            try await U5Proof.render(UsageProviderConnection(provider: reading, store: store, row: providerRow).padding(20),
                name: "factory-\(state.name)-usage-center", width: 560, dark: dark)
        }
    }
}
