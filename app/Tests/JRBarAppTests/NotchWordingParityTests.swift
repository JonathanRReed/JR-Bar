import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Notch shared wording stays byte-identical")
struct NotchWordingParityTests {
    @Test func resetCountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Typed tables keep CI's older type checker inside its time limit.
        let cases: [(Double, String)] = [(0, "reset — waiting for a new reading"),
                                         (1, "resets in 1m"), (3720, "resets in 1h 02m"),
                                         (3600, "resets in 1h 00m"), (331_200, "resets in 3d 20h")]
        for (seconds, text) in cases {
            #expect(PanelStore.countdown(to: now.timeIntervalSince1970 + seconds, now: now) == text)
        }
        #expect(PanelStore.countdown(to: nil, now: now) == nil)
    }

    @Test func percent() {
        #expect(UsageWindowLabel.percent(nil) == "—")
        let cases: [(Double, String)] = [(-1, "0%"), (42, "42%"), (99.6, "99%"), (99.95, "100%"), (101, "100%")]
        for (value, text) in cases {
            #expect(UsageWindowLabel.percent(value) == text)
        }
    }

    @Test func askAge() {
        let cases: [(Double, String)] = [(-1, "a while"), (59, "under a minute"), (60, "1 minute"),
                                         (120, "2 minutes"), (3600, "1 hour"), (169_200, "47 hours"),
                                         (172_800, "2 days"), (259_200, "3 days")]
        for (seconds, text) in cases {
            #expect(CoreAsk.ageWords(seconds) == text)
        }
    }

    @Test func calendarHeadsUp() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ShelfMeetingWatch.countdown(to: now.addingTimeInterval(20), now: now) == "now")
        #expect(ShelfMeetingWatch.countdown(to: now.addingTimeInterval(45), now: now) == "in 1 min")
        #expect(ShelfMeetingWatch.countdown(to: now.addingTimeInterval(110), now: now) == "in 2 min")
    }
}
