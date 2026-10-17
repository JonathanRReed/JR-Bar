import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Roster and transcript loads overlap in the Overview (an event burst, the
/// stale tick, ⌘R, a pin), and each reply is decoded off the main actor, so
/// two of them can finish in either order. The load that started last is the
/// only one whose answer is shown: an older reply landing late must not leave
/// the table one reply behind. The replies here are released by hand, so no
/// timer runs and nothing sleeps.
@Suite("Overview load order")
@MainActor
struct OverviewLoadOrderTests {
    /// A reply source that holds every request until the test releases it,
    /// in whatever order the test likes.
    @MainActor
    final class Gate<Value: Sendable> {
        private var pending: [CheckedContinuation<Value, Error>] = []
        private var watchers: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []
        var requestCount: Int { pending.count }

        /// A request arrives and waits for its reply.
        func request() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                let ready = watchers.filter { pending.count >= $0.count }
                watchers.removeAll { pending.count >= $0.count }
                for watcher in ready { watcher.resume.resume() }
            }
        }

        /// Suspends until `count` requests have arrived.
        func untilRequests(_ count: Int) async {
            if pending.count >= count { return }
            await withCheckedContinuation { resume in watchers.append((count, resume)) }
        }

        /// Answer the `call`-th request (1 is the first to arrive).
        func answer(_ call: Int, with value: Value) { pending[call - 1].resume(returning: value) }
        func fail(_ call: Int, with error: Error) { pending[call - 1].resume(throwing: error) }
    }

    private struct Refused: Error {}

    private func roster(_ ids: String...) throws -> CoreRoster {
        let rows = ids.map { #"{"id":"\#($0)","provider":"claude","mode":"working"}"# }
        let counts = #"{"total":\#(ids.count),"workers":0,"attention":0,"live":\#(ids.count),"finished":0,"hidden_from_panel":0,"listed":\#(ids.count)}"#
        let json = #"{"sessions":[\#(rows.joined(separator: ","))],"counts":\#(counts)}"#
        return try JSONDecoder().decode(CoreRoster.self, from: Data(json.utf8))
    }

    private func page(_ text: String) throws -> CoreTimelinePage {
        let json = #"{"events":[{"seq":1,"kind":"message","text":"\#(text)"}],"has_more":false,"total":1,"gaps":[]}"#
        return try JSONDecoder().decode(CoreTimelinePage.self, from: Data(json.utf8))
    }

    private func makeStore(_ gate: Gate<CoreRoster>) -> OverviewStore {
        let store = OverviewStore(core: CoreModel())
        store.fetchRoster = { try await gate.request() }
        return store
    }

    // MARK: The roster

    @Test("background polling coalesces a slow roster read and retries after failure",
          .timeLimit(.minutes(1)))
    func backgroundPollingDoesNotStarveSlowReads() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let first = Task { await store.loadBackground() }
        await gate.untilRequests(1)
        for tick in 1...20 {
            store.now = Date(timeIntervalSince1970: Double(tick))
            await store.loadBackground()
            store.scheduleLoad()
        }
        #expect(gate.requestCount == 1)
        gate.answer(1, with: try roster("claude:slow"))
        await first.value
        #expect(store.roster.map(\.id) == ["claude:slow"])
        let failed = Task { await store.loadBackground() }
        await gate.untilRequests(2)
        gate.fail(2, with: Refused())
        await failed.value
        #expect(store.error != nil)
        let retry = Task { await store.loadBackground() }
        await gate.untilRequests(3)
        gate.answer(3, with: try roster("claude:recovered"))
        await retry.value
        #expect(store.roster.map(\.id) == ["claude:recovered"])
        #expect(store.error == nil)
    }

    @Test("explicit refresh replaces a pending background read",
          .timeLimit(.minutes(1)))
    func explicitRefreshSupersedesBackgroundRead() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let background = Task { await store.loadBackground() }
        await gate.untilRequests(1)
        let explicit = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(2)
        gate.answer(1, with: try roster("claude:old"))
        await background.value
        await store.loadBackground()
        #expect(gate.requestCount == 2)
        #expect(store.loading)
        gate.answer(2, with: try roster("claude:new"))
        await explicit.value
        #expect(store.roster.map(\.id) == ["claude:new"])
        #expect(!store.loading)
    }

    @Test("events during a roster read earn one follow-up without replacing the pending read",
          .timeLimit(.minutes(1)))
    func eventsDuringReadAreNotLost() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let first = Task { await store.loadBackground() }
        await gate.untilRequests(1)
        for _ in 0..<10 { store.scheduleLoad(eventDriven: true) }
        #expect(gate.requestCount == 1)
        gate.answer(1, with: try roster("claude:before-event"))
        await first.value
        #expect(store.roster.map(\.id) == ["claude:before-event"])
        await gate.untilRequests(2)
        #expect(gate.requestCount == 2)
        gate.answer(2, with: try roster("claude:after-event"))
        // A third explicit read fences the follow-up's completion without
        // depending on a timer or a yield count.
        let fence = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(3)
        gate.answer(3, with: try roster("claude:after-event"))
        await fence.value
        #expect(store.roster.map(\.id) == ["claude:after-event"])
    }

    @Test("closing the window drops the pending event follow-up",
          .timeLimit(.minutes(1)))
    func closeDropsEventFollowUp() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let first = Task { await store.loadBackground() }
        await gate.untilRequests(1)
        store.scheduleLoad(eventDriven: true)
        store.windowDidClose()
        gate.answer(1, with: try roster("claude:closed"))
        await first.value
        #expect(gate.requestCount == 1)
    }

    @Test("an older roster load that finishes last does not overwrite the newer one",
          .timeLimit(.minutes(1)))
    func olderRosterLoadLandingLateIsDropped() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let older = Task { await store.load() }
        await gate.untilRequests(1)
        let newer = Task { await store.load() }
        await gate.untilRequests(2)

        gate.answer(2, with: try roster("claude:newer-1", "claude:newer-2"))
        await newer.value
        #expect(store.roster.map(\.id) == ["claude:newer-1", "claude:newer-2"])

        gate.answer(1, with: try roster("claude:older"))
        await older.value
        #expect(store.roster.map(\.id) == ["claude:newer-1", "claude:newer-2"],
                "the older reply landed last and must not win")
        #expect(store.counts.total == 2)
        #expect(store.error == nil)
    }

    @Test("loads that finish in order show the last one, as they always did", .timeLimit(.minutes(1)))
    func inOrderLoadsShowTheLast() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let first = Task { await store.load() }
        await gate.untilRequests(1)
        let second = Task { await store.load() }
        await gate.untilRequests(2)
        gate.answer(1, with: try roster("claude:first"))
        await first.value
        gate.answer(2, with: try roster("claude:second"))
        await second.value
        #expect(store.roster.map(\.id) == ["claude:second"])
    }

    @Test("a single load shows its reply", .timeLimit(.minutes(1)))
    func singleLoadIsUnchanged() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let only = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(1)
        #expect(store.loading, "a deliberate refresh shows the spinner while it waits")
        gate.answer(1, with: try roster("claude:only"))
        await only.value
        #expect(store.roster.map(\.id) == ["claude:only"])
        #expect(!store.loading && store.error == nil && store.loadedAt != nil)
    }

    @Test("an older load that fails late does not put an error over a newer success",
          .timeLimit(.minutes(1)))
    func olderFailureLandingLateIsDropped() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let older = Task { await store.load() }
        await gate.untilRequests(1)
        let newer = Task { await store.load() }
        await gate.untilRequests(2)
        gate.answer(2, with: try roster("claude:newer"))
        await newer.value
        gate.fail(1, with: Refused())
        await older.value
        #expect(store.error == nil, "the table shows the newer reply, so nothing is wrong")
        #expect(store.roster.map(\.id) == ["claude:newer"])
    }

    @Test("the newest load failing is the error shown, whatever the older one read",
          .timeLimit(.minutes(1)))
    func newestFailureIsShown() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let older = Task { await store.load() }
        await gate.untilRequests(1)
        let newer = Task { await store.load() }
        await gate.untilRequests(2)
        gate.fail(2, with: Refused())
        await newer.value
        #expect(store.error != nil)
        gate.answer(1, with: try roster("claude:older"))
        await older.value
        #expect(store.roster.isEmpty, "a reply older than the failed load is not shown")
        #expect(store.error != nil)
    }

    @Test("an older roster load cannot clear the spinner of a newer refresh", .timeLimit(.minutes(1)))
    func olderRosterCannotClearSpinner() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        let older = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(1)
        let newer = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(2)
        gate.answer(1, with: try roster("claude:older"))
        await older.value
        #expect(store.loading)
        gate.answer(2, with: try roster("claude:newer"))
        await newer.value
        #expect(!store.loading)
    }

    @Test("a background load that replaces a manual refresh releases its spinner", .timeLimit(.minutes(1)))
    func backgroundLoadReleasesReplacedSpinner() async throws {
        let gate = Gate<CoreRoster>()
        let store = makeStore(gate)
        store.roster = try roster("claude:initial").sessions
        let manual = Task { await store.load(userInitiated: true) }
        await gate.untilRequests(1)
        let background = Task { await store.load() }
        await gate.untilRequests(2)
        gate.answer(2, with: try roster("claude:latest"))
        await background.value
        #expect(!store.loading)
        gate.answer(1, with: try roster("claude:older"))
        await manual.value
        #expect(!store.loading)
    }

    // MARK: The transcript

    @Test("refresh preserves the oldest loaded cursor and the exhausted-history state", arguments: [true, false])
    func refreshKeepsEarlierPagination(hasMore: Bool) async throws {
        func numberedPage(_ seq: Int, more: Bool, before: Int?) throws -> CoreTimelinePage {
            var result = try page("event")
            result.events[0].seq = seq
            result.hasMore = more
            result.nextBefore = before
            return result
        }
        let store = OverviewStore(core: CoreModel())
        var replies = [
            try numberedPage(30, more: true, before: 30),
            try numberedPage(20, more: hasMore, before: hasMore ? 20 : nil),
            try numberedPage(40, more: true, before: 40),
        ]
        var cursors: [Int?] = []
        store.fetchTimeline = { _, before, _, _, _ in
            cursors.append(before)
            return replies.removeFirst()
        }
        await store.loadTimeline(for: "claude:session:a")
        await store.loadEarlierTimeline()
        await store.refreshTimeline()
        #expect(store.timeline.map(\.seq) == [20, 40])
        #expect(store.timelinePage?.hasMore == hasMore)
        #expect(store.timelinePage?.nextBefore == (hasMore ? 20 : nil))
        if hasMore { replies.append(try numberedPage(10, more: false, before: nil)) }
        await store.loadEarlierTimeline()
        #expect(cursors.count == (hasMore ? 4 : 3))
        if hasMore { #expect(cursors.last == .some(20)) }

        replies = [try numberedPage(80, more: true, before: 80),
                   try numberedPage(90, more: true, before: 90)]
        await store.loadTimeline(for: "claude:session:b")
        await store.refreshTimeline()
        #expect(store.timelinePage?.nextBefore == 90, "a new selection starts its own pagination")
    }

    @Test("an older transcript read that finishes last does not overwrite the newer one",
          .timeLimit(.minutes(1)))
    func olderTimelineLandingLateIsDropped() async throws {
        let gate = Gate<CoreTimelinePage>()
        let store = OverviewStore(core: CoreModel())
        store.fetchTimeline = { _, _, _, _, _ in try await gate.request() }
        let id = "claude:session:a"
        // Selecting the row again while its first read is out starts a second.
        let older = Task { await store.loadTimeline(for: id) }
        await gate.untilRequests(1)
        let newer = Task { await store.loadTimeline(for: id) }
        await gate.untilRequests(2)

        gate.answer(2, with: try page("newer"))
        await newer.value
        #expect(store.timeline.first?.text == "newer")
        gate.answer(1, with: try page("older"))
        await older.value
        #expect(store.timeline.first?.text == "newer", "the older page landed last and must not win")
        #expect(store.timelinePage?.events.first?.text == "newer")
        #expect(!store.timelineFailed)
    }

    @Test("a transcript read for a row that is no longer selected is still dropped",
          .timeLimit(.minutes(1)))
    func timelineForAnotherSelectionIsDropped() async throws {
        let gate = Gate<CoreTimelinePage>()
        let store = OverviewStore(core: CoreModel())
        store.fetchTimeline = { _, _, _, _, _ in try await gate.request() }
        let first = Task { await store.loadTimeline(for: "claude:session:a") }
        await gate.untilRequests(1)
        let second = Task { await store.loadTimeline(for: "claude:session:b") }
        await gate.untilRequests(2)
        gate.answer(2, with: try page("for b"))
        await second.value
        gate.answer(1, with: try page("for a"))
        await first.value
        #expect(store.timelineSessionID == "claude:session:b")
        #expect(store.timeline.first?.text == "for b")
    }
    @Test("an older transcript read cannot clear a newer selection's spinner", .timeLimit(.minutes(1)))
    func olderTimelineCannotClearSpinner() async throws {
        let gate = Gate<CoreTimelinePage>()
        let store = OverviewStore(core: CoreModel())
        store.fetchTimeline = { _, _, _, _, _ in try await gate.request() }
        let older = Task { await store.loadTimeline(for: "claude:session:a") }
        await gate.untilRequests(1)
        let newer = Task { await store.loadTimeline(for: "claude:session:b") }
        await gate.untilRequests(2)
        gate.answer(1, with: try page("for a"))
        await older.value
        #expect(store.timelineLoading)
        gate.answer(2, with: try page("for b"))
        await newer.value
        #expect(!store.timelineLoading)
        #expect(store.timeline.first?.text == "for b")
    }

    @Test("a failed older-page read cannot put an error over a newer selection", .timeLimit(.minutes(1)))
    func earlierTimelineFailureAfterSelectionIsDropped() async throws {
        let gate = Gate<CoreTimelinePage>()
        let store = OverviewStore(core: CoreModel())
        store.fetchTimeline = { _, _, _, _, _ in try await gate.request() }
        store.timelineSessionID = "claude:session:a"
        store.timelinePage = CoreTimelinePage(hasMore: true, nextBefore: 10)
        let earlier = Task { await store.loadEarlierTimeline() }
        await gate.untilRequests(1)
        let newer = Task { await store.loadTimeline(for: "claude:session:b") }
        await gate.untilRequests(2)
        gate.fail(1, with: Refused())
        await earlier.value
        #expect(store.error == nil)
        #expect(store.timelineLoading)
        gate.answer(2, with: try page("for b"))
        await newer.value
        #expect(!store.timelineLoading)
    }

}
