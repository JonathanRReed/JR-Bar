import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The Control Center's keys age an ask the way the Screen Bar's left ear
/// does: one ring, one clock, for "how long has it waited".
@Suite("Control Center · ask age")
@MainActor
struct DeckAskAgeTests {
    private static let document = SettingsDocument(.object([
        "escalation_tier": .string("chime"),
        "escalation_final_seconds": .number(400),
        "escalation_ramp_seconds": .number(20),
        "escalation_tier_by_provider": .object(["codex": .string("light")]),
    ]))

    @Test func anAskingKeyWearsTheEarsRing() throws {
        let slot = DeckSlot(index: 2, identity: "id", session: "s1", label: "api", provider: "claude", state: .inputRequired)
        let age = try #require(DeckAskAge.make(slot: slot, asks: [CoreAsk(session: "s1", openedAt: 100)], sessions: [],
                                               document: Self.document))
        #expect(age.openedAt == Date(timeIntervalSince1970: 100))
        #expect(age.fullAfter == 400)
        // The provider's own ceiling reaches the pad too.
        let codex = DeckSlot(index: 3, identity: "id2", session: "s2", provider: "codex", state: .inputRequired)
        #expect(DeckAskAge.make(slot: codex, asks: [CoreAsk(session: "s2", openedAt: 50)], sessions: [],
                                document: Self.document)?.fullAfter == 20)
    }

    @Test func aSessionsOwnAskCountsWhenTheListHasNone() {
        let session = CoreSession(id: "s1", provider: "claude", ask: CoreAsk(session: "s1", openedAt: 200))
        let slot = DeckSlot(index: 0, identity: "id", session: "s1", provider: "claude")
        #expect(DeckAskAge.make(slot: slot, asks: [], sessions: [session], document: Self.document)?.openedAt
                == Date(timeIntervalSince1970: 200))
    }

    @Test func quietKeysAndUndatedAsksHaveNoRing() {
        let slot = DeckSlot(index: 0, identity: "id", session: "s1", provider: "claude")
        #expect(DeckAskAge.make(slot: slot, asks: [], sessions: [], document: Self.document) == nil)
        #expect(DeckAskAge.make(slot: slot, asks: [CoreAsk(session: "s1")], sessions: [], document: Self.document) == nil,
                "an undated ask gets no guessed ring")
        let reserved = DeckSlot(index: 1, identity: "id", session: nil, provider: "claude")
        #expect(DeckAskAge.make(slot: reserved, asks: [CoreAsk(session: "s1", openedAt: 1)], sessions: [], document: Self.document) == nil)
    }
}
