import Foundation
import Testing
@testable import JRBarCore

@Suite("Provider credential commands")
struct ProviderCredentialTests {
    @Test("credential validation trims pasted input and rejects controls or oversized keys")
    func validation() throws {
        #expect(try CoreModel.normalizedProviderSecret("  synthetic-key  ") == "synthetic-key")
        #expect(try CoreModel.normalizedProviderSecret(String(repeating: "x", count: 65536)).utf8.count == 65536)
        for value in ["", "  ", "a\nb", "a\tb", "a\0b", "a\u{200b}b", "a\u{2028}b", String(repeating: "é", count: 32769)] {
            #expect(throws: CoreReplyError.self) { try CoreModel.normalizedProviderSecret(value) }
        }
    }

    @Test("an acknowledgement must name the requested account and operation")
    func acknowledgement() throws {
        let data = Data(#"{"provider":"factory","instance":"work","account":"api-key","available":true}"#.utf8)
        let receipt = try JSONDecoder().decode(ProviderCredentialReceipt.self, from: data)
        #expect(receipt.matches(provider: "factory", instance: "work", account: "api-key", available: true))
        #expect(!receipt.matches(provider: "factory", instance: "default", account: "api-key", available: true))
        #expect(!receipt.matches(provider: "devin", instance: "work", account: "api-key", available: true))
        #expect(!receipt.matches(provider: "factory", instance: "work", account: "token", available: true))
        #expect(!receipt.matches(provider: "factory", instance: "work", account: "api-key", available: false))
    }

    @Test("source option commands carry the exact provider instance and partial patch")
    func sourceOptionsArguments() throws {
        let args = CoreModel.providerOptionsArguments("kimi", options: ["region": "international", "source": "web"], instance: "work")
        #expect(args == ["provider": .string("kimi"), "instance": .string("work"),
                         "options": .object(["region": .string("international"), "source": .string("web")])])
        let clear = CoreModel.providerOptionsArguments("kilo", options: ["organization_id": ""], instance: nil)
        #expect(clear["instance"] == nil)
        #expect(clear["options"] == .object(["organization_id": .string("")]))
        #expect(clear["enabled"] == nil)
    }

    @MainActor
    @Test("offline source option writes fail without claiming saved")
    func sourceOptionsOffline() async {
        let core = CoreModel()
        do {
            _ = try await core.setProviderOptions("kimi", options: ["source": "api"], instance: "work")
            Issue.record("offline source choices reported saved")
        } catch { #expect(error as? CoreClientError == .notConnected) }
    }

    @MainActor
    @Test("offline credential methods await failure instead of reporting saved")
    func offline() async {
        let core = CoreModel()
        do {
            try await core.setProviderCredential("factory", account: "api-key", secret: "synthetic-key", instance: "work")
            Issue.record("offline save reported success")
        } catch { #expect(error as? CoreClientError == .notConnected) }
        do {
            try await core.deleteProviderCredential("factory", account: "api-key", instance: "work")
            Issue.record("offline removal reported success")
        } catch { #expect(error as? CoreClientError == .notConnected) }
    }
}
