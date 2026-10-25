import Foundation
@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("History timeline cache")
struct HistoryTimelineCacheTests {
    private func store() -> HistoryStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + UUID().uuidString + ".sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = HistoryStore(core: core, schedulingEnabled: false)
        store.readTimeline = { _ in CoreTimelinePage(events: []) }
        return store
    }

    private func row(_ index: Int) -> CoreHistoryRow {
        CoreHistoryRow(at: Double(index), kind: "started", provider: "claude", session: "claude:fixture-\(index)")
    }

    @Test func cacheEvictsLeastRecentlyOpenedRow() async throws {
        let store = store()
        for index in 0..<32 {
            let task = try #require(store.loadTimeline(for: row(index)))
            await task.value
        }
        #expect(store.expandedTimelines.count == 32)
        #expect(store.loadTimeline(for: row(0)) == nil)
        let next = try #require(store.loadTimeline(for: row(32)))
        await next.value
        #expect(store.expandedTimelines.count == 32)
        #expect(store.timeline(for: row(0)) != nil)
        #expect(store.timeline(for: row(1)) == nil)
        #expect(store.timeline(for: row(32)) != nil)
    }

    @Test func vanishedRowsAndCloseReleaseCachedReconstructions() async throws {
        let store = store()
        for index in 0..<3 {
            let task = try #require(store.loadTimeline(for: row(index)))
            await task.value
        }
        store.adopt(rows: [row(1)])
        #expect(Set(store.expandedTimelines.keys) == [row(1).id])
        store.windowDidClose()
        #expect(store.expandedTimelines.isEmpty)
        #expect(store.failedTimelines.isEmpty)
        #expect(store.expandedLoading.isEmpty)
        #expect(store.expandedID == nil)
    }

    @Test(arguments: [true, false])
    func lateReadCannotRefillEvictedCache(close: Bool) async throws {
        let store = store()
        var resume: CheckedContinuation<CoreTimelinePage, Never>?
        store.readTimeline = { _ in await withCheckedContinuation { resume = $0 } }
        let read = try #require(store.loadTimeline(for: row(0)))
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let pending = try #require(resume)
        if close { store.windowDidClose() }
        else { store.adopt(rows: [row(1)]) }
        pending.resume(returning: CoreTimelinePage(events: []))
        await read.value
        #expect(store.expandedTimelines.isEmpty)
        #expect(store.expandedLoading.isEmpty)
    }
}
