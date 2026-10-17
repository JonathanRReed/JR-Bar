import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// History as the one home of the past: rows open their timeline in
/// place, the Events tab carries Event Replay's journal, the Why popover
/// keeps a light log, and event rows reveal their session in the Overview.
@MainActor
@Suite struct HistoryMergeTests {
    static let uuid = "8870963f-850a-4bd2-9a4f-0c1a2b3c4d5e"

    @Test("a readable row toggles open and closed; an unreadable one never opens")
    func expansion() {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = HistoryStore(core: core)
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
        let panel = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.test.lightlog"))!,
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

    @Test("a done watch is spent by the run's ending and only by it")
    func doneWatch() {
        let panel = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.test.done"))!,
                               screenBarShown: false)
        let row = SessionRow(session: CoreSession(id: "claude:run", provider: "claude", mode: "working"), pinnedAsk: nil)
        panel.toggleDoneWatch(row)
        #expect(panel.isWatchedForDone(row))
        #expect(!panel.consumeDoneWatch(for: CoreEvent(id: "1", kind: "ask_opened", session: "claude:run")))
        #expect(panel.consumeDoneWatch(for: CoreEvent(id: "2", kind: "completed", session: "claude:run")))
        #expect(!panel.isWatchedForDone(row))
        #expect(!panel.consumeDoneWatch(for: CoreEvent(id: "3", kind: "completed", session: "claude:run")))

        let remote = SessionRow(session: CoreSession(id: "remote:studio:claude:x", provider: "claude", mode: "working"), pinnedAsk: nil)
        panel.toggleDoneWatch(remote)
        #expect(!panel.isWatchedForDone(remote))
    }

    @Test("the bell is offered on a local working run and nowhere else")
    func bellEligibility() {
        func row(_ id: String, _ mode: String) -> SessionRow {
            SessionRow(session: CoreSession(id: id, provider: "claude", mode: mode), pinnedAsk: nil)
        }
        #expect(row("claude:run", "working").canWatchForDone)
        #expect(!row("claude:run", "idle").canWatchForDone)
        #expect(!row("claude:run", "completed").canWatchForDone)
        #expect(!row("claude:run", "failed").canWatchForDone)
        #expect(!row("remote:studio:claude:x", "working").canWatchForDone)
        #expect(DoneBell.actionName(watched: false) == "Notify when done")
        #expect(DoneBell.actionName(watched: true) == "Stop notifying when done")
        #expect(DoneBell.help(watched: true) != DoneBell.help(watched: false))
    }

    @Test("Screen Sharing reaches a peer by a clean host name only")
    func screenSharingHost() {
        #expect(PanelStore.screenSharingHost(peerHost: "studio.tail1234.ts.net", machine: "studio") == "studio.tail1234.ts.net")
        #expect(PanelStore.screenSharingHost(peerHost: nil, machine: "studio-mac") == "studio-mac")
        #expect(PanelStore.screenSharingHost(peerHost: "evil host/../x", machine: "bad name?") == nil)
    }

    @Test("the log's ages are narrow")
    func ages() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(WhyDetailView.age(99_990, now: now) == "now")
        #expect(WhyDetailView.age(99_700, now: now) == "5m")
        #expect(WhyDetailView.age(92_000, now: now) == "2h")
        #expect(WhyDetailView.age(1_000, now: now) == "1d")
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
