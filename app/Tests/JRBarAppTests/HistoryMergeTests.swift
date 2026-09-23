import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// History as the one home of the past: rows open their timeline in
/// place, the Events tab carries Event Replay's journal, the Why popover
/// keeps a light log, and event rows reveal their session in the Overview.
@MainActor
@Suite struct HistoryMergeTests {
    static let uuid = "8870963f-850a-4bd2-9a4f-0c1a2b3c4d5e"

    @Test("a readable row toggles open and closed; an unreadable one never opens")
    func expansion() {
        let store = HistoryStore(core: CoreModel())
        let row = CoreHistoryRow(at: 10, kind: "completed", provider: "claude", session: "claude:session:\(Self.uuid)")
        let quota = CoreHistoryRow(at: 11, kind: "quota_crossed", provider: "claude")
        store.rows = [row, quota]

        store.toggleExpanded(quota)
        #expect(store.expandedID == nil)

        store.toggleExpanded(row)
        #expect(store.expandedID == row.id)
        #expect(store.selectedID == row.id)
        store.toggleExpanded(row)
        #expect(store.expandedID == nil)

        store.selectedID = row.id
        store.expandSelected(true)
        #expect(store.expandedID == row.id)
        store.expandSelected(false)
        #expect(store.expandedID == nil)
    }

    @Test("the Events tab filters the journal the Replay store read")
    func events() {
        let store = HistoryStore(core: CoreModel())
        store.replay.events = [
            CoreEvent(id: "1", kind: "ask_opened", session: "codex:a", at: 1, provider: "codex"),
            CoreEvent(id: "2", kind: "failed", session: "claude:b", at: 2, provider: "claude"),
            CoreEvent(id: "3", kind: CoreEvent.usageHistoryReadyKind, at: 3),
        ]
        #expect(store.events.map(\.id) == ["2", "1"])
        #expect(store.eventCategories == [.asks, .failures])
        store.toggleEventCategory(.failures)
        #expect(store.events.map(\.id) == ["2"])
        #expect(store.eventCount(.asks) == 1)

        var revealed: String?
        #expect(!store.canReveal(store.events[0]))
        store.onRevealSession = { revealed = $0 }
        #expect(store.canReveal(store.events[0]))
        store.reveal(store.events[0])
        #expect(revealed == "claude:b")
    }

    @Test("the panel's light log keeps the events that moved a light, newest first")
    func lightLog() {
        let panel = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.test.lightlog.\(UUID().uuidString)")!,
                               screenBarShown: false)
        panel.noteEvent(CoreEvent(id: "a", kind: "device_connected", at: 1))
        panel.noteEvent(CoreEvent(id: "b", kind: "completed", label: "JR-Bar", at: 2, provider: "claude"))
        panel.noteEvent(CoreEvent(id: "b", kind: "completed", label: "JR-Bar", at: 2, provider: "claude"))
        panel.noteEvent(CoreEvent(id: "c", kind: "ask_opened", label: "core", at: 3, provider: "codex"))
        #expect(panel.recentEvents.map(\.id) == ["a", "b", "c"])
        #expect(panel.lightLog.map(\.text) == ["Codex asked · core", "Claude finished · JR-Bar"])
        for index in 0..<60 { panel.noteEvent(CoreEvent(id: "x\(index)", kind: "completed", at: Double(10 + index))) }
        #expect(panel.recentEvents.count == PanelStore.recentEventLimit)
    }

    @Test("the log's ages are narrow")
    func ages() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(WhyDetailView.age(99_990, now: now) == "now")
        #expect(WhyDetailView.age(99_700, now: now) == "5m")
        #expect(WhyDetailView.age(92_000, now: now) == "2h")
        #expect(WhyDetailView.age(1_000, now: now) == "1d")
    }

    @Test("a gone transcript falls back to the archive's copy, asked for by the session's uuid")
    func archiveFallback() async {
        let store = OverviewStore(core: CoreModel())
        let id = "claude:session:\(Self.uuid)"
        store.roster = [CoreRosterEntry(session: CoreSession(id: id, provider: "claude", mode: "completed", lifecycle: "completed"))]
        store.filter = OverviewFilter(preset: .all)
        store.timelineSessionID = id
        let record = ArchiveRecord(id: "rec", name: "\(Self.uuid).jsonl", sourcePath: "/x", byteCount: 1,
                                   importedAt: Date(), sourceModifiedAt: nil, provider: "claude", sessionID: Self.uuid)
        let rebuilt = SessionReconstructor.reconstruction(from: [CoreTimelineItem(seq: 0, kind: "message", role: "user", text: "hi")],
                                                          running: false)
        var asked: String?
        store.archiveTimeline = { sessionID in
            asked = sessionID
            return (rebuilt, record)
        }
        await store.loadArchivedTimeline(for: id)
        #expect(asked == Self.uuid)
        #expect(store.archivedTimeline?.id == id)
        #expect(store.archivedTimeline?.record.id == "rec")
    }

    @Test("the archive's timeline comes from its newest transcript, never a proxy log")
    func newestTranscript() {
        let old = ArchiveRecord(id: "old", name: "a", sourcePath: "/a", byteCount: 1, importedAt: Date(timeIntervalSince1970: 1),
                                sourceModifiedAt: nil, provider: "claude", sessionID: "s")
        let new = ArchiveRecord(id: "new", name: "b", sourcePath: "/b", byteCount: 1, importedAt: Date(timeIntervalSince1970: 2),
                                sourceModifiedAt: nil, provider: "codex", sessionID: "s")
        let proxy = ArchiveRecord(id: "proxy", name: "c", sourcePath: "/c", byteCount: 1, importedAt: Date(timeIntervalSince1970: 3),
                                  sourceModifiedAt: nil, provider: "cliproxy", sessionID: "s")
        #expect(DataHoarderModel.newestTranscript(in: [old, proxy, new])?.id == "new")
        #expect(DataHoarderModel.newestTranscript(in: [proxy]) == nil)
    }

    @Test("revealing a session shows every row and selects it, now or once it loads")
    func reveal() {
        let store = OverviewStore(core: CoreModel())
        store.filter = OverviewFilter(preset: .failed)
        store.search = "zzz"
        store.roster = [CoreRosterEntry(session: CoreSession(id: "hist-a", provider: "claude", mode: "working"))]
        store.reveal("hist-a")
        #expect(store.filter == OverviewFilter(preset: .all))
        #expect(store.search.isEmpty)
        #expect(store.selectedID == "hist-a")

        store.reveal("hist-later")
        #expect(store.selectedID == "hist-a")
    }
}
