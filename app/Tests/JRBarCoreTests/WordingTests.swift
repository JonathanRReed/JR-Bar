import Foundation
import JRBarCore
import Testing

@Suite("Shared wording")
struct WordingTests {
    @Test func numbers() {
        #expect(UsageNumber.percent(nil) == "—")
        #expect(UsageNumber.percent(99.6) == "99%")
        #expect(UsageNumber.rate(2.43, approximate: true) == "≈ 2.4%/h")
        #expect(UsageNumber.rate(12.4) == "12%/h")
        #expect(UsageNumber.rateLimit(0.00123) == "≤ 0.001%/h")
    }

    @Test func paddedDurations() {
        #expect(UsageTime.duration(30) == "30s")
        #expect(UsageTime.duration(41 * 60) == "41m")
        #expect(UsageTime.duration(65 * 60) == "1h 05m")
        #expect(UsageTime.duration(3 * 86400 + 20 * 3600) == "3d 20h")
        #expect(UsageTime.ago(29) == "now")
        #expect(UsageTime.ago(30) == "30s ago")
    }

    /// "If it doesn't have minutes, just give me 1h." A whole hour or a
    /// whole day drops its zeros; a partial hour keeps its padded minutes.
    /// The daemon's `duration_words` reads the same table
    /// (tests/test_duration_words.py).
    @Test func wholeHoursDropTheMinutes() {
        let table: [(Double, String)] = [
            (3600, "1h"), (3600 + 59, "1h"), (2 * 3600, "2h"), (23 * 3600, "23h"),
            (3600 + 5 * 60, "1h 05m"), (2 * 3600 + 30 * 60, "2h 30m"),
            (86400, "1d"), (3 * 86400, "3d"), (3 * 86400 + 4 * 3600, "3d 4h"),
            (3 * 86400 + 30 * 60, "3d"), (59 * 60, "59m"), (90, "1m 30s"),
        ]
        for (seconds, words) in table {
            #expect(UsageTime.duration(seconds) == words, "\(seconds) s")
        }
    }

    @Test func localizedClockAndReset() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let now = 1_700_006_400.0
        let reset = now + 86400
        #expect(UsageTime.clock(now, locale: Locale(identifier: "en_US"), timeZone: zone).contains(":00"))
        #expect(UsageTime.clock(now, locale: Locale(identifier: "en_GB"), timeZone: zone) == "00:00")
        let later = UsageTime.resetLine(reset, now: now, locale: Locale(identifier: "en_US"), timeZone: zone)
        #expect(later.contains(":00"))
        #expect(UsageTime.resetLine(now - 60, now: now) == "Reset 1m ago")
        #expect(UsageTime.runsOut(at: now + 42 * 60, now: now) == "Runs out in 42m")
    }

    @Test func countdownsUseWholeMinutesAndShortColumns() {
        #expect(UsageTime.resetLine(3418, now: 0) == "in 57m")
        #expect(UsageTime.resetLine(61, now: 0) == "in 2m")
        #expect(UsageTime.resetLine(1, now: 0) == "now")
        #expect(UsageTime.resetLine(30, now: 0) == "in 1m")
        #expect(UsageWindowLabel.column("7d Fable") == "Fable 7d")
        #expect(UsageWindowLabel.column("Gemini Weekly") == "Gemini 7d")
        #expect(UsageWindowLabel.column("Claude + GPT 5-Hour") == "Claude+GPT 5h")
    }

    @Test func everyForecastBranchReportsUsed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for verdict in [UsageForecast.Verdict.comfortable, .unknown, .guarded(reason: "insufficient_samples")] {
            for held in [false, true] {
                let resets: [Double?] = [nil, now.timeIntervalSince1970 + 3600]
                for reset in resets {
                    var forecast = UsageForecast(window: "5h", usedPct: 42, resetsAt: reset,
                                                 verdict: verdict, ratePctPerHour: 0, source: .none)
                    forecast.heldIdle = held
                    let line = forecast.headline(now: now)
                    #expect(line.contains("42% used"))
                    #expect(!line.contains("% left"))
                }
            }
        }
    }
}
