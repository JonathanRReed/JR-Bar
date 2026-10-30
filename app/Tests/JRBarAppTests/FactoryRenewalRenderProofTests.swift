import JRBarTestSupport
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory renewal render proof", .serialized, .renderProofAppearance)
struct FactoryRenewalRenderProofTests {
    nonisolated static let states: [String] = ["one-profile", "none", "connected", "waiting", "refused", "disconnected", "forgotten"]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"), arguments: Self.states)
    func proofs(_ state: String) async throws {
        var profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen · synthetic.default")
        let saved = ["connected", "waiting", "refused", "disconnected", "forgotten"].contains(state)
        profile.connected = saved
        profile.consented = saved
        let profiles = state == "none" ? [] : [profile]
        let connection = FactoryBrowserConnectionModel(available: saved, load: { profiles },
            importSession: { _ in "Saved." }, disconnect: { "Disconnected." }, forgetProfile: { _ in })
        await connection.load()
        if state == "disconnected" { await connection.disconnect() }
        if state == "forgotten" { await connection.forget(profile) }
        var reading = CoreProviderUsage(id: "factory", state: "needs_sign_in", reason: "authentication_required")
        reading.observedAt = 1000
        reading.statusText = "Not connected"
        if state == "connected" {
            reading.state = "ready"
            reading.reason = nil
            connection.updateReading(reading)
        }
        if state == "refused" {
            reading.reason = "factory_refresh_invalid_grant"
            reading.statusText = "Factory refused the saved sign-in (invalid_grant). Choose Connect Factory."
            connection.updateReading(reading)
        }
        for dark in [false, true] {
            try await U5Proof.render(FactoryConnectionSheet(model: connection, dismiss: {}, onAddAPIKey: {}),
                name: "renewal-\(state)-sheet", width: 480, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 12) {
                Text("Factory").font(.headline)
                Text(connection.factoryStatus)
                FactorySavedProfiles(model: connection)
            }.padding(20), name: "renewal-\(state)-saved-rows", width: 560, dark: dark)
        }
        #expect(connection.signInProfiles.count == (state == "none" ? 0 : 1))
        if state == "disconnected" || state == "forgotten" {
            #expect(connection.factoryStatus == "Not connected")
            #expect(connection.savedProfiles.isEmpty)
        }
        if state == "refused" {
            #expect(connection.factoryStatus.contains("invalid_grant"))
            let core = CoreModel(socketPath: "/tmp/jrbar-renewal-proof-unused.sock")
            core.handle(.connected)
            core.apply(.state(CoreState()))
            let rowData = Data("""
                {"id":"factory","instance":"default","enabled":true,
                 "credentials":[{"account":"web-session","available":true}]}
                """.utf8)
            let row = try JSONDecoder().decode(ProviderRow.self, from: rowData)
            let store = UsageCenterStore(core: core)
            for dark in [false, true] {
                try await U5Proof.render(VStack(alignment: .leading, spacing: 12) {
                    Text(reading.statusText ?? "")
                    UsageProviderConnection(provider: reading, store: store, row: row, showsRecovery: false)
                }.padding(20), name: "renewal-refused-usage-center", width: 560, dark: dark)
            }
        }
    }
}
