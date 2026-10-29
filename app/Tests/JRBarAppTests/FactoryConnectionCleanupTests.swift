import AppKit
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Factory connection and provider detail cleanup", .serialized, .renderProofAppearance)
struct FactoryConnectionCleanupTests {
    @Test("opening and typing stay local until each explicit action")
    func explicitActions() async {
        var opened = 0
        var saved = 0
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
            available: false, save: { _ in saved += 1 }, remove: {},
            openFactoryKeyPage: { opened += 1; return true })
        model.beginEditing()
        model.secret = "synthetic-key"
        #expect(opened == 0 && saved == 0)
        model.beginConnection()
        #expect(opened == 1 && saved == 0)
        model.secret = "synthetic-key"
        #expect(saved == 0)
        #expect(await model.save())
        #expect(saved == 1 && opened == 1)
        #expect(model.message == "Factory key validated and saved. The usage switch controls ongoing requests.")
        model.beginConnection()
        #expect(opened == 1, "Replacing a saved key does not open the key creation page")
    }

    @Test("browser opening failure leaves the editor and its retry link available")
    func browserFailure() {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
            available: false, save: { _ in }, remove: {}, openFactoryKeyPage: { false })
        model.beginConnection()
        #expect(model.message == "Could not open Factory. Use Create a Factory API key below.")
        #expect(!model.available && !model.busy)
    }

    @Test("Factory validation failures remain visible without exposing server details",
          arguments: ["authentication_required", "usage_access_denied", "rate_limited", "network_unavailable", "invalid_response"])
    func validationFailure(_ code: String) async {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
            available: true, save: { _ in throw CoreReplyError(code: code, message: "synthetic-secret") }, remove: {})
        model.secret = "synthetic-key"
        #expect(await model.save() == false)
        #expect(model.available && model.secret.isEmpty)
        #expect(model.message != nil && model.message?.contains("synthetic-secret") == false)
    }

    @Test("every provider names the account instead of the recovery action", arguments: PolishRound2Tests.providerIDs)
    func accountNames(_ providerID: String) {
        var reading = CoreProviderUsage(id: providerID, state: "needs_sign_in", action: "Connect synthetic account")
        #expect(UsageCenterStore.accountLine(reading, history: nil) == "Default")
        reading.instance = "work"
        #expect(UsageCenterStore.accountLine(reading, history: nil) == "work")
        reading.account = UsageAccount(label: "Sample account")
        #expect(UsageCenterStore.accountLine(reading, history: nil) == "Sample account")
    }

    private func fixture(_ providerID: String = "factory", key: Bool = false, consent: Bool = true,
                         reason: String = "authentication_required") async throws -> (UsageCenterStore, ProviderRow, CoreProviderUsage) {
        let data: [String: Any] = ["id": providerID, "instance": "default", "enabled": true,
            "credentials": [["account": "api-key", "available": key]],
            "usage_consent": ["granted": consent, "version": 1,
                "detail": "Asks api.factory.ai for Standard and Core usage windows with your saved API key first. An older imported access token can still be used while valid; a previously approved browser profile may repair it. JR-Bar never uses browser refresh tokens or Droid credentials. Save API key checks the key once; this switch controls ongoing usage requests."]]
        let row = try JSONDecoder().decode(ProviderRow.self, from: JSONSerialization.data(withJSONObject: data))
        var reading = CoreProviderUsage(id: providerID, state: "needs_sign_in",
            action: providerID == "factory" ? "Add Factory API key" : "Connect synthetic account", reason: reason)
        reading.actionKind = "manage"
        reading.readAt = 1_800_000_000 - 120
        reading.statusText = reason == "browser_token_unavailable" ? "Add a Factory API key to read usage." : "Sign-in required"
        if key {
            reading.state = "ready"
            reading.statusText = nil
            reading.account = UsageAccount(label: "Sample account", fidelity: "official")
            reading.action = nil
            reading.actionKind = nil
            reading.windows = [CoreUsageWindow(name: "5h", usedPct: 25)]
        }
        let core = CoreModel(socketPath: "/tmp/jrbar-factory-cleanup-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [reading]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: 1_800_000_000)
        store.readProviderRows = { [row] }
        await store.loadProviderRows()?.value
        return (store, row, reading)
    }

    @Test("a managed Factory detail offers the key action once")
    func oneAction() async throws {
        let (store, _, reading) = try await fixture()
        let detail = UsageProviderDetail(provider: reading, store: store, showCost: false)
        #expect(detail.connectionOwnsAction)
        let host = NSHostingView(rootView: detail.frame(width: 570))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(host)
        #expect(labels.filter { $0 == "Add Factory API key" }.count == 1)
        #expect(!labels.contains("Fix sign-in"))
    }

    @Test("every detail keeps staged recovery in one place", arguments: PolishRound2Tests.providerIDs)
    func stagedActions(_ providerID: String) async throws {
        let (store, row, reading) = try await fixture(providerID)
        let detail = UsageProviderDetail(provider: reading, store: store, showCost: false)
        let connection = UsageProviderConnection(provider: reading, store: store, row: row, showsRecovery: false)
        let host = NSHostingView(rootView: connection.frame(width: 570))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(host)
        #expect(!labels.contains("Fix sign-in"))
        #expect(!labels.contains("Re-sign in"))
        let managed = ["factory", "devin", "kimi", "kilo"].contains(providerID)
        #expect(detail.connectionOwnsAction == managed)
        var consentReading = reading
        consentReading.state = "needs_consent"
        consentReading.reason = "usage_consent_required"
        let consentDetail = UsageProviderDetail(provider: consentReading, store: store, showCost: false)
        #expect(consentDetail.connectionOwnsAction)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func factoryProofs() async throws {
        let states: [(name: String, key: Bool, reason: String)] = [
            ("no-key", false, "authentication_required"),
            ("saved", true, ""),
            ("refresh-only", false, "browser_token_unavailable"),
            ("expired", false, "browser_session_expired"),
        ]
        let suite = "jrbar-factory-proof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("factory", forKey: "usageCenter.provider")
        for state in states {
            let (store, row, _) = try await fixture(key: state.key, reason: state.reason)
            for dark in [false, true] {
                try await DesignFixBProof.write(UsageCenterView(store: store).defaultAppStorage(defaults),
                    name: "factory-\(state.name)-minimum-window", title: "Usage Center",
                    size: CGSize(width: 800, height: 480), dark: dark)
                if state.name == "no-key" || state.key {
                    try await U5Proof.render(ProviderUsageSwitchRow(row: row, model: ProviderUsageSwitchesModel(), core: store.core).padding(20),
                        name: "factory-\(state.name)-row", width: 580, dark: dark)
                }
            }
        }
        for dark in [false, true] {
            let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
                available: false, save: { _ in }, remove: {})
            try await U5Proof.render(ProviderCredentialEditor(model: model, dismiss: {}),
                name: "factory-connect-sheet", width: 420, dark: dark)
            let gate = ProviderCredentialEditorTests.Gate()
            defer { gate.finish() }
            let checking = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
                available: false, save: { _ in try await gate.run() }, remove: {})
            checking.secret = "synthetic-key"
            let pending = Task { await checking.save() }
            await gate.waitUntilStarted()
            try await U5Proof.render(ProviderCredentialEditor(model: checking, dismiss: {}),
                name: "factory-checking-sheet", width: 420, dark: dark)
            gate.finish()
            #expect(await pending.value == false)
            let validated = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
                available: false, save: { _ in }, remove: {})
            validated.secret = "synthetic-key"
            #expect(await validated.save())
            try await U5Proof.render(ProviderCredentialEditor(model: validated, dismiss: {}),
                name: "factory-validated-sheet", width: 420, dark: dark)
            let failed = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key",
                available: false, save: { _ in throw CoreReplyError(code: "usage_access_denied") }, remove: {})
            failed.secret = "synthetic-key"
            #expect(await failed.save() == false)
            try await U5Proof.render(ProviderCredentialEditor(model: failed, dismiss: {}),
                name: "factory-denied-sheet", width: 420, dark: dark)
        }
    }
}
