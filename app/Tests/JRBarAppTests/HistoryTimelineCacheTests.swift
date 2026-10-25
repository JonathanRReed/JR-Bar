import AppKit
import Foundation
import SwiftUI
@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("History timeline cache", .timeLimit(.minutes(2)))
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

    @Test func expandedRowRefetchesAnEvictedTimelineOnDemand() async throws {
        let store = store()
        let expanded = row(0)
        var reads = 0
        let started = TestEvents<Void>()
        var finish: CheckedContinuation<CoreTimelinePage, Never>?
        store.readTimeline = { _ in reads += 1; return CoreTimelinePage(events: []) }
        store.toggleExpanded(expanded)
        #expect(await waitForObservedState { !store.isLoadingTimeline(expanded) })
        for index in 1...32 {
            let task = try #require(store.loadTimeline(for: row(index)))
            await task.value
        }
        #expect(store.expandedID == expanded.id)
        #expect(store.timeline(for: expanded) == nil)
        let before = reads
        store.readTimeline = { _ in
            reads += 1
            return await withCheckedContinuation { finish = $0; started.send(()) }
        }
        let host = NSHostingView(rootView: HistoryRowView(row: expanded, store: store, isLast: true))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 360)
        while !store.isLoadingTimeline(expanded), !Task.isCancelled {
            host.layoutSubtreeIfNeeded()
            await drainMainQueue()
        }
        try Task.checkCancellation()
        _ = try await started.next()
        #expect(store.isLoadingTimeline(expanded))
        #expect(store.loadMissingExpandedTimeline(for: expanded) == nil)
        finish?.resume(returning: CoreTimelinePage(events: [
            CoreTimelineItem(seq: 0, kind: "message", role: "assistant", text: "Synthetic work"),
        ]))
        #expect(await waitForObservedState { !store.isLoadingTimeline(expanded) })
        withExtendedLifetime(host) {}
        #expect(reads == before + 1)
        #expect(store.timeline(for: expanded)?.items.count == 1)
        #expect(store.expandedTimelines.count == 32)
        #expect(store.loadMissingExpandedTimeline(for: expanded) == nil)
        #expect(store.loadMissingExpandedTimeline(for: row(1)) == nil)
        if WindowsRenderProofTests.enabled {
            try WindowsRenderProofTests.write("history-evicted-row", size: CGSize(width: 800, height: 360)) {
                HistoryRowView(row: expanded, store: store, isLast: true)
            }
        }
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
