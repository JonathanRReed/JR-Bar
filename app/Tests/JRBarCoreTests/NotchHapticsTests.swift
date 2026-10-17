import Foundation
import Testing
@testable import JRBarCore

/// When the island taps a trackpad, as pure facts.
@Suite("Notch haptics")
struct NotchHapticsTests {
    @Test("a tap needs the one switch and a live island, and Reduce Motion is not a condition")
    func tapGate() {
        for moment in NotchHaptics.Moment.allCases {
            #expect(NotchHaptics.fires(moment, switchOn: true, live: true))
            #expect(!NotchHaptics.fires(moment, switchOn: false, live: true))
            #expect(!NotchHaptics.fires(moment, switchOn: true, live: false))
        }
    }

    @Test("a thing arriving taps generic, a thing snapping into place taps alignment")
    func patterns() {
        #expect(NotchHaptics.pattern(for: .open) == .generic)
        #expect(NotchHaptics.pattern(for: .pageTurn) == .alignment)
        #expect(NotchHaptics.pattern(for: .gestureFold) == .alignment)
    }

    @Test("the moments are exactly the ones a hand makes, never an arrival of news")
    func momentsAreHandMade() {
        #expect(Set(NotchHaptics.Moment.allCases) == [.open, .pageTurn, .gestureFold])
    }
}
