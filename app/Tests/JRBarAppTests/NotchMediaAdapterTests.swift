import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Now Playing helper's line protocol and evidence line. No helper
/// is launched: the parse and the log wording are pure.
@Suite("Notch media adapter")
@MainActor
struct NotchMediaAdapterTests {
    @Test("null, blank and unparseable lines are nothing playing")
    func nothingPlaying() {
        #expect(AlcoveMediaAdapter.parse(Data("null".utf8)) == nil)
        #expect(AlcoveMediaAdapter.parse(Data("   ".utf8)) == nil)
        #expect(AlcoveMediaAdapter.parse(Data("{not json".utf8)) == nil)
    }

    @Test("the first answer's evidence line says how long, and whether a track was playing")
    func evidence() {
        #expect(AlcoveMediaAdapter.firstLineNote(after: 0.2374, track: true)
                == "helper live after 237 ms — a track is playing")
        #expect(AlcoveMediaAdapter.firstLineNote(after: 1.5, track: false)
                == "helper live after 1500 ms — nothing playing")
    }
}
