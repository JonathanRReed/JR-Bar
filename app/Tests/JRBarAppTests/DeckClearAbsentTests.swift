import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Clear Absent shows the cleared board while the daemon decides. A
/// refusal takes the guess back.
@Suite("Deck clear absent")
@MainActor
struct DeckClearAbsentTests {
    @Test("a Clear Absent the daemon cannot take leaves the board as it was")
    func failedClearRestoresTheBoard() async {
        let core = CoreModel()
        let observed = DeckSlot(index: 0, identity: "claude:s1", session: "claude:session:s1")
        let absent = DeckSlot(index: 1, identity: "codex:gone")
        let deck = DeckState(slots: [observed, absent])
        core.apply(.state(CoreState(generation: 3, deck: deck)))
        let store = DeckStore(core: core)
        #expect(store.deck?.absentSlots.count == 1)

        store.sheet = .clearAbsent
        store.confirmSheet()
        // No monitor is connected, so the command fails at once.
        var turns = 0
        while store.sheetBusy, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        #expect(!store.sheetBusy)
        #expect(store.lastError != nil)
        #expect(store.deck == core.deck, "the cleared board was only a guess")
        #expect(store.deck?.absentSlots.count == 1)
    }
}
