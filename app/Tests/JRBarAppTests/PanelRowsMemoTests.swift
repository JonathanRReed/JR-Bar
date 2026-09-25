import Foundation
import Observation
@testable import JRBarCore
import Testing
@testable import JRBarApp

/// The panel builds its rows once per change of what they are made of —
/// the daemon's state, its settings, the sessions' usage, liveness — and
/// every read in between shares that one build. These tests count builds;
/// none of them time anything.
@Suite("Panel rows memo")
@MainActor
struct PanelRowsMemoTests {
    static func session(_ id: String, mode: String = "working", since: Double = 1_790_000_000) -> CoreSession {
        CoreSession(id: id, provider: "claude", label: id, cwd: "/tmp/synthetic/\(id)", mode: mode, since: since)
    }

    static func state(_ generation: Int, _ sessions: [CoreSession]) -> CoreState {
        CoreState(generation: generation, now: 1_790_000_000 + Double(generation), sessions: sessions)
    }

    static func liveStore(_ sessions: [CoreSession]) -> (CoreModel, PanelStore) {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        core.handle(.connected)
        core.apply(.state(state(1, sessions)))
        let store = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.test.\(UUID())")!,
                               screenBarShown: false)
        store.animationsArmed = false
        return (core, store)
    }

    @Test("every read between two frames shares one build")
    func readsShareOneBuild() {
        let (core, store) = Self.liveStore([Self.session("a"), Self.session("b", mode: "waiting")])
        let before = store.rowsComputations
        _ = store.rows
        _ = store.visibleRows
        _ = store.visibleAskRows
        _ = store.visiblePlainRows
        _ = store.askRows
        _ = store.screenBarFocus
        _ = store.screenBarWings
        _ = store.completedCount
        #expect(store.rowsComputations == before + 1)
        core.apply(.state(Self.state(2, [Self.session("a"), Self.session("c")])))
        #expect(store.rows.map(\.id).sorted() == ["a", "c"])
        _ = store.visibleRowIDs
        #expect(store.rowsComputations == before + 2, "a new frame builds once more")
    }

    @Test("a provider colour set in Settings reaches the row")
    func settingsColourRebuilds() {
        let (core, store) = Self.liveStore([Self.session("a")])
        let before = store.rows.first?.style.accentHex
        core.apply(.settings(CoreSettings(generation: 2, document: .object([
            "colors": .object(["agent_colors": .object(["claude": .string("#112233")])]),
        ]))))
        #expect(store.rows.first?.style.accentHex == "#112233")
        #expect(before != "#112233")
    }

    @Test("a session's usage reaching the store reaches its row")
    func usageRebuilds() {
        let (_, store) = Self.liveStore([Self.session("a")])
        #expect(store.rows.first?.usage == nil)
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "a": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 1.5),
        ]), asked: ["a"])
        #expect(store.rows.first?.usage?.model == "claude-opus-4-5")
    }

    @Test("a disconnect empties the rows")
    func disconnectEmpties() {
        let (core, store) = Self.liveStore([Self.session("a")])
        #expect(store.rows.count == 1)
        core.handle(.disconnected(reason: "gone"))
        #expect(store.rows.isEmpty)
    }

    @Test("the find query cuts the shared rows without building them again")
    func findCutsTheMemo() {
        let (_, store) = Self.liveStore([Self.session("alpha"), Self.session("bravo", mode: "waiting")])
        _ = store.rows
        let before = store.rowsComputations
        store.find("alp")
        #expect(store.visibleRowIDs == ["alpha"])
        #expect(store.visiblePlainRows.map(\.id) == ["alpha"])
        store.clearFind()
        #expect(store.visibleRows.count == 2)
        #expect(store.rowsComputations == before, "the query never rebuilds the rows")
    }

    @Test("a view reading the rows is woken by a new frame")
    func rowsStayObserved() {
        let (core, store) = Self.liveStore([Self.session("a")])
        final class Tripped: @unchecked Sendable { var fired = false }
        let tripped = Tripped()
        withObservationTracking { _ = store.visibleRows } onChange: { tripped.fired = true }
        core.apply(.state(Self.state(3, [Self.session("a"), Self.session("b")])))
        #expect(tripped.fired, "the memo must still subscribe its reader to the state")
    }
}
