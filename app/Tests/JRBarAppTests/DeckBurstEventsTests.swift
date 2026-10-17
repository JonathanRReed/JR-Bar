import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Two presses can reach the app in one turn of the run loop. The deck
/// lights both keys, not only the last one to land.
@Suite("Deck burst events")
@MainActor
struct DeckBurstEventsTests {
    private func press(_ index: Int, id: String) -> CoreMessage {
        .event(CoreEvent(id: id, kind: "deck_input",
                         input: DeckInput(index: index, kind: "press", at: 100)))
    }

    private func settle(_ store: DeckStore, until done: @MainActor () -> Bool) async {
        var turns = 0
        while !done(), turns < 1_000 {
            await Task.yield()
            turns += 1
        }
    }

    @Test("every input of a burst lights its key")
    func burstLightsEveryKey() async {
        let core = CoreModel()
        let store = DeckStore(core: core)
        core.apply(press(2, id: "e1"))
        core.apply(press(5, id: "e2"))
        core.apply(press(9, id: "e3"))
        await settle(store) { store.isLit(9) }
        #expect(store.isLit(2) && store.isLit(5) && store.isLit(9))
    }

    @Test("a receipt in a burst is not lost behind a later press")
    func receiptInABurst() async {
        let core = CoreModel()
        let store = DeckStore(core: core)
        core.apply(.event(CoreEvent(id: "r1", kind: "deck_receipt", at: 50,
                                    code: "keymap_verified", message: "Verified")))
        core.apply(press(1, id: "e1"))
        await settle(store) { store.isLit(1) }
        #expect(store.eventReceipt?.code == "keymap_verified")
    }

    @Test("the model keeps a bounded run of recent events in order, numbered from 1")
    func recentEvents() {
        let core = CoreModel()
        #expect(core.eventSequence == 0)
        let total = CoreModel.recentEventLimit + 10
        for number in 0..<total {
            core.apply(press(number % 20, id: "x\(number)"))
        }
        #expect(core.eventSequence == total)
        #expect(core.recentEvents.count == CoreModel.recentEventLimit)
        #expect(core.events(after: total - 3).map(\.id) == ["x\(total - 3)", "x\(total - 2)", "x\(total - 1)"])
        #expect(core.events(after: total).isEmpty)
        // A reader that fell further behind than the log keeps gets what
        // is left, oldest first.
        let behind = core.events(after: 0)
        #expect(behind.count == CoreModel.recentEventLimit)
        #expect(behind.last?.id == "x\(total - 1)")
    }

    @Test("a repeat of an event already seen is not logged twice")
    func duplicatesAreNotLogged() {
        let core = CoreModel()
        core.apply(press(1, id: "dup"))
        core.apply(press(1, id: "dup"))
        #expect(core.eventSequence == 1)
    }
}
