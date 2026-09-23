import Foundation
import Testing
@testable import JRBarApp

/// Settings › Devices › Screen Bar's "Right now" line: whose clock the
/// band is on, whether it refused a program, and why it may be still.
@Suite("Screen Bar right-now line")
@MainActor
struct ScreenBarSourceLineTests {
    private func line(live: Bool = true, mirror: Bool = true, strip: Bool = true, offset: Double? = nil,
                      why: String? = nil, rejection: String? = nil, motion: String? = nil,
                      alcove: Bool = false) -> String {
        ScreenBarSourceLine.describe(live: live, mirrorSetting: mirror, stripPresent: strip, phaseOffsetMs: offset,
                                     why: why, rejection: rejection, motionNote: motion, followingAlcove: alcove)
    }

    @Test func namesTheSourceTheBandPlays() {
        #expect(line() == "Mirroring the strip, phase-locked")
        #expect(line(strip: false) == "Its own display — no strip to mirror")
        #expect(line(mirror: false) == "Its own display")
        #expect(line(live: false).hasPrefix("Monitor offline"))
    }

    @Test func aPhaseNudgeIsNamedWithItsSign() {
        #expect(line(offset: 40) == "Mirroring the strip, phase-locked (nudged +40 ms)")
        #expect(line(offset: -120) == "Mirroring the strip, phase-locked (nudged −120 ms)")
        #expect(line(offset: 0.4) == "Mirroring the strip, phase-locked", "under a millisecond is no nudge")
    }

    @Test func offlineItNamesTheFeedTheAppFellBackTo() {
        func offline(_ feed: ScreenBarSourceLine.OfflineFeed?) -> String {
            ScreenBarSourceLine.describe(live: false, mirrorSetting: true, stripPresent: false, phaseOffsetMs: nil,
                                         why: nil, rejection: nil, motionNote: nil, followingAlcove: false,
                                         offlineFeed: feed)
        }
        #expect(offline(.strip) == "Monitor offline — playing the last program the strip was sent")
        // No strip mounted: the band breathes, and says so rather than
        // crediting a strip that is not there.
        #expect(offline(.idleBreath) == "Monitor offline — playing the built-in idle breath")
        #expect(offline(.file) == "Monitor offline — playing the feed file's program")
        #expect(offline(nil) == offline(.strip), "before the feed reports, the strip wording stands")
        #expect(ScreenBarSourceLine.OfflineFeed(.builtInIdle) == .idleBreath)
        #expect(ScreenBarSourceLine.OfflineFeed(.device("/Volumes/SIDEPULSE/LEDS.LED")) == .strip)
        #expect(ScreenBarSourceLine.OfflineFeed(.stateFile("/tmp/feed.led")) == .file)
    }

    @Test func refusalsStillnessAndAlcoveAreSpelledOut() {
        let text = line(why: "ask_waiting", rejection: "too-long", motion: "still while the camera is on", alcove: true)
        #expect(text == "Mirroring the strip, phase-locked · ask waiting · refused a program (too-long), holding the last safe one · still while the camera is on · following Alcove")
        // Offline, the daemon's why is not the band's.
        #expect(!line(live: false, why: "ask_waiting").contains("ask waiting"))
    }
}
