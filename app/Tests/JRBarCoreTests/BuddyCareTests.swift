import Foundation
import Testing
@testable import JRBarCore

/// `BuddyCare` is the buddy's Tamagotchi-lite memory (docs/TOYS.md): a
/// persisted log of pets, treats and eaten crumbs whose only read is
/// `mood(at:)`. The tests pin the decay — never-touched stays content,
/// a day without a pat turns to missing, a treat is `fed` for a window
/// and counts as a pet — and that the whole log rides the same tolerant
/// decode as the rest of `app-state.json`.
@Suite("Buddy care")
struct BuddyCareTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("a fresh log is content and stays content forever untouched")
    func neverTouchedIsContent() {
        let care = BuddyCare()
        #expect(care.mood(at: t0) == .content)
        #expect(care.mood(at: t0.addingTimeInterval(365 * 24 * 3600)) == .content,
                "it cannot miss what it never had")
    }

    @Test("a pet is content now, missing after a day of quiet")
    func attentionDecays() {
        var care = BuddyCare()
        care.pet(at: t0)
        #expect(care.petCount == 1)
        #expect(care.mood(at: t0) == .content)
        #expect(care.mood(at: t0.addingTimeInterval(BuddyCare.lonelyAfter - 1)) == .content)
        #expect(care.mood(at: t0.addingTimeInterval(BuddyCare.lonelyAfter + 1)) == .missing)
    }

    @Test("a pet while missed brings it back")
    func petResetsMissing() {
        var care = BuddyCare()
        care.pet(at: t0)
        let later = t0.addingTimeInterval(BuddyCare.lonelyAfter + 60)
        #expect(care.mood(at: later) == .missing)
        care.pet(at: later)
        #expect(care.mood(at: later) == .content)
        #expect(care.petCount == 2)
    }

    @Test("a treat is fed for the window, and counts as a pet")
    func treatIsFed() {
        var care = BuddyCare()
        care.feed(at: t0)
        #expect(care.treatsGiven == 1)
        #expect(care.petCount == 1, "a treat is also a pat")
        #expect(care.mood(at: t0) == .fed)
        #expect(care.mood(at: t0.addingTimeInterval(BuddyCare.fedWindow - 1)) == .fed)
        #expect(care.mood(at: t0.addingTimeInterval(BuddyCare.fedWindow + 1)) == .content,
                "fed wears off; only the long quiet misses you")
    }

    @Test("fed wins over missing — the treat is also attention")
    func fedOutranksMissing() {
        var care = BuddyCare(lastInteractionAt: t0.timeIntervalSince1970 - BuddyCare.lonelyAfter - 60)
        #expect(care.mood(at: t0) == .missing)
        care.feed(at: t0)
        #expect(care.mood(at: t0) == .fed)
    }

    @Test("crumbs are ambient: eating does not count as attention")
    func eatingIsNotAttention() {
        var care = BuddyCare(lastInteractionAt: t0.timeIntervalSince1970 - BuddyCare.lonelyAfter - 60)
        care.eat(at: t0, count: 3)
        #expect(care.crumbsEaten == 3)
        #expect(care.lastCrumbAt == t0.timeIntervalSince1970)
        #expect(care.mood(at: t0) == .missing, "watching it eat is not saying hi")
    }

    @Test("an empty document is a fresh log; mistyped fields fall back")
    func tolerantDecode() throws {
        #expect(try decode(BuddyCare.self, "{}") == BuddyCare())
        #expect(try decode(BuddyCare.self, #"{"petCount": "many", "future": true}"#) == BuddyCare())
        let full = try decode(BuddyCare.self, #"{"lastInteractionAt": 5, "lastTreatAt": 9, "lastCrumbAt": 7, "petCount": 4, "treatsGiven": 2, "crumbsEaten": 11}"#)
        #expect(full == BuddyCare(lastInteractionAt: 5, lastTreatAt: 9, lastCrumbAt: 7,
                                petCount: 4, treatsGiven: 2, crumbsEaten: 11))
    }

    @Test("the log round-trips through NotchBuddySettings")
    func roundTrip() throws {
        var settings = NotchBuddySettings(enabled: true)
        settings.care = BuddyCare(lastInteractionAt: 5, lastTreatAt: 9, petCount: 4,
                                treatsGiven: 2, crumbsEaten: 11)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NotchBuddySettings.self, from: data) == settings)
    }

    @Test("a settings blob without care decodes to a fresh log")
    func missingCareIsFresh() throws {
        let settings = try decode(NotchBuddySettings.self, #"{"enabled": true, "character": "crab"}"#)
        #expect(settings.care == BuddyCare())
        #expect(settings.resolvedCharacter == .crab)
        #expect(settings.resolvedName == "Pinch")
    }
}
