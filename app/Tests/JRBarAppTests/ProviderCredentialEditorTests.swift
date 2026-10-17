import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Provider credential editor")
struct ProviderCredentialEditorTests {
    @MainActor
    final class Recorder {
        var saved: [String] = []
        var removed = 0
        var changed = 0
    }

    @MainActor
    final class Gate {
        var continuation: CheckedContinuation<Void, Error>?
        var started: CheckedContinuation<Void, Never>?
        var calls = 0

        func run() async throws {
            calls += 1
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.started?.resume()
                self.started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func finish() { continuation?.resume(); continuation = nil }
    }

    @Test("availability facts survive credential writes and retired results stay silent",
          arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func availabilityDuringWrite(removing: Bool, outcome: (Bool, Bool)) async {
        let (retired, fails) = outcome
        let gate = Gate()
        let recorder = Recorder()
        let operation: @MainActor () async throws -> Void = {
            try await gate.run()
            if fails { throw CoreReplyError(code: "credential_unavailable", message: "synthetic-secret") }
        }
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "default", account: "api-key",
            available: removing, save: { _ in try await operation() }, remove: operation,
            onChanged: { recorder.changed += 1 })
        model.secret = "synthetic-key"
        let pending = Task {
            if removing { await model.remove(); return false }
            return await model.save()
        }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        model.updateAvailability(removing)
        model.updateAvailability(!removing)
        #expect(model.available == removing)
        if retired { model.cancel() }
        gate.finish()
        let saved = await pending.value
        #expect(model.available == !removing)
        #expect(!model.busy)
        #expect(model.secret.isEmpty)
        #expect(recorder.changed == ((!retired && !fails) ? 1 : 0))
        #expect(saved == (!removing && !retired && !fails))
        if retired { #expect(model.message == nil) }
        #expect(model.message?.contains("synthetic-secret") != true)
    }

    @Test("current credential acknowledgements supersede earlier availability facts", arguments: [false, true])
    func acknowledgementWins(removing: Bool) async {
        let gate = Gate()
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "default", account: "api-key",
            available: removing, save: { _ in try await gate.run() }, remove: { try await gate.run() })
        model.secret = "synthetic-key"
        let pending = Task {
            if removing { await model.remove() } else { _ = await model.save() }
        }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        model.updateAvailability(removing)
        gate.finish()
        await pending.value
        #expect(model.available == !removing)
    }

    private func editor(_ recorder: Recorder, instance: String = "default") -> ProviderCredentialEditorModel {
        ProviderCredentialEditorModel(provider: "factory", instance: instance, account: "api-key", available: false,
            save: { recorder.saved.append($0) }, remove: { recorder.removed += 1 },
            onChanged: { recorder.changed += 1 })
    }

    @Test("saving trims the key, clears the field and changes only its credential")
    func save() async {
        let recorder = Recorder()
        let model = editor(recorder, instance: "work")
        model.secret = "  synthetic-key  "
        let saved = await model.save()
        #expect(saved)
        #expect(recorder.saved == ["synthetic-key"])
        #expect(recorder.removed == 0)
        #expect(recorder.changed == 1)
        #expect(model.available)
        #expect(model.secret.isEmpty)
        #expect(model.instance == "work")
        #expect(model.message == "API key saved. The usage switch controls requests.")
    }

    @Test("provider key edits keep other providers and instances untouched")
    func genericProviderIsolation() async {
        var keys = ["factory:work": "factory-key", "kimi:work": "kimi-key", "kilo:work": "kilo-key",
                    "kimi:personal": "personal-kimi", "kilo:personal": "personal-kilo"]
        let models = ["factory", "kimi", "kilo"].map { provider in
            ProviderCredentialEditorModel(provider: provider, instance: "work", account: "api-key", available: true,
                save: { keys["\(provider):work"] = $0 }, remove: { _ = keys.removeValue(forKey: "\(provider):work") })
        }
        #expect(models.map(\.providerName) == ["Factory", "Kimi Code", "Kilo"])
        models[1].secret = "replacement-kimi"
        let saved = await models[1].save()
        #expect(saved)
        await models[2].remove()
        #expect(keys == ["factory:work": "factory-key", "kimi:work": "replacement-kimi",
                         "kimi:personal": "personal-kimi", "kilo:personal": "personal-kilo"])
        #expect(models[0].available)
        #expect(models[1].available)
        #expect(!models[2].available)
        #expect(models.allSatisfy { $0.instance == "work" && $0.account == "api-key" })
    }

    @Test("a failed replacement does not dismiss an existing key editor")
    func replacementFailure() async {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key", available: true,
            save: { _ in throw CoreReplyError(code: "credential_unavailable") }, remove: {})
        model.secret = "synthetic-key"
        let saved = await model.save()
        #expect(!saved)
        #expect(model.available)
        #expect(model.secret.isEmpty)
    }

    @Test("empty and cancelled edits send nothing")
    func emptyAndCancel() async {
        let recorder = Recorder()
        let model = editor(recorder)
        await model.save()
        model.secret = "synthetic-key"
        model.cancel()
        await model.save()
        #expect(model.secret.isEmpty)
        #expect(recorder.saved.isEmpty)
        #expect(recorder.changed == 0)
    }

    @Test("remove clears availability without saving a key")
    func remove() async {
        let recorder = Recorder()
        let model = editor(recorder)
        model.secret = "synthetic-key"
        await model.remove()
        #expect(recorder.removed == 1)
        #expect(recorder.saved.isEmpty)
        #expect(recorder.changed == 1)
        #expect(!model.available)
        #expect(model.secret.isEmpty)
    }

    @Test("held saves deduplicate and retired completions cannot change another account")
    func heldSave() async {
        let gate = Gate()
        let old = Recorder()
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key", available: false,
            save: { _ in try await gate.run() }, remove: {}, onChanged: { old.changed += 1 })
        model.secret = "synthetic-key"
        let pending = Task { await model.save() }
        await gate.waitUntilStarted()
        #expect(model.busy)
        #expect(model.secret.isEmpty)
        await model.save()
        await model.remove()
        #expect(gate.calls == 1)
        model.cancel()
        let other = editor(Recorder(), instance: "personal")
        gate.finish()
        await pending.value
        #expect(old.changed == 0)
        #expect(model.message == nil)
        #expect(!model.available)
        #expect(!other.available)
        #expect(!model.busy)
    }

    @Test("storage messages never become visible and the failed key is cleared")
    func redactedError() async {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "default", account: "api-key", available: false,
            save: { _ in throw CoreReplyError(code: "credential_unavailable", message: "synthetic-key") },
            remove: { throw CoreReplyError(code: "synthetic-key", message: "synthetic-key") })
        model.secret = "synthetic-key"
        await model.save()
        #expect(model.secret.isEmpty)
        #expect(model.message == "Could not save the API key. Enter it again and retry.")
        await model.remove()
        #expect(model.message == "Could not remove the API key. Try again.")
    }

    @Test("offline failures explain how to retry")
    func offline() async {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "default", account: "api-key", available: false,
            save: { _ in throw CoreClientError.notConnected }, remove: {})
        model.secret = "synthetic-key"
        await model.save()
        #expect(model.message == "Monitor offline. Reconnect and try again.")
        #expect(model.secret.isEmpty)
    }
}

@MainActor
@Suite("Provider credential removal lifetime")
struct ProviderCredentialRemovalLifetimeTests {
    @Test("a dismissed removal cannot publish a late acknowledgement")
    func heldRemove() async {
        let gate = ProviderCredentialEditorTests.Gate()
        let recorder = ProviderCredentialEditorTests.Recorder()
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "work", account: "api-key", available: true,
            save: { _ in recorder.saved.append("unexpected") }, remove: { try await gate.run() },
            onChanged: { recorder.changed += 1 })
        let pending = Task { await model.remove() }
        await gate.waitUntilStarted()
        await model.remove()
        #expect(gate.calls == 1)
        model.cancel()
        gate.finish()
        await pending.value
        #expect(model.available)
        #expect(model.message == nil)
        #expect(recorder.changed == 0)
        #expect(recorder.saved.isEmpty)
        #expect(!model.busy)
    }
}

@MainActor
@Suite("Provider source choices")
struct ProviderSourceOptionsTests {
    private func row(_ provider: String = "kimi", instance: String = "default", options: [String: String] = [:]) throws -> ProviderRow {
        let document: [String: Any] = ["id": provider, "instance": instance, "options": options,
            "usage_consent": ["granted": false, "version": 1]]
        return try JSONDecoder().decode(ProviderRow.self, from: JSONSerialization.data(withJSONObject: document))
    }

    @Test("draft choices wait for Save and follow the persisted reply without enabling usage")
    func explicitSave() async throws {
        var patches: [[String: String]] = []
        var accepted: [ProviderRow] = []
        let persisted = try row(options: ["region": "international", "source": "web"])
        let model = ProviderSourceOptionsModel(row: try row(), write: { patches.append($0); return persisted },
                                               onSaved: { accepted.append($0) })
        model.region = "international"
        model.source = "web"
        #expect(patches.isEmpty)
        let saved = await model.save()
        #expect(saved)
        #expect(patches == [["region": "international", "source": "web"]])
        #expect(accepted == [persisted])
        #expect(accepted[0].usageConsent?.granted == false)
        #expect(model.region == "international" && model.source == "web")
    }

    @Test("Kimi CLI selection cannot borrow the default China credential", arguments: ["work", "default"])
    func cliScope(instance: String) async throws {
        let model = ProviderSourceOptionsModel(row: try row(instance: instance),
            write: { _ in Issue.record("ineligible CLI scope wrote options"); return try row() })
        model.source = "cli"
        if instance == "default" { model.region = "international" }
        let saved = await model.save()
        #expect(!saved)
        #expect(!model.cliAvailable)
    }

    @Test("empty Kilo organization explicitly saves personal usage")
    func personalKilo() async throws {
        var patch: [String: String] = [:]
        let persisted = try row("kilo")
        let model = ProviderSourceOptionsModel(row: try row("kilo", options: ["organization_id": "synthetic-org"]),
            write: { patch = $0; return persisted })
        model.organizationID = "  "
        let saved = await model.save()
        #expect(saved)
        #expect(patch == ["organization_id": ""])
        #expect(model.organizationID.isEmpty)
    }

    @Test("duplicate saves and retired completions cannot publish source choices")
    func retiredSave() async throws {
        let gate = ProviderCredentialEditorTests.Gate()
        var accepted = 0
        let persisted = try row(options: ["source": "api"])
        let model = ProviderSourceOptionsModel(row: try row(), write: { _ in try await gate.run(); return persisted },
                                               onSaved: { _ in accepted += 1 })
        let pending = Task { await model.save() }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        let duplicate = await model.save()
        #expect(!duplicate && gate.calls == 1)
        model.cancel()
        gate.finish()
        let saved = await pending.value
        #expect(!saved)
        #expect(accepted == 0 && model.message == nil && !model.busy)
    }

    @Test("source write failures stay visible and redact backend detail")
    func failure() async throws {
        let model = ProviderSourceOptionsModel(row: try row(), write: { _ in
            throw CoreReplyError(code: "invalid_args", message: "synthetic-secret")
        })
        let saved = await model.save()
        #expect(!saved)
        #expect(model.message == "Could not save source choices. Check the values and retry.")
    }

    @Test("manual web tokens keep their own account and accurate labels")
    func manualToken() async {
        var saved: [String] = []
        let model = ProviderCredentialEditorModel(provider: "kimi", instance: "work", account: "web-session",
            available: false, save: { saved.append($0) }, remove: {})
        #expect(model.credentialName == "web token")
        model.secret = "synthetic-web-token"
        let succeeded = await model.save()
        #expect(succeeded && saved == ["synthetic-web-token"])
        #expect(model.account == "web-session")
        #expect(model.message == "Web token saved. The usage switch controls requests.")
    }
}
