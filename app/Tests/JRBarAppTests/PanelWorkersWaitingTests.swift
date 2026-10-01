import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The panel's two halves of the sub-agent ask story, each told in the
/// words and rows a person sees, with nothing timed and no daemon.
///
/// Off, the default: a worker's request is quiet. The parent row says so in
/// plain words ("1 worker waiting"); no ask row, no needs-you count and no
/// header word follow. On: the same request is an ordinary ask. It is
/// counted in the header and it has a row, so an alert is never raised for
/// something the panel cannot show, and Approve and Deny reach it through
/// the one ask desk.
@Suite("Panel workers waiting")
@MainActor
struct PanelWorkersWaitingTests {
    static let mainID = "claude:session:main-one"
    static let workerID = "claude:agent:worker-one"
    static let otherID = "claude:agent:worker-two"
    static let now = 1_790_000_000.0

    static func mainRow(workers: Int = 2, waiting: Int? = nil, ask: CoreAsk? = nil) -> CoreSession {
        CoreSession(id: mainID, provider: "claude", label: "jr-bar", cwd: "/tmp/synthetic/jr-bar",
                    mode: ask == nil ? "working" : "waiting_for_input", since: now, ask: ask,
                    workers: workers, workersWaiting: waiting)
    }

    static func workerRow(_ id: String = workerID, ask: CoreAsk? = nil) -> CoreSession {
        CoreSession(id: id, provider: "claude", kind: "worker", parent: mainID, label: "jr-bar worker \(id.suffix(3))",
                    mode: "waiting_for_input", nextActor: "user", since: now - 30, ask: ask)
    }

    static func askFor(_ session: String) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", openedAt: now - 20, summary: "Run: make build", answerable: true)
    }

    static func makeStore(_ state: CoreState) -> PanelStore {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(state))
        let store = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.test.\(UUID())")!,
                               screenBarShown: false)
        store.animationsArmed = false
        return store
    }

    /// The daemon's off-state frame: a working main that counts one quiet
    /// worker, the worker's own row with no ask, and no asks at all.
    static var offState: CoreState {
        CoreState(generation: 1, now: now,
                  aggregate: CoreAggregate(mode: "working", needsYou: 0, active: 1),
                  sessions: [mainRow(waiting: 1), workerRow(), workerRow(otherID)])
    }

    /// The same request with sub-agent asks on: published as an ask on the
    /// worker's own row and counted in the header.
    static var onState: CoreState {
        let asked = workerRow(ask: askFor(workerID))
        return CoreState(generation: 1, now: now,
                         aggregate: CoreAggregate(mode: "needs_you", needsYou: 1, active: 1),
                         sessions: [mainRow(waiting: 0), asked, workerRow(otherID)],
                         asks: [askFor(workerID)])
    }

    // MARK: the words

    @Test("the count is said in plain words, singular and plural, and not at all when none")
    func wording() {
        func text(_ waiting: Int?) -> String? {
            SessionRow(session: Self.mainRow(waiting: waiting), pinnedAsk: nil).workersWaitingText
        }
        #expect(text(nil) == nil)
        #expect(text(0) == nil)
        #expect(text(1) == "1 worker waiting")
        #expect(text(3) == "3 workers waiting")
    }

    @Test("a worker's own row and an orphan ask say nothing about waiting workers")
    func onlyAParentSpeaks() {
        let worker = SessionRow(session: Self.workerRow(), pinnedAsk: nil)
        #expect(worker.workersWaitingText == nil)
        #expect(SessionRow(orphanAsk: Self.askFor("claude:session:gone")).workersWaitingText == nil)
    }

    @Test("the tooltip and the spoken label carry it, and the tooltip names the setting")
    func tooltip() throws {
        let row = SessionRow(session: Self.mainRow(waiting: 2), pinnedAsk: nil)
        let help = try #require(row.help(now: Date(timeIntervalSince1970: Self.now)))
        #expect(help.contains("2 workers waiting"))
        #expect(help.contains("Sub-agent asks"))
        let none = SessionRow(session: Self.mainRow(waiting: 0), pinnedAsk: nil)
        #expect(none.help(now: Date(timeIntervalSince1970: Self.now))?.contains("waiting") != true)
    }

    // MARK: the setting off

    @Test("off: the parent row says one worker is waiting, and that is all it does")
    func offIsOnlyWords() throws {
        let store = Self.makeStore(Self.offState)
        let parent = try #require(store.rows.first { $0.id == Self.mainID })
        #expect(parent.workersWaitingText == "1 worker waiting")
        #expect(parent.workersText == "2 workers", "the workers chip keeps counting every live worker")
        // Nothing asks, nothing counts, nothing escalates.
        #expect(store.rows.map(\.id) == [Self.mainID], "workers are not rows")
        #expect(store.askRows.isEmpty)
        #expect(parent.ask == nil)
        #expect(parent.activity == .working)
        #expect(store.aggregate == .working)
        #expect(store.headerWord == "Working")
        #expect(store.screenBarFocus.word == "Working")
        #expect(store.screenBarFocus.clickSession == Self.mainID)
    }

    @Test("off: a daemon that does not say reads as before, with no words")
    func offOlderDaemon() throws {
        let state = CoreState(generation: 1, now: Self.now,
                              aggregate: CoreAggregate(mode: "working", active: 1),
                              sessions: [Self.mainRow(waiting: nil), Self.workerRow()])
        let store = Self.makeStore(state)
        let parent = try #require(store.rows.first)
        #expect(parent.workersWaitingText == nil)
        #expect(store.askRows.isEmpty)
    }

    // MARK: the setting on

    @Test("on: the worker's ask has a row of its own, the same ask the desk answers")
    func onGivesTheAskARow() throws {
        let store = Self.makeStore(Self.onState)
        let row = try #require(store.rows.first { $0.id == Self.workerID })
        #expect(row.ask?.session == Self.workerID)
        #expect(row.activity == .waiting)
        #expect(row.label.contains("worker"), "the label names it as a worker of the parent's run")
        // The parent keeps its own row and says nothing quiet is waiting.
        let parent = try #require(store.rows.first { $0.id == Self.mainID })
        #expect(parent.workersWaitingText == nil)
        // The other worker has no ask, so it is no row.
        #expect(store.rows.contains { $0.id == Self.otherID } == false)
        #expect(Set(store.rows.map(\.id)) == [Self.mainID, Self.workerID])
    }

    @Test("on: the header counts the ask and the ask rows list it first")
    func onCountsAndLists() {
        let store = Self.makeStore(Self.onState)
        #expect(store.aggregate == .needsInput)
        #expect(store.headerWord == "Needs you")
        #expect(store.askRows.map(\.id) == [Self.workerID])
        #expect(store.rows.first?.id == Self.workerID, "an ask leads the list")
        #expect(store.screenBarFocus.word == "Needs you")
        #expect(store.screenBarFocus.clickSession == Self.workerID)
    }

    @Test("on: Approve and Deny reach the worker's ask through the ordinary desk and chords")
    func onIsAnswerable() throws {
        let store = Self.makeStore(Self.onState)
        let row = try #require(store.askRows.first)
        let ask = try #require(row.ask)
        #expect(ask.canAnswer)
        #expect(store.askDesk.refusal(ask, .approve) == nil)
        #expect(store.askDesk.refusal(ask, .deny) == nil)
        #expect(PanelStore.chordTarget(.approve, typingInField: false, selectedID: nil, askRows: store.askRows)
                == .ask(id: Self.workerID))
        #expect(PanelStore.chordTarget(.deny, typingInField: false, selectedID: nil, askRows: store.askRows)
                == .ask(id: Self.workerID))
    }

    @Test("on: every ask in the state lands on a row, so no alert fires for something unshown")
    func onNoAskWithoutARow() {
        let gone = "claude:session:cleared"
        var state = Self.onState
        state.asks.append(Self.askFor(Self.mainID))
        state.asks.append(Self.askFor(gone))
        state.sessions[0] = Self.mainRow(waiting: 0, ask: Self.askFor(Self.mainID))
        let store = Self.makeStore(state)
        let rowIDs = Set(store.rows.map(\.id))
        for ask in state.asks {
            #expect(rowIDs.contains(ask.session ?? ""), "no row for \(ask.session ?? "-")")
        }
        #expect(store.askRows.count == 3)
    }
}
