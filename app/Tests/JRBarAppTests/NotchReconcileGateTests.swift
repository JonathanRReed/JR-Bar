import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The toy's reconcile runs only when a doc moved something the notch
/// shows. A working session's clock, tool and message move on nearly
/// every `state` doc, and a reconcile on each one stalled the island's
/// animations; those docs skip it. An ask, the focus, a quiet mode, a
/// session starting or finishing, the usage meters and a setting still
/// reconcile on the doc that carries them.
@Suite("Notch reconcile gate")
@MainActor
struct NotchReconcileGateTests {
    private func makeToy() -> (NotchToy, ToysStore, CoreModel) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store, core)
    }

    /// Two working sessions; `tick` moves only what a working session's
    /// doc moves between two real changes.
    private func doc(tick: Int, asks: [CoreAsk] = [], focus: CoreFocus? = nil,
                     extra: [CoreSession] = [], usedPct: Double = 40) -> CoreState {
        let clock = 1_000 + Double(tick)
        let sessions = [
            CoreSession(id: "claude:1", provider: "claude", label: "fix-tests", mode: "working",
                        since: 900, updatedAt: clock, tool: tick.isMultiple(of: 2) ? "Read" : "Edit",
                        message: "step \(tick)"),
            CoreSession(id: "codex:1", provider: "codex", label: "ship-it", mode: "working",
                        since: 950, updatedAt: clock + 0.5, event: "tool_\(tick)"),
        ] + extra
        let usage = CoreUsage(refreshedAt: clock, providers: [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: usedPct)]),
        ])
        return CoreState(generation: tick, now: clock, sessions: sessions, asks: asks,
                         usage: usage, focus: focus)
    }

    @Test("a doc that only moves the working sessions' clocks skips the reconcile")
    func clockOnlyDocsSkip() {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        core.apply(.state(doc(tick: 0)))
        toy.noteInputsChanged()
        let first = toy.reconcileCount
        #expect(first >= 1, "the first doc always reconciles")
        for tick in 1...30 {
            core.apply(.state(doc(tick: tick)))
            toy.noteInputsChanged()
        }
        #expect(toy.reconcileCount == first, "30 docs of clock churn, no reconcile")
    }

    @Test("an ask opening, and the same ask answered, each reconcile on their doc")
    func askMovesReconcile() {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        core.apply(.state(doc(tick: 0)))
        toy.noteInputsChanged()
        var count = toy.reconcileCount
        let ask = CoreAsk(session: "claude:1", openedAt: 1_010, summary: "Run the migration?",
                          answerable: true, request: "r1")
        core.apply(.state(doc(tick: 1, asks: [ask])))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "a new ask reconciles")
        count = toy.reconcileCount
        core.apply(.state(doc(tick: 2, asks: [ask])))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count, "the same ask on the next doc does not")
        core.apply(.state(doc(tick: 3)))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "the ask answered elsewhere reconciles")
    }

    @Test("a focus change, a quiet mode, a session arriving and a meter moving each reconcile")
    func otherInputsReconcile() throws {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        core.apply(.state(doc(tick: 0)))
        toy.noteInputsChanged()
        var count = toy.reconcileCount
        let quiet = try JSONDecoder().decode(CoreFocus.self,
                                             from: Data(#"{"mode":"dim","source":"focus"}"#.utf8))
        core.apply(.state(doc(tick: 1, focus: quiet)))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "a quiet stretch starting")
        count = toy.reconcileCount
        core.apply(.state(doc(tick: 2)))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "and ending")
        count = toy.reconcileCount
        let arriving = CoreSession(id: "gemini:1", provider: "gemini", label: "long-think", mode: "working")
        core.apply(.state(doc(tick: 3, extra: [arriving])))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "a session starting to work")
        count = toy.reconcileCount
        core.apply(.state(doc(tick: 4, extra: [arriving], usedPct: 55)))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "a usage meter moving")
        count = toy.reconcileCount
        store.state.notch.mediaEnabled.toggle()
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count + 1, "a Notch setting")
    }

    @Test("a skipped doc still says a quiet stretch's summary it could not say before")
    func skippedDocStillReplaysTheHold() {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        core.apply(.state(doc(tick: 0)))
        toy.noteInputsChanged()
        toy.noteMacFocus(name: "Work", on: true)
        toy.offer(AlcoveNotice(id: "c", kind: .completed, title: "Claude · fix-tests", subtitle: "finished",
                               session: "claude:1", key: "completed:c"))
        #expect(toy.capsuleQueue.held.map(\.id) == ["c"])
        // The Focus ends while the island cannot speak; the hold waits.
        toy.islandVisible = false
        toy.noteMacFocus(name: "Work", on: false)
        #expect(toy.capsuleQueue.held.map(\.id) == ["c"])
        toy.islandVisible = true
        // The next doc carries nothing new, and still says it.
        let count = toy.reconcileCount
        core.apply(.state(doc(tick: 1)))
        toy.noteInputsChanged()
        #expect(toy.reconcileCount == count, "the doc itself changed nothing")
        #expect(toy.capsuleQueue.held.isEmpty)
        #expect(toy.capsuleQueue.current?.title == "While you were in Work")
    }

    @Test("the reduced inputs ignore the doc's own stamps and a session's clock")
    func inputsIgnoreChurn() {
        let (toy, store, core) = makeToy()
        defer { withExtendedLifetime(store) {} }
        core.apply(.state(doc(tick: 0)))
        let before = toy.reconcileInputs
        core.apply(.state(doc(tick: 7)))
        #expect(toy.reconcileInputs == before)
        var renamed = doc(tick: 8)
        renamed.sessions[0].label = "fix-more-tests"
        core.apply(.state(renamed))
        #expect(toy.reconcileInputs != before, "a row's label is on the card")
    }
}
