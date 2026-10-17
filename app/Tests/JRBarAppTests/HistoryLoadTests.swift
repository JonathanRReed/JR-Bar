import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("History read acknowledgements")
struct HistoryLoadTests {
    private func makeStore() -> HistoryStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-test.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        return HistoryStore(core: core, schedulingEnabled: false)
    }

    @Test("a visit acknowledges history only after the first successful read")
    func acknowledgesAfterRead() async throws {
        let store = makeStore()
        let gate = HistoryReadGate()
        var marks = 0
        store.readHistory = { try await gate.read() }
        store.markSeen = { marks += 1 }
        let task = try #require(store.windowDidOpen())
        let didStart = await gate.waitUntilStarted()
        try #require(didStart, "History read did not start")
        #expect(marks == 0)
        gate.finish([CoreHistoryRow(at: 10, kind: "failed", unseen: true)])
        await task.value
        #expect(store.away?.counts["failed"] == 1)
        #expect(marks == 1)
        store.windowDidClose()
    }

    @Test("a failed read and closing without a read leave history unseen")
    func failureDoesNotAcknowledge() async throws {
        let store = makeStore()
        var marks = 0
        store.readHistory = { throw CoreClientError.timeout }
        store.markSeen = { marks += 1 }
        let task = try #require(store.windowDidOpen())
        await task.value
        #expect(store.error?.hasPrefix(HistoryStore.loadFailurePrefix) == true)
        #expect(!store.loading)
        store.windowDidClose()
        #expect(marks == 0)
    }

    @Test("a reply from an earlier visit cannot replace the reopened window's rows")
    func oldVisitIsDiscarded() async throws {
        let store = makeStore()
        let gate = HistoryReadGate()
        var marks = 0
        store.readHistory = { try await gate.read() }
        store.markSeen = { marks += 1 }
        let oldTask = try #require(store.windowDidOpen())
        let didStart = await gate.waitUntilStarted()
        try #require(didStart, "History read did not start")
        store.windowDidClose()
        store.readHistory = { [CoreHistoryRow(at: 20, kind: "completed", unseen: true)] }
        let newTask = try #require(store.windowDidOpen())
        await newTask.value
        gate.finish([CoreHistoryRow(at: 10, kind: "failed", unseen: true)])
        await oldTask.value
        #expect(store.rows.map(\.at) == [20])
        #expect(store.away?.counts == ["completed": 1])
        #expect(marks == 1)
        #expect(!store.loading)
        store.windowDidClose()
    }

    @Test("a clock tick queued before close cannot start another read")
    func queuedTickAfterClose() async throws {
        let store = makeStore()
        var reads = 0
        var marks = 0
        store.readHistory = {
            reads += 1
            throw CoreClientError.timeout
        }
        store.markSeen = { marks += 1 }
        let initial = try #require(store.windowDidOpen())
        await initial.value
        #expect(reads == 1)
        let queuedTick = Task { store.refreshOnClockTick() }
        store.windowDidClose()
        let refresh = await queuedTick.value
        if let refresh { await refresh.value }
        #expect(refresh == nil)
        #expect(reads == 1)
        #expect(marks == 0)
        #expect(!store.loading)
    }
}

@MainActor
private final class HistoryReadGate {
    private var started = false
    private var result: CheckedContinuation<[CoreHistoryRow], Error>?

    func read() async throws -> [CoreHistoryRow] {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            started = true
        }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !started {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            await Task.yield()
        }
        return !Task.isCancelled
    }

    func finish(_ rows: [CoreHistoryRow]) {
        result?.resume(returning: rows)
        result = nil
    }
}
