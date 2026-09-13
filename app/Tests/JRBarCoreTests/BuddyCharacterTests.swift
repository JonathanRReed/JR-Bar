import Foundation
import Testing
@testable import JRBarCore

/// `BuddyCharacter` is the Notch Buddy roster (docs/TOYS.md). Its raw
/// values are written into `app-state.json`, so they must decode
/// cleanly, stay stable, and fail soft — an unknown stored name reads
/// as Dot through `NotchBuddySettings.resolvedCharacter` while the
/// string itself survives in the file for a newer build to honour.
@Suite("Buddy character")
struct BuddyCharacterTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("every case decodes from its raw value")
    func everyCaseDecodes() throws {
        for character in BuddyCharacter.allCases {
            let decoded = try decode(BuddyCharacter.self, "\"\(character.rawValue)\"")
            #expect(decoded == character)
        }
    }

    @Test("the roster's raw values are stable")
    func rosterIsStable() {
        #expect(Set(BuddyCharacter.allCases.map(\.rawValue))
                == ["dot", "cat", "ghost", "robot", "owl", "slime",
                    "axolotl", "crab", "mushroom", "ufo"])
    }

    @Test("an unknown stored name resolves to Dot but keeps the string")
    func unknownResolvesToDot() throws {
        let settings = try decode(NotchBuddySettings.self, #"{"enabled": true, "character": "dragon"}"#)
        #expect(settings.resolvedCharacter == .dot)
        #expect(settings.character == "dragon", "the raw string stays for a newer build")
        #expect(NotchBuddySettings(character: "owl").resolvedCharacter == .owl)
        #expect(NotchBuddySettings(character: "slime").resolvedCharacter == .slime)
        #expect(NotchBuddySettings().resolvedCharacter == .dot)
    }

    @Test("display names are unique and non-empty, blurbs non-empty")
    func namesAndBlurbs() {
        let names = BuddyCharacter.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(BuddyCharacter.allCases.allSatisfy { !$0.blurb.isEmpty })
    }

    @Test("every character answers to a default name, all distinct")
    func defaultNames() {
        let names = BuddyCharacter.allCases.map(\.defaultName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test("a blank stored name resolves to the character's default")
    func resolvedName() {
        #expect(NotchBuddySettings().resolvedName == "Dot")
        #expect(NotchBuddySettings(character: "cat").resolvedName == "Pixel")
        #expect(NotchBuddySettings(character: "cat", buddyName: "Nori").resolvedName == "Nori")
        #expect(NotchBuddySettings(character: "cat", buddyName: "   ").resolvedName == "Pixel",
                "spaces are not a name")
        // An unrecognised character names itself after Dot.
        #expect(NotchBuddySettings(character: "dragon").resolvedName == "Dot")
    }

    @Test("the chosen character, name and care round-trip through ToysState")
    func settingsRoundTrip() throws {
        var state = ToysState()
        var care = BuddyCare()
        care.pet(at: Date(timeIntervalSince1970: 1_700_000_000))
        state.notchBuddy = NotchBuddySettings(enabled: true, character: "owl",
                                              buddyName: "Hoot", care: care)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ToysState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.notchBuddy.resolvedCharacter == .owl)
        #expect(decoded.notchBuddy.resolvedName == "Hoot")
        #expect(decoded.notchBuddy.care.petCount == 1)
    }
}
