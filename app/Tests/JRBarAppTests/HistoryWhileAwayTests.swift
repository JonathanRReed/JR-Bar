import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The History window's honesty about the past: what "while you were away"
/// covers, when a failed timeline read is asked for again, and what a
/// row that cannot open says.
@MainActor
@Suite struct HistoryWhileAwayTests {
    private func row(_ at: Double, _ kind: String, session: String? = nil, unseen: Bool) -> CoreHistoryRow {
        CoreHistoryRow(at: at, kind: kind, provider: "claude", session: session, label: "Run \(Int(at))", unseen: unseen)
    }

    @Test("the away summary holds after a refresh reports the same rows as seen")
    func awayOutlivesTheNextRefresh() {
        let store = HistoryStore(core: CoreModel())
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.adopt(rows: [row(30, "completed", session: "claude:a", unseen: true),
                           row(20, "asked", session: "claude:b", unseen: true),
                           row(10, "completed", session: "claude:c", unseen: false)])
        #expect(store.away?.text == "While you were away: 1 finished, 1 needed you")

        // Opening moved the daemon's mark: the next read has nothing unseen.
        store.adopt(rows: [row(30, "completed", session: "claude:a", unseen: false),
                           row(20, "asked", session: "claude:b", unseen: false),
                           row(10, "completed", session: "claude:c", unseen: false)])
        #expect(store.away?.text == "While you were away: 1 finished, 1 needed you")
        #expect(store.isUnseen(store.rows[0]))
        #expect(!store.isUnseen(store.rows[2]))
    }

    @Test("a row that arrives while the window is open is not away")
    func newRowsAreNotAway() {
        let store = HistoryStore(core: CoreModel())
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.adopt(rows: [row(10, "completed", session: "claude:c", unseen: false)])
        #expect(store.away == nil)
        store.adopt(rows: [row(40, "completed", session: "claude:d", unseen: true),
                           row(10, "completed", session: "claude:c", unseen: false)])
        #expect(store.away == nil, "you are looking at it")
        #expect(!store.isUnseen(store.rows[0]))
    }

    @Test("new rows do not hide the away summary captured when the window opened")
    func arrivingRowsKeepTheAwaySummary() {
        let store = HistoryStore(core: CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-away-test.sock"))
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.adopt(rows: [row(30, "failed", session: "claude:a", unseen: true),
                           row(10, "completed", session: "claude:b", unseen: false)])
        store.adopt(rows: [row(40, "completed", session: "claude:c", unseen: true),
                           row(30, "failed", session: "claude:a", unseen: false),
                           row(10, "completed", session: "claude:b", unseen: false)])
        #expect(store.away?.text == "While you were away: 1 failed")
        #expect(store.away?.rows.map(\.at) == [30])
        #expect(!store.isUnseen(store.rows[0]))
    }

    @Test("showing the window again while it is open keeps the same away summary")
    func showingAgainKeepsTheBaseline() {
        let store = HistoryStore(core: CoreModel())
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.adopt(rows: [row(30, "failed", session: "claude:a", unseen: true)])
        store.windowDidOpen()
        store.adopt(rows: [row(30, "failed", session: "claude:a", unseen: false)])
        #expect(store.away?.text == "While you were away: 1 failed")
    }

    @Test("a failed timeline read is asked for again; so is a run still going")
    func timelineRetry() {
        #expect(HistoryStore.shouldLoadTimeline(cached: false, failed: false, running: false, force: false))
        #expect(!HistoryStore.shouldLoadTimeline(cached: true, failed: false, running: false, force: false), "a finished run's read is kept")
        #expect(HistoryStore.shouldLoadTimeline(cached: true, failed: true, running: false, force: false), "the error is not the answer")
        #expect(HistoryStore.shouldLoadTimeline(cached: true, failed: false, running: true, force: false), "a live transcript moves on")
        #expect(HistoryStore.shouldLoadTimeline(cached: true, failed: false, running: false, force: true))
    }

    @Test("a row that cannot open for want of the monitor says so instead of opening blank")
    func openingNeedsTheMonitor() {
        let store = HistoryStore(core: CoreModel())
        let target = row(10, "completed", session: "claude:session:8870963f-850a-4bd2-9a4f-0c1a2b3c4d5e", unseen: false)
        store.rows = [target]
        store.toggleExpanded(target)
        #expect(store.expandedID == nil)
        #expect(store.notice?.isError == true)
    }

    @Test("two rows that differ only in their detail are two rows")
    func rowIdentity() {
        let a = CoreHistoryRow(at: 5, kind: "quota_crossed", provider: "claude", label: "Claude", detail: "75 %")
        let b = CoreHistoryRow(at: 5, kind: "quota_crossed", provider: "claude", label: "Claude", detail: "90 %")
        #expect(a.id != b.id)
    }

    @Test("a reply refusal reads as its message, not a struct dump")
    func errorWords() {
        let busy = CoreReplyError(code: "busy", message: "The monitor is busy")
        #expect(UsageCenterStore.describe(busy) == "The monitor is busy")
        #expect(!UsageCenterStore.describe(CoreClientError.timeout).contains("CoreClientError"))
    }

    @Test("a palette hit lands on the Activity tab with its row selected, or the row that stands for it")
    func paletteHitFocus() {
        let store = HistoryStore(core: CoreModel())
        let head = row(30, "completed", session: "claude:a", unseen: false)
        let under = row(20, "started", session: "claude:a", unseen: false)
        store.rows = [head, under]
        store.mode = .events
        store.focus(on: under, query: "Run")
        #expect(store.mode == .activity)
        #expect(store.filter.text == "Run")
        #expect(store.selectedID == head.id, "the folded row is shown under its head")
        store.focus(on: head, query: "Run")
        #expect(store.selectedID == head.id)
        store.focus(on: nil, query: "")
        #expect(store.filter.text.isEmpty)
    }
}
