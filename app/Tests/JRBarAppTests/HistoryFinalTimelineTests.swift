import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("History final timeline")
struct HistoryFinalTimelineTests {
    private let row = CoreHistoryRow(at: 10, kind: "started", provider: "claude", session: "claude:fixture")

    private func store(running: Bool = true) -> HistoryStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-final-history-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: running ? [CoreSession(id: "claude:fixture", provider: "claude", mode: "working")] : [])))
        return HistoryStore(core: core, schedulingEnabled: false)
    }

    private func page(final: Bool) -> CoreTimelinePage {
        let message = CoreTimelineItem(seq: 0, kind: "message", role: "assistant", text: "Synthetic work")
        let end = CoreTimelineItem(seq: 1, kind: "turn_end")
        return CoreTimelinePage(events: final ? [message, end] : [message])
    }

    @Test("a page read during a run gets one final read and then stays cached")
    func completionRefreshesOnce() async throws {
        let store = store()
        var reads = 0
        store.readTimeline = { _ in reads += 1; return page(final: reads > 1) }
        let initial = try #require(store.loadTimeline(for: row))
        await initial.value
        #expect(store.timeline(for: row)?.items.count == 1)
        store.core.apply(.state(CoreState()))
        let final = try #require(store.loadTimeline(for: row))
        await final.value
        #expect(store.timeline(for: row)?.items.count == 2)
        #expect(store.timeline(for: row)?.story.diedMidTurn == false)
        #expect(store.loadTimeline(for: row) == nil)
        #expect(reads == 2)
    }

    @Test("a finished run cached on its first read needs no extra fetch")
    func finishedFirstRead() async throws {
        let store = store(running: false)
        var reads = 0
        store.readTimeline = { _ in reads += 1; return page(final: true) }
        let task = try #require(store.loadTimeline(for: row))
        await task.value
        #expect(store.loadTimeline(for: row) == nil)
        #expect(reads == 1)
    }

    @Test("a failed final read stays retryable instead of becoming the final cache")
    func failedFinalRead() async throws {
        let store = store()
        store.readTimeline = { _ in page(final: false) }
        let initial = try #require(store.loadTimeline(for: row))
        await initial.value
        store.core.apply(.state(CoreState()))
        store.readTimeline = { _ in throw CoreClientError.timeout }
        let failed = try #require(store.loadTimeline(for: row))
        await failed.value
        #expect(store.failedTimelines.contains(row.id))
        store.readTimeline = { _ in page(final: true) }
        let retry = try #require(store.loadTimeline(for: row))
        await retry.value
        #expect(!store.failedTimelines.contains(row.id))
        #expect(store.timeline(for: row)?.items.count == 2)
        #expect(store.loadTimeline(for: row) == nil)
    }
}
