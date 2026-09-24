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

    @Test("a held ask's ring empties over its hold and goes when the hold lapses")
    func holdRing() {
        let start = Date(timeIntervalSince1970: 1_000)
        let held = CoreAsk(session: "claude:session:r", kind: "permission", openedAt: 1_000,
                           decision: CoreAskDecision(holdUntil: 1_045))
        #expect(RailHoldRing.fraction(of: held, at: start) == 1)
        #expect(RailHoldRing.fraction(of: held, at: start.addingTimeInterval(22.5)) == 0.5)
        #expect(RailHoldRing.secondsLeft(of: held, at: start.addingTimeInterval(22.5)) == 23)
        #expect(RailHoldRing.fraction(of: held, at: start.addingTimeInterval(45)) == nil, "lapsed: no ring")

        // No start on record: the usual 45 s is the measure.
        let unopened = CoreAsk(session: "claude:session:r", decision: CoreAskDecision(holdUntil: 1_030))
        #expect(RailHoldRing.fraction(of: unopened, at: start) == 30.0 / 45.0)

        let open = CoreAsk(session: "claude:session:r", decision: CoreAskDecision())
        #expect(RailHoldRing.fraction(of: open, at: start) == nil, "a hold with no deadline draws no ring")
        let decided = CoreAsk(session: "claude:session:r", decision: CoreAskDecision(holdUntil: 1_045, decided: true))
        #expect(RailHoldRing.fraction(of: decided, at: start) == nil)
        #expect(RailHoldRing.fraction(of: CoreAsk(session: "claude:session:r"), at: start) == nil)
    }

    @Test("under Reduce Motion the ring steps, and it never reads empty while time is left")
    func holdRingSteps() {
        #expect(RailHoldRing.stepped(1) == 1)
        #expect(RailHoldRing.stepped(0.5) == 5.0 / 9.0)
        #expect(RailHoldRing.stepped(0.01) == 1.0 / 9.0)
        #expect(RailHoldRing.stepped(0) == 0)
    }

    @Test("the ring redraws until the deadline and then stops")
    func holdRingTicks() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ticks = RailHoldRing.ticks(from: now, until: now.addingTimeInterval(3.5), every: 1)
        #expect(ticks.map(\.timeIntervalSince1970) == [1_000, 1_001, 1_002, 1_003, 1_003.5])
        #expect(RailHoldRing.ticks(from: now, until: now, every: 1) == [now])
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
