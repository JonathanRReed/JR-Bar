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

    @Test("the roster is the six shipped characters, raw values stable")
    func rosterIsStable() {
        #expect(Set(BuddyCharacter.allCases.map(\.rawValue))
                == ["dot", "cat", "ghost", "robot", "owl", "slime"])
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

    @Test("the chosen character round-trips through ToysState")
    func settingsRoundTrip() throws {
        var state = ToysState()
        state.notchBuddy = NotchBuddySettings(enabled: true, character: "owl")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ToysState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.notchBuddy.resolvedCharacter == .owl)
    }
}
