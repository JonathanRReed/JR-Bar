import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The pal card: every line is the care log's, in words — when you met,
/// what it's had, whose crumbs it likes best, the longest ask it sat
/// through. Nothing is hashed or invented.
@Suite("Buddy pal card")
@MainActor
struct BuddyPalCardTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a buddy nobody has met says so and claims nothing")
    func unmet() {
        let card = BuddyPalCard.make(care: BuddyCare(), now: t0)
        #expect(card.feeling == "Not met yet")
        #expect(card.since == nil)
        #expect(card.favourite == nil)
        #expect(card.longestAsk == nil)
        #expect(card.tally == "0 pets · 0 treats · 0 crumbs")
    }

    @Test("the first pet is the day you met; crumbs remember their agent")
    func meetingAndFavourite() {
        var care = BuddyCare()
        care.pet(at: t0)
        care.pet(at: t0.addingTimeInterval(60))
        #expect(care.firstMetAt == t0.timeIntervalSince1970, "later pets don't move the day")
        care.eat(at: t0, count: 1, provider: "Claude")
        care.eat(at: t0, count: 2, provider: "codex")
        care.eat(at: t0, count: 1, provider: nil)
        #expect(care.crumbsByProvider == ["claude": 1, "codex": 2])
        #expect(care.favouriteProvider?.id == "codex")
        let card = BuddyPalCard.make(care: care, now: t0) { $0.capitalized }
        #expect(card.since?.hasPrefix("Together since") == true)
        #expect(card.favourite == "Favourite agent: Codex — 2 crumbs")
        #expect(card.tally == "2 pets · 0 treats · 4 crumbs")
    }

    @Test("a tie on crumbs picks the same favourite every time")
    func favouriteTieIsStable() {
        var care = BuddyCare()
        care.eat(at: t0, provider: "zeta")
        care.eat(at: t0, provider: "alpha")
        #expect(care.favouriteProvider?.id == "alpha")
    }

    @Test("only the longest ask is kept, and it reads in minutes")
    func longestAsk() {
        var care = BuddyCare()
        care.noteAsk(lasted: 300)
        care.noteAsk(lasted: 120)
        care.noteAsk(lasted: .nan)
        #expect(care.longestAskSeconds == 300)
        #expect(BuddyPalCard.make(care: care, now: t0).longestAsk == "Longest ask sat through: 5 min")
        #expect(BuddyPalCard.duration(42) == "42 s")
        #expect(BuddyPalCard.duration(7_500) == "2 h 5 min")
        #expect(BuddyPalCard.duration(7_200) == "2 h")
    }

    @Test("a log from before the fields is seeded with its earliest stamp, as a floor")
    func migration() throws {
        let json = #"{"lastInteractionAt": 1700000500, "lastCrumbAt": 1700000100, "petCount": 3}"#
        let care = try JSONDecoder().decode(BuddyCare.self, from: Data(json.utf8))
        #expect(care.firstMetAt == 1_700_000_100)
        #expect(care.firstMetIsFloor)
        #expect(BuddyPalCard.make(care: care, now: t0).since?.hasPrefix("Together at least since") == true)
        let fresh = try JSONDecoder().decode(BuddyCare.self, from: Data("{}".utf8))
        #expect(fresh.firstMetAt == 0)
        #expect(fresh == BuddyCare())
        var round = BuddyCare()
        round.pet(at: t0)
        round.eat(at: t0, provider: "codex")
        round.noteAsk(lasted: 90)
        #expect(try JSONDecoder().decode(BuddyCare.self, from: JSONEncoder().encode(round)) == round)
        let junk = try JSONDecoder().decode(BuddyCare.self, from: Data(
            #"{"crumbsByProvider": {"codex": -2, "claude": 3}, "longestAskSeconds": -5}"#.utf8))
        #expect(junk.crumbsByProvider == ["claude": 3])
        #expect(junk.longestAskSeconds == 0)
    }

    @Test("the buddy logs how long each ask stayed open")
    func asksAreTimed() {
        let core = CoreModel()
        var state = ToysState()
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let buddy = store.notchBuddy
        let asking = CoreSession(id: "a", provider: "codex", mode: "waiting_for_user",
                                 lifecycle: "active", nextActor: "user",
                                 ask: CoreAsk(session: "a", kind: "question",
                                              openedAt: t0.timeIntervalSince1970))
        buddy.noteAsks([asking], at: t0.addingTimeInterval(10))
        #expect(store.state.notchBuddy.care.longestAskSeconds == 0, "still open")
        buddy.noteAsks([], at: t0.addingTimeInterval(95))
        #expect(store.state.notchBuddy.care.longestAskSeconds == 95)
    }

    @Test("a completion's crumb is credited to its session's agent")
    func crumbCarriesProvider() {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "s", provider: "gemini")])))
        var state = ToysState()
        state.notchBuddy.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        store.notchBuddy.noteEvent(CoreEvent(id: "c", kind: "completed", session: "s"), at: t0)
        #expect(store.state.notchBuddy.care.crumbsByProvider == ["gemini": 1])
    }
}
