import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Notch shared wording stays byte-identical")
struct NotchWordingParityTests {
    @Test func resetCountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (seconds, text) in [(0.0, "reset — waiting for a new reading"),
                                (1, "resets in 1m"), (62 * 60, "resets in 1h 02m"),
                                (3600, "resets in 1h 00m"), (3 * 86400 + 20 * 3600, "resets in 3d 20h")] {
            #expect(PanelStore.countdown(to: now.timeIntervalSince1970 + seconds, now: now) == text)
        }
        #expect(PanelStore.countdown(to: nil, now: now) == nil)
    }

    @Test func percent() {
        #expect(UsageWindowLabel.percent(nil) == "—")
        for (value, text) in [(-1.0, "0%"), (42, "42%"), (99.6, "99%"), (99.95, "100%"), (101, "100%")] {
            #expect(UsageWindowLabel.percent(value) == text)
        }
    }

    @Test func askAge() {
        for (seconds, text) in [(-1.0, "a while"), (59, "under a minute"), (60, "1 minute"),
                                (120, "2 minutes"), (3600, "1 hour"), (47 * 3600, "47 hours"),
                                (48 * 3600, "2 days"), (3 * 86400, "3 days")] {
            #expect(CoreAsk.ageWords(seconds) == text)
        }
    }
}
