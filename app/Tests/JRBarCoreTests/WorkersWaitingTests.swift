import Foundation
import Testing
@testable import JRBarCore

/// `sessions[].workers_waiting`: how many of a main row's workers wait on a
/// request that stays quiet while sub-agent asks are off. It decodes
/// tolerantly (absent is "not said", never a zero), it is information only,
/// and a worker's ask, which the daemon publishes only while the setting is
/// on, always has a row to land on.
@Suite("Workers waiting on a quiet request")
struct WorkersWaitingTests {
    private static let mainID = "claude:session:main-one"
    private static let workerID = "claude:agent:worker-one"
    private static let otherID = "claude:agent:worker-two"

    private static func decodeRow(_ json: String) throws -> CoreSession {
        try JSONDecoder().decode(CoreSession.self, from: Data(json.utf8))
    }

    private static func workerRow(_ id: String = workerID, parent: String? = mainID, ask: CoreAsk? = nil) -> CoreSession {
        CoreSession(id: id, provider: "claude", kind: "worker", parent: parent, mode: "waiting_for_input",
                    nextActor: "user", ask: ask)
    }

    private static func askFor(_ session: String?) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "Run: make build", answerable: true)
    }

    // MARK: decode

    @Test("a main row's count decodes")
    func decodes() throws {
        let row = try Self.decodeRow(#"{"id":"claude:session:a","kind":"main","workers":3,"workers_waiting":2}"#)
        #expect(row.workers == 3)
        #expect(row.workersWaiting == 2)
    }

    @Test("absent means not said: nil, never zero, and the row still decodes")
    func absentIsNil() throws {
        let row = try Self.decodeRow(#"{"id":"claude:session:a","kind":"main","workers":3}"#)
        #expect(row.workersWaiting == nil)
        #expect(row.workers == 3)
    }

    @Test("a value of the wrong type is not said either, and never loses the row")
    func wrongTypeIsNil() throws {
        let text = try Self.decodeRow(#"{"id":"claude:session:a","kind":"main","workers_waiting":"two"}"#)
        #expect(text.workersWaiting == nil)
        let null = try Self.decodeRow(#"{"id":"claude:session:a","kind":"main","workers_waiting":null}"#)
        #expect(null.workersWaiting == nil)
        #expect(text.id == "claude:session:a")
    }

    @Test("a negative count reads as none")
    func negativeIsZero() throws {
        let row = try Self.decodeRow(#"{"id":"claude:session:a","kind":"main","workers_waiting":-4}"#)
        #expect(row.workersWaiting == 0)
    }

    @Test("a state frame carries it on the main row and an older frame carries nothing")
    func stateFrame() throws {
        func frame(_ extra: String) throws -> CoreState {
            let json = """
            {"t":"state","v":1,"generation":2,"aggregate":{"mode":"working","needs_you":0,"active":1,"ready":0,"failed":0,"total":1},
             "sessions":[{"id":"\(Self.mainID)","provider":"claude","kind":"main","mode":"working","workers":2\(extra)},
                         {"id":"\(Self.workerID)","provider":"claude","kind":"worker","parent":"\(Self.mainID)","mode":"waiting_for_input","next_actor":"user"}],
             "asks":[]}
            """
            guard case .state(let state) = try CoreCodec.decode(frame: Data(json.utf8)) else { throw CoreCodecError.notAnObject }
            return state
        }
        let withCount = try frame(#","workers_waiting":1"#)
        #expect(withCount.session(withID: Self.mainID)?.workersWaiting == 1)
        #expect(withCount.session(withID: Self.workerID)?.workersWaiting == nil)
        let older = try frame("")
        #expect(older.session(withID: Self.mainID)?.workersWaiting == nil)
        #expect(older.session(withID: Self.mainID)?.workers == 2)
    }

    @Test("it survives an encode and decode of the row")
    func roundTrip() throws {
        let row = CoreSession(id: Self.mainID, provider: "claude", mode: "working", workers: 2, workersWaiting: 1)
        let back = try JSONDecoder().decode(CoreSession.self, from: JSONEncoder().encode(row))
        #expect(back.workersWaiting == 1)
        #expect(back == row)
    }

    // MARK: information only

    @Test("a waiting count lights nothing: the row's activity and the header word are what they were")
    func lightsNothing() {
        let quiet = CoreSession(id: Self.mainID, provider: "claude", mode: "working", workers: 2, workersWaiting: 2)
        let plain = CoreSession(id: Self.mainID, provider: "claude", mode: "working", workers: 2)
        #expect(SessionActivity.reduce(quiet) == .working)
        #expect(SessionActivity.reduce(quiet) == SessionActivity.reduce(plain))
        // A quiet worker with no ask is working too, whatever its mode says.
        #expect(SessionActivity.reduce(Self.workerRow()) == .working)
        let aggregate = CoreAggregate(mode: "working", needsYou: 0, active: 1)
        #expect(AgentAggregateState.from(aggregate: aggregate) == .working)
    }

    // MARK: a worker's ask always has a row

    @Test("with sub-agent asks off no worker ask is published and nothing asks")
    func offPublishesNothing() {
        let state = CoreState(sessions: [
            CoreSession(id: Self.mainID, provider: "claude", mode: "working", workers: 1, workersWaiting: 1),
            Self.workerRow(),
        ])
        #expect(state.askingWorkers.isEmpty)
        #expect(state.orphanAsks.isEmpty)
        #expect(state.mainSessions.map(\.id) == [Self.mainID])
    }

    @Test("with them on, a child worker that carries a published ask is a row of its own")
    func onGivesTheWorkerARow() {
        let asked = Self.workerRow(ask: Self.askFor(Self.workerID))
        let state = CoreState(
            aggregate: CoreAggregate(mode: "needs_you", needsYou: 1),
            sessions: [CoreSession(id: Self.mainID, provider: "claude", mode: "working", workers: 2, workersWaiting: 0),
                       asked, Self.workerRow(Self.otherID)],
            asks: [Self.askFor(Self.workerID)])
        #expect(state.askingWorkers.map(\.id) == [Self.workerID])
        #expect(state.orphanAsks.isEmpty)
    }

    @Test("a worker that names no parent is already a main row and is not listed twice")
    func parentlessIsNotRepeated() {
        let loose = Self.workerRow(parent: nil, ask: Self.askFor(Self.workerID))
        let state = CoreState(sessions: [loose], asks: [Self.askFor(Self.workerID)])
        #expect(state.mainSessions.map(\.id) == [Self.workerID])
        #expect(state.askingWorkers.isEmpty)
    }

    @Test("every ask the daemon publishes lands on a row: a main, a child worker, or an orphan")
    func everyAskHasARow() {
        let gone = "claude:session:cleared"
        let state = CoreState(
            aggregate: CoreAggregate(mode: "needs_you", needsYou: 4),
            sessions: [CoreSession(id: Self.mainID, provider: "claude", mode: "waiting", ask: Self.askFor(Self.mainID)),
                       Self.workerRow(ask: Self.askFor(Self.workerID)),
                       Self.workerRow(Self.otherID, parent: nil, ask: Self.askFor(Self.otherID))],
            asks: [Self.askFor(Self.mainID), Self.askFor(Self.workerID), Self.askFor(Self.otherID), Self.askFor(gone)])
        let rowIDs = Set(state.mainSessions.map(\.id) + state.askingWorkers.map(\.id) + state.orphanAsks.compactMap(\.session))
        let asked = Set(state.asks.compactMap(\.session))
        #expect(asked.isSubset(of: rowIDs))
        #expect(state.askingWorkers.map(\.id) == [Self.workerID])
    }

    @Test("an ask with no session at all is an orphan, never an asking worker")
    func sessionlessIsOrphan() {
        let state = CoreState(sessions: [Self.workerRow()], asks: [Self.askFor(nil), Self.askFor("")])
        #expect(state.askingWorkers.isEmpty)
        #expect(state.orphanAsks.count == 2)
    }
}
