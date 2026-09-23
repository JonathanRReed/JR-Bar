import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The rail's hover pill says what an asking key's session wants.
@Suite("Rail ask pill")
@MainActor
struct DeckRailAskTests {
    @Test("an asking key names the ask; other keys say nothing more")
    func detail() {
        let core = CoreModel()
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:session:r", provider: "claude", mode: "waiting", lifecycle: "active")],
            asks: [CoreAsk(session: "claude:session:r", kind: "permission", summary: "Run   swift test\nin app/?")])))
        let store = DeckStore(core: core)
        let asking = DeckSlot(index: 0, session: "claude:session:r", state: .inputRequired)
        #expect(store.askDetail(for: asking) == "Run swift test in app/?")
        #expect(store.askDetail(for: DeckSlot(index: 1, session: "claude:session:r", state: .active)) == nil)
        #expect(store.askDetail(for: DeckSlot(index: 2, session: "claude:session:gone", state: .inputRequired)) == nil)
    }

    @Test("a long ask is cut to one bounded line")
    func bounded() {
        let long = String(repeating: "word ", count: 40)
        let line = DeckStore.askLine(long)
        #expect(line?.count == 90)
        #expect(line?.hasSuffix("…") == true)
        #expect(DeckStore.askLine("   ") == nil)
    }
}
