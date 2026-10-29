import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("History clear and Undo recovery", .serialized, .timeLimit(.minutes(2)), .renderProofAppearance)
struct HistoryClearRecoveryTests {
    @Test("Clear reports a refusal without refreshing it away")
    func clearRefusalIsVisible() async throws {
        try await withFixture { fixture in
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            var reads = 0
            store.readHistory = { reads += 1; return [] }
            let action = try #require(store.clearCompleted())
            try await fixture.pending(1)
            try await fixture.release(error: "refused")
            await action.value
            #expect(store.notice?.isError == true)
            #expect(store.notice?.text.contains("Synthetic refused") == true)
            #expect(reads == 0)
        }
    }

    @Test("Undo refusal stays visible and does not trigger a history read")
    func undoRefusalIsVisible() async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            var reads = 0
            store.readHistory = { reads += 1; return [] }
            store.undo()
            try await fixture.pending(1)
            try await fixture.release(error: "refused")
            try #require(await fixture.until { store.notice != nil || (reads > 0 && !store.loading) })
            #expect(store.notice?.isError == true)
            #expect(store.notice?.text.contains("Synthetic refused") == true)
            #expect(reads == 0)
            #expect(fixture.core.lastClear?.batch == "old")
        }
    }

    @Test("an older Undo reply cannot retire a newer clear offer")
    func lateUndoKeepsNewOffer() async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let undo = Task { try await fixture.core.undoClear() }
            try await fixture.pending(1)
            let clear = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(2)
            try await fixture.release(index: 1, batch: "new")
            _ = try await clear.value
            #expect(fixture.core.lastClear?.batch == "new")
            try await fixture.release()
            _ = try await undo.value
            #expect(fixture.core.lastClear?.batch == "new")
        }
    }

    @Test("an older clear reply cannot replace a newer clear offer")
    func lateClearKeepsNewOffer() async throws {
        try await withFixture { fixture in
            let first = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(1)
            let second = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(2)
            try await fixture.release(index: 1, batch: "new")
            _ = try await second.value
            try await fixture.release(batch: "old")
            _ = try await first.value
            #expect(fixture.core.lastClear?.batch == "new")
        }
    }

    @Test("an expired or missing current batch is retired", arguments: ["expired", "not_found"])
    func terminalUndoRetiresOffer(_ code: String) async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let undo = Task { try await fixture.core.undoClear() }
            try await fixture.pending(1)
            try await fixture.release(error: code)
            _ = try await undo.value
            #expect(fixture.core.lastClear == nil)
            #expect(!fixture.core.canUndoClear)
        }
    }

    @Test("an ended session keeps Clear completed available")
    func endedSessionIsClearable() {
        let core = CoreModel(socketPath: "/tmp/jrbar-history-unused.sock")
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "codex:synthetic", provider: "codex", mode: "ended", lifecycle: "ended"),
        ])))
        let store = HistoryStore(core: core, schedulingEnabled: false)
        #expect(store.completedCount == 1)
    }

    @Test("Clear waits for acknowledgement and replaces an obsolete read", arguments: [false, true])
    func acknowledgedClearOwnsRefresh(_ oldReadFails: Bool) async throws {
        try await withFixture { fixture in
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            let started = TestEvents<Void>()
            var oldRead: CheckedContinuation<[CoreHistoryRow], Error>?
            defer { oldRead?.resume(throwing: CancellationError()) }
            var reads = 0
            store.readHistory = {
                reads += 1
                if reads == 1 { return try await withCheckedThrowingContinuation { oldRead = $0; started.send(()) } }
                return [CoreHistoryRow(at: 20, kind: "completed")]
            }
            let previous = try #require(store.reload())
            _ = try await started.next()
            let action = try #require(store.clearCompleted())
            #expect(store.pendingAction == .clear)
            #expect(store.clearCompleted() == nil)
            #expect(store.undo() == nil)
            try await fixture.pending(1)
            #expect(reads == 1)
            try await fixture.release(batch: "new")
            await action.value
            #expect(store.pendingAction == nil)
            #expect(store.rows.map(\.at) == [20])
            #expect(reads == 2)
            #expect(store.notice?.text == "Cleared 1 session. Undo is available for 5 minutes.")
            if oldReadFails { oldRead?.resume(throwing: CoreClientError.timeout) }
            else { oldRead?.resume(returning: [CoreHistoryRow(at: 10, kind: "failed")]) }
            oldRead = nil
            await previous.value
            #expect(store.rows.map(\.at) == [20])
            #expect(store.error == nil)
            #expect(!store.loading)
        }
    }

    @Test("successful Undo and failed row refresh remain distinct")
    func undoReceiptSurvivesRefreshFailure() async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            store.rows = [CoreHistoryRow(at: 10, kind: "completed")]
            store.readHistory = { throw CoreClientError.timeout }
            let action = try #require(store.undo())
            #expect(store.pendingAction == .undo)
            try await fixture.pending(1)
            try await fixture.release()
            await action.value
            #expect(store.notice?.text == "Restored 1 session.")
            #expect(store.notice?.isError == false)
            #expect(store.error?.hasPrefix(HistoryStore.loadFailurePrefix) == true)
            #expect(store.rows.map(\.at) == [10])
            #expect(fixture.core.lastClear == nil)
            #expect(store.pendingAction == nil)
        }
    }

    @Test("a disconnected clear or Undo reports failure and preserves the previous offer", arguments: [false, true])
    func disconnectKeepsOffer(_ undo: Bool) async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            let action = try #require(undo ? store.undo() : store.clearCompleted())
            try await fixture.pending(1)
            fixture.core.stop()
            await action.value
            #expect(store.notice?.isError == true)
            #expect(store.notice?.text.contains(MonitorWords.sentence) == true)
            #expect(store.pendingAction == nil)
            #expect(fixture.core.lastClear?.batch == "old")
        }
    }

    @Test("a successful no-op clear keeps the earlier Undo offer")
    func noOpKeepsOffer() async throws {
        try await withFixture { fixture in
            try await fixture.seed("old")
            let clear = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(1)
            try await fixture.release(cleared: [])
            _ = try await clear.value
            #expect(fixture.core.lastClear?.batch == "old")
        }
    }

    @Test("a newer failed or no-op clear does not discard an older successful reply", arguments: [false, true])
    func noNewBatchKeepsOlderSuccess(_ refuse: Bool) async throws {
        try await withFixture { fixture in
            let first = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(1)
            let second = Task { try await fixture.core.clearCompletedNow() }
            try await fixture.pending(2)
            try await fixture.release(index: 1, error: refuse ? "refused" : nil, cleared: [])
            _ = try await second.value
            try await fixture.release(batch: "old")
            _ = try await first.value
            #expect(fixture.core.lastClear?.batch == "old")
        }
    }

    @Test("stale sessions keep Clear available while live working sessions do not")
    func staleSessionIsClearable() {
        let core = CoreModel(socketPath: "/tmp/jrbar-history-unused.sock")
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "codex:stale", provider: "codex", mode: "working", stale: true),
            CoreSession(id: "codex:live", provider: "codex", mode: "working"),
        ])))
        #expect(HistoryStore(core: core, schedulingEnabled: false).completedCount == 1)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func clearRefusalRenderProof() async throws {
        try await withFixture { fixture in
            let store = HistoryStore(core: fixture.core, schedulingEnabled: false)
            store.rows = [CoreHistoryRow(at: Date().timeIntervalSince1970, kind: "completed", provider: "codex", label: "Synthetic session")]
            let action = try #require(store.clearCompleted())
            try await fixture.pending(1)
            try await fixture.release(error: "refused")
            await action.value
            try WindowsRenderProofTests.write("history-clear-refused", size: CGSize(width: 680, height: 420)) {
                HistoryView(store: store)
            }
        }
    }

    private func withFixture(_ body: (CoreCommandReplyFixture) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        do {
            try await fixture.start()
            try await body(fixture)
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}
