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
        #expect(UsageCenterStore.refusal(refused) == "usage_graph_days must be 7, 30, 90 or 365.")
        #expect(UsageCenterStore.refusal(CoreReply(id: "1", ok: false, error: CoreReplyError(code: "busy"))) == "The monitor is busy. Try again in a moment.")
        #expect(UsageCenterStore.refusal(CoreReply(id: "1", ok: false)) == "The monitor refused that.")
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
    @Test("overflow reconciles history without replaying decorative pulses")
    func overflowReconciles() async {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude", state: "ready")]))))
        let store = UsageCenterStore(core: core)
        var reads = 0
        store.readHistory = { provider, range in
            reads += 1
            return UsageHistory(provider: provider, range: range.rawValue, days: [])
        }
        store.readProviderRows = { [] }
        store.windowDidOpen()
        for index in 0..<40 {
            core.apply(.event(CoreEvent(id: "overflow-\(index)", kind: index == 39 ? "quota_reset" : "completed", provider: "claude")))
        }
        let tasks = store.coreDidChange()
        for task in tasks { await task.value }
        #expect(reads >= UsageHistoryRange.allCases.count)
        #expect(store.resetPulses.isEmpty)
        store.windowDidClose()
    }

    @MainActor
    @Test("reopening keeps unchanged caches and reconciles all ranges after a closed event gap")
    func reopeningReconcilesOnlyAfterGap() async {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude", state: "ready")]))))
        let store = UsageCenterStore(core: core)
        var ranges: [UsageHistoryRange] = []
        var resetReads = 0
        store.readHistory = { provider, range in
            ranges.append(range)
            return UsageHistory(provider: provider, range: range.rawValue, days: [])
        }
        store.readProviderRows = { [] }
        store.readResetStatus = { _ in resetReads += 1; return CoreReply(id: "fixture", ok: true) }
        for task in store.windowDidOpen() { await task.value }
        store.windowDidClose()
        ranges.removeAll()
        core.apply(.event(CoreEvent(id: "small-burst", kind: "completed")))
        for task in store.windowDidOpen() { await task.value }
        #expect(ranges.isEmpty)
        #expect(resetReads == 2)
        store.windowDidClose()
        ranges.removeAll()
        for index in 0..<40 {
            core.apply(.event(CoreEvent(id: "observed-closed-\(index)", kind: "completed")))
            store.coreDidChange()
        }
        for task in store.windowDidOpen() { await task.value }
        #expect(ranges.isEmpty)
        store.windowDidClose()
        ranges.removeAll()
        for index in 0..<40 {
            core.apply(.event(CoreEvent(id: "closed-overflow-\(index)", kind: "completed")))
        }
        _ = store.coreDidChange()
        let readsBeforeOpen = resetReads
        for task in store.windowDidOpen() { await task.value }
        #expect(Set(ranges.map(\.rawValue)) == Set(UsageHistoryRange.allCases.map(\.rawValue)))
        #expect(resetReads == readsBeforeOpen + 1)
        store.windowDidClose()
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

@MainActor @Suite("Reset save status")
struct ResetSaveStatusTests {
    @Test func failureIsVisibleAndRetryUsesTheCurrentDaemonState() async {
        let store = UsageCenterStore(core: CoreModel())
        var retries: [Bool] = []
        store.readResetStatus = { retry in
            retries.append(retry)
            return CoreReply(id: "fixture", ok: true, result: .object([
                "persistence": .object(["dirty": .bool(!retry),
                                         "error": retry ? .null : .string("refused_full")])]))
        }
        store.readProviderRows = { [] }
        for task in store.windowDidOpen() { await task.value }
        store.windowDidClose()
        #expect(store.resetSaveFailure == "refused_full")
        await store.loadResetStatus(retry: true).value
        #expect(retries == [false, true] && store.resetSaveFailure == nil)
    }
}
