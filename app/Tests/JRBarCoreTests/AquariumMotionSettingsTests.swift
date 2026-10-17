import Foundation
import Testing
@testable import JRBarCore

@Suite("Aquarium motion settings")
struct AquariumMotionSettingsTests {
    @Test func oldAndUnknownModesStayLive() throws {
        for json in ["{}", #"{"motion":"unknown"}"#, #"{"motion":false}"#] {
            let settings = try JSONDecoder().decode(AquariumSettings.self, from: Data(json.utf8))
            #expect(settings.motion == .live)
        }
    }

    @Test func stillRoundTripsWithTheRestOfTheTank() throws {
        var settings = AquariumSettings(enabled: true, density: 0.4)
        settings.motion = .still
        settings.keepResidents = false
        settings.sound = true
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AquariumSettings.self, from: encoded) == settings)
    }
}
