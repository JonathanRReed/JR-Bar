import Foundation
import Testing
@testable import JRBarCore

/// A whole-number percent is a promise. "100% used" says the window is
/// spent and "0% left" says nothing is left; neither may be printed for a
/// window that still has room, and no value may trap the conversion.
@Suite("Whole percents never overstate")
struct WholePercentTests {
    @Test("99.6 used is 99, and only a spent window reads 100")
    func neverFullEarly() {
        #expect(UsageWindowLabel.wholeUsed(99.6) == 99)
        #expect(UsageWindowLabel.wholeUsed(99.94) == 99)
        #expect(UsageWindowLabel.wholeUsed(99.95) == 100)
        #expect(UsageWindowLabel.wholeUsed(100) == 100)
        #expect(UsageWindowLabel.wholeUsed(42.4) == 42)
        #expect(UsageWindowLabel.wholeUsed(0) == 0)
    }

    @Test("0.4 left is 1 left, and only a spent window has none")
    func neverEmptyEarly() {
        #expect(UsageWindowLabel.wholeLeft(usedPct: 99.6) == 1)
        #expect(UsageWindowLabel.wholeLeft(usedPct: 99.95) == 0)
        #expect(UsageWindowLabel.wholeLeft(usedPct: 100) == 0)
        #expect(UsageWindowLabel.wholeLeft(usedPct: 0) == 100)
        #expect(UsageWindowLabel.wholeLeft(usedPct: 58.6) == 41)
    }

    @Test("a value out of range or not a number is clamped, never trapped")
    func clamps() {
        #expect(UsageWindowLabel.wholeUsed(-5) == 0)
        #expect(UsageWindowLabel.wholeUsed(250) == 100)
        #expect(UsageWindowLabel.wholeUsed(1e300) == 100)
        #expect(UsageWindowLabel.wholeUsed(.infinity) == 100)
        #expect(UsageWindowLabel.wholeUsed(-.infinity) == 0)
        #expect(UsageWindowLabel.wholeUsed(.nan) == 0)
        #expect(UsageWindowLabel.wholeLeft(usedPct: 1e300) == 0)
    }

    @Test("the percent column and the spoken form use the same rule")
    func labelsAgree() {
        #expect(UsageWindowLabel.percent(99.6) == "99%")
        #expect(UsageWindowLabel.spoken(99.6) == "99 percent used")
        #expect(UsageWindowLabel.percent(1e300) == "100%")
        #expect(UsageWindowLabel.percent(100) == "100%")
    }

    @Test("the forecast headline never says 0% left for a window with room")
    func forecastHeadline() {
        let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 99.6, resetsAt: nil)
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: [], now: 1_788_982_892)
        #expect(!forecast.headline(now: Date(timeIntervalSince1970: 1_788_982_892)).contains("0% left"))
    }
}

@Suite("Countdowns and conversions never trap on a daemon's number")
struct SaturatingNumberTests {
    @Test("a saturating Int stops at the edge and reads NaN as zero")
    func saturates() {
        #expect(Int(saturating: 42.9) == 42)
        #expect(Int(saturating: -42.9) == -42)
        #expect(Int(saturating: .nan) == 0)
        #expect(Int(saturating: .infinity) == 1_000_000_000_000_000)
        #expect(Int(saturating: -1e300) == -1_000_000_000_000_000)
    }

    @Test("a reset time out of range still reads as words")
    func relativeSurvives() {
        let now = Date(timeIntervalSince1970: 1_788_982_892)
        #expect(!UsageForecast.relative(to: 1e300, now: now).isEmpty)
        #expect(!UsageForecast.relative(to: .infinity, now: now).isEmpty)
        #expect(UsageForecast.relative(to: -1e300, now: now) == "now")
    }

    @Test("a reset that has passed never reads as 'resets now'")
    func pastResetHeadline() {
        let now = 1_788_982_892.0
        let window = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 100, resetsAt: now - 3 * 3600)
        let forecast = UsageForecaster.forecast(window: window, daemon: nil, samples: [], now: now)
        let line = forecast.headline(now: Date(timeIntervalSince1970: now))
        #expect(!line.contains("resets now"))
        #expect(line.contains("waiting for a new reading"))
        let spent = CoreUsageWindow(key: "five-hour", name: "5h", usedPct: 100, resetsAt: now + 10)
        let soon = UsageForecaster.forecast(window: spent, daemon: nil, samples: [], now: now)
        #expect(soon.headline(now: Date(timeIntervalSince1970: now)) == "Used up: the 5h window resets now")
    }
}
