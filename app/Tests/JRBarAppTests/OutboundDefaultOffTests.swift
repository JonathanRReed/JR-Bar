import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Nothing leaves the Mac on a first launch: the notch card's lyrics lookup
/// stays off, and unagreed, until the person turns it on. (Lyrics has its
/// own proof in `NotchLyricsTests`, and the daemon's features in
/// `tests/test_outbound_default_off.py`.)
@Suite("Outbound requests are off by default")
@MainActor
struct OutboundDefaultOffTests {
    @Test("a first-launch notch settings value has lyrics off")
    func defaultsAreOff() throws {
        for notch in [NotchSettings(),
                      try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))] {
            #expect(!notch.lyrics)
            #expect(!notch.lyricsConsented)
            #expect(!notch.lyricsAllowed)
        }
    }

    @Test("a saved file that still carries the retired weather keys loads, and they change nothing")
    func retiredWeatherKeysAreIgnored() throws {
        let saved = #"{"weather": true, "weatherCity": "London", "weatherUseIPLocation": true}"#
        let notch = try JSONDecoder().decode(NotchSettings.self, from: Data(saved.utf8))
        #expect(notch == NotchSettings())
    }
}
