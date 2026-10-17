import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Usage Center store's small decisions that need no daemon: what a
/// refused write means and how provider rows are keyed.
@Suite("Usage Center store")
struct UsageCenterStoreTests {
    private func row(_ id: String, instance: String? = nil, label: String) throws -> ProviderRow {
        let extra = instance.map { #","instance":"\#($0)""# } ?? ""
        let json = #"{"id":"\#(id)","label":"\#(label)"\#(extra)}"#
        return try JSONDecoder().decode(ProviderRow.self, from: Data(json.utf8))
    }

    @Test("a refused write names its reason; an accepted one says nothing")
    func refusal() {
        #expect(UsageCenterStore.refusal(CoreReply(id: "1", ok: true)) == nil)
        let refused = CoreReply(id: "1", ok: false, error: CoreReplyError(code: "invalid_args", message: "usage_graph_days must be 7, 30, 90 or 365"))
        #expect(UsageCenterStore.refusal(refused) == "usage_graph_days must be 7, 30, 90 or 365")
        #expect(UsageCenterStore.refusal(CoreReply(id: "1", ok: false, error: CoreReplyError(code: "busy"))) == "busy")
        #expect(UsageCenterStore.refusal(CoreReply(id: "1", ok: false)) == "refused")
    }

    @Test("two rows claiming one identity keep the first instead of trapping")
    func duplicateRows() throws {
        let rows = [try row("claude", label: "First"), try row("claude", label: "Second"),
                    try row("claude", instance: "work", label: "Work")]
        let keyed = UsageCenterStore.rowsByIdentity(rows)
        #expect(keyed.count == 2)
        #expect(keyed["claude"]?.label == "First")
        #expect(keyed["claude|work"]?.label == "Work")
    }

    @MainActor
    @Test("a reset survives an unrelated event in the same observation turn")
    func coalescedReset() {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-reset-burst.sock")
        let store = UsageCenterStore(core: core)
        core.apply(.event(CoreEvent(id: "reset", kind: "quota_reset", provider: "claude")))
        core.apply(.event(CoreEvent(id: "other", kind: "completed")))
        store.coreDidChange()
        #expect(store.isCelebrating("claude"))
        let pulse = store.resetPulses["claude"]
        store.coreDidChange()
        #expect(store.resetPulses["claude"] == pulse)
    }

    @MainActor
    @Test("a named account reset only celebrates that account")
    func accountReset() async throws {
        let data = Data(#"{"id":"reset-work","kind":"quota_reset","provider":"claude","instance":"work"}"#.utf8)
        let event = try JSONDecoder().decode(CoreEvent.self, from: data)
        #expect(event.instance == "work")
        let roundTrip = try JSONDecoder().decode(CoreEvent.self, from: JSONEncoder().encode(event))
        #expect(roundTrip.instance == "work")
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-reset-account.sock")
        core.handle(.connected)
        let defaultAccount = CoreProviderUsage(id: "claude", state: "ready")
        var workAccount = defaultAccount
        workAccount.instance = "work"
        core.apply(.state(CoreState(usage: CoreUsage(providers: [defaultAccount, workAccount]))))
        let store = UsageCenterStore(core: core)
        store.readHistory = { provider, range in
            UsageHistory(provider: provider, range: range.rawValue, days: [])
        }
        core.apply(.event(event))
        store.coreDidChange()
        #expect(store.isCelebrating("claude|work"))
        #expect(!store.isCelebrating("claude"))
        #expect(!store.isCelebrating("claude|personal"))
        #expect(!store.isLoading(workAccount))
        #expect(store.isLoading(defaultAccount))
        await Task.yield()
    }

}
