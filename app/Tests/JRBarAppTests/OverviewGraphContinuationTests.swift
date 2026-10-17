import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@MainActor
@Suite struct OverviewGraphContinuationTests {
    private func store() -> OverviewStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-graph-progress-fixture.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = OverviewStore(core: core)
        store.pane = .usage
        store.graphClock = { Date(timeIntervalSince1970: 1_790_000_000) }
        store.fetchGraphProviderIDs = { ["codex"] }
        return store
    }

    private func document(reading: Int, summary: String = "fixture") -> CoreUsageGraphDocument {
        var graph = CoreUsageGraph()
        graph.readingFiles = reading
        return CoreUsageGraphDocument(graph: graph, summary: summary)
    }

    @Test func pendingScanContinuesOnceAndBecomesFreshOnlyWhenComplete() async throws {
        let store = store()
        var count = 0
        store.fetchGraph = { _, _, _ in
            count += 1
            return self.document(reading: count == 1 ? 3 : 0)
        }
        await store.loadGraph()
        #expect(store.graph?.graph.readingFiles == 3)
        #expect(store.graphLoadedAt == nil)
        let deadline = try #require(store.graphNextScanAt)
        #expect(store.continueGraphScanIfDue(at: deadline.addingTimeInterval(-1), visible: true) == nil)
        let continuation = try #require(store.continueGraphScanIfDue(at: deadline, visible: true))
        #expect(store.continueGraphScanIfDue(at: deadline.addingTimeInterval(100), visible: true) == nil)
        await continuation.value
        #expect(count == 2)
        #expect(store.graph?.graph.readingFiles == 0)
        #expect(store.graphLoadedAt != nil)
        #expect(store.graphNextScanAt == nil)
    }

    @Test func stablePartialSourcesDoNotScheduleAnotherScan() async {
        let store = store()
        store.fetchGraph = { _, _, _ in
            var graph = CoreUsageGraph()
            graph.partialProviderIds = ["codex"]
            graph.sourceStatistics = [.init(sourceId: "t3code", label: "T3 Code", dataStatus: "partial")]
            return CoreUsageGraphDocument(graph: graph)
        }
        await store.loadGraph()
        #expect(store.graphLoadedAt != nil)
        #expect(store.graphNextScanAt == nil)
    }

    @Test func hiddenOfflineOrDifferentPaneCannotContinue() async throws {
        let store = store()
        store.fetchGraph = { _, _, _ in self.document(reading: 1) }
        await store.loadGraph()
        let deadline = try #require(store.graphNextScanAt)
        #expect(store.continueGraphScanIfDue(at: deadline, visible: false) == nil)
        store.core.handle(.disconnected(reason: "fixture"))
        #expect(store.continueGraphScanIfDue(at: deadline, visible: true) == nil)
        store.pane = .roster
        #expect(store.graphNextScanAt == nil)
        #expect(store.continueGraphScanIfDue(at: deadline, visible: true) == nil)
    }

    @Test func leavingBeforeDispatchDoesNotSendTheQueuedRequest() async throws {
        let store = store()
        var count = 0
        store.fetchGraph = { _, _, _ in count += 1; return self.document(reading: 1) }
        await store.loadGraph()
        let deadline = try #require(store.graphNextScanAt)
        let continuation = try #require(store.continueGraphScanIfDue(at: deadline, visible: true))
        store.pane = .graph
        store.pane = .usage
        await continuation.value
        #expect(count == 1)
        #expect(store.graphNextScanAt == nil)
    }

    @Test func failureKeepsTheDocumentAndStopsAutomaticRetry() async throws {
        let store = store()
        var count = 0
        store.fetchGraph = { _, _, _ in
            count += 1
            if count == 1 { return self.document(reading: 2, summary: "retained") }
            throw CoreReplyError(code: "fixture", message: "No reply")
        }
        await store.loadGraph()
        let deadline = try #require(store.graphNextScanAt)
        let continuation = try #require(store.continueGraphScanIfDue(at: deadline, visible: true))
        await continuation.value
        #expect(store.graph?.summary == "retained")
        #expect(store.graphError != nil)
        #expect(store.graphNextScanAt == nil)
        #expect(store.continueGraphScanIfDue(at: deadline.addingTimeInterval(100), visible: true) == nil)
    }

    @Test func closeThenLatePartialThenReopenResumesCurrentUsage() async {
        let store = store()
        let gate = OverviewUsageTests.GraphGate()
        store.fetchGraph = { try await gate.fetch($0, $1, $2) }
        let first = Task { await store.loadGraph() }
        await gate.settle(until: 1)
        store.windowDidClose()
        gate.answer(.success(document(reading: 2)))
        await first.value
        #expect(store.graphNextScanAt == nil)
        store.resumeUsageOnOpen()
        await gate.settle(until: 1)
        #expect(gate.asks.count == 2)
        gate.answer(.success(document(reading: 0)))
        for _ in 0..<1_000 where store.graphInFlight { await Task.yield() }
        #expect(store.graphLoadedAt != nil)
    }

    @Test(arguments: [false, true])
    func manualOutcomeBeforeQueuedDispatchStopsTheOldContinuation(failed: Bool) async throws {
        let store = store()
        var count = 0
        store.fetchGraph = { _, _, _ in
            count += 1
            if count == 1 { return self.document(reading: 2) }
            if failed { throw CoreReplyError(code: "fixture", message: "Manual refresh failed") }
            return self.document(reading: 0)
        }
        await store.loadGraph()
        let deadline = try #require(store.graphNextScanAt)
        let queued = try #require(store.continueGraphScanIfDue(at: deadline, visible: true))
        await store.loadGraph()
        await queued.value
        #expect(count == 2)
        #expect((store.graphError != nil) == failed)
        #expect(store.graphNextScanAt == nil)
    }

    @Test func manualPartialReplyReplacesTheQueuedContinuationDeadline() async throws {
        let store = store()
        var count = 0
        store.fetchGraph = { _, _, _ in
            count += 1
            return self.document(reading: 2)
        }
        await store.loadGraph()
        let deadline = try #require(store.graphNextScanAt)
        let queued = try #require(store.continueGraphScanIfDue(at: deadline, visible: true))
        let manualTime = deadline.addingTimeInterval(5)
        store.graphClock = { manualTime }
        await store.loadGraph()
        await queued.value
        #expect(count == 2)
        #expect(store.graphNextScanAt == manualTime.addingTimeInterval(OverviewStore.graphScanRetryInterval))
    }
}
