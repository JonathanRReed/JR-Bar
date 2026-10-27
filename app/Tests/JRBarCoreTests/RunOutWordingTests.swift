import Foundation
import JRBarCore
import Testing

@Suite("Run-out wording")
struct RunOutWordingTests {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let us = Locale(identifier: "en_US")
    static let gb = Locale(identifier: "en_GB")

    static func epoch(_ text: String) -> Double {
        ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970
    }

    @Test func relativeDurationsAndDefaults() {
        let cases: [(Double, String)] = [
            (1, "in 1m"), (29, "in 1m"), (60, "in 1m"), (61, "in 2m"),
            (65 * 60, "in 1h 05m"), (200 * 60, "in 3h 20m"),
            (52 * 3600, "in 2d 4h"), (9 * 86400, "in 9d 0h"),
        ]
        for (seconds, expected) in cases {
            #expect(UsageTime.runOutWhen(at: seconds, now: 0) == expected)
            #expect(UsageTime.runsOut(at: seconds, now: 0) == "Runs out \(expected)")
        }
        for setting: String? in [nil, "", "invalid", "time_left"] {
            #expect(UsageRunOutStyle(setting: setting) == .timeLeft)
        }
        #expect(UsageRunOutStyle(setting: "clock") == .clock)
    }

    @Test(arguments: ["en_US", "en_GB"], UsageRunOutStyle.allCases)
    func calendarMatrix(localeID: String, style: UsageRunOutStyle) {
        let locale = Locale(identifier: localeID)
        let now = Self.epoch("2027-01-11T12:00:00Z")
        let cases: [(String, String)] = [
            ("2027-01-11T15:20:00Z", ""),
            ("2027-01-12T10:00:00Z", "tomorrow"),
            ("2027-01-13T10:00:00Z", "Wed"),
            ("2027-01-14T10:00:00Z", "Thu"),
            ("2027-01-15T10:00:00Z", "Fri"),
            ("2027-01-16T10:00:00Z", "Sat"),
            ("2027-01-17T10:00:00Z", "Sun"),
            ("2027-01-18T10:00:00Z", "Jan"),
            ("2027-01-20T10:00:00Z", "Jan"),
        ]
        for (stamp, day) in cases {
            let at = Self.epoch(stamp)
            let forms = UsageTime.runOutForms(at: at, now: now, locale: locale, timeZone: Self.utc, style: style)
            #expect(forms.count == 4)
            #expect(forms[0] == UsageTime.runsOut(at: at, now: now, locale: locale, timeZone: Self.utc, style: style))
            for form in forms {
                if style == .timeLeft { #expect(form.contains(" in ") || form.hasSuffix(" left")) }
                else if day == "tomorrow" {
                    #expect(form.contains("tomorrow") || form.contains("Tue"))
                } else if !day.isEmpty { #expect(form.contains(day)) }
            }
            if style == .clock {
                let clock = UsageTime.clock(at, locale: locale, timeZone: Self.utc)
                #expect(forms[0].contains(clock))
                #expect(forms[0].contains(localeID == "en_US" ? "M" : ":"))
            }
        }
    }

    @Test func midnightAndDaylightSaving() {
        let midnight = Self.epoch("2027-01-11T23:50:00Z")
        let after = Self.epoch("2027-01-12T00:10:00Z")
        #expect(UsageTime.runOutWhen(at: after, now: midnight, locale: Self.gb, timeZone: Self.utc, style: .clock) == "tomorrow 00:10")
        #expect(UsageTime.runOutWhen(at: after, now: midnight) == "in 20m")
        let zone = TimeZone(identifier: "America/Chicago")!
        let pairs: [(String, String, String)] = [
            ("2027-03-13T18:00:00Z", "2027-03-14T17:00:00Z", "in 23h 00m"),
            ("2027-11-06T17:00:00Z", "2027-11-07T18:00:00Z", "in 1d 1h"),
        ]
        for (start, end, duration) in pairs {
            let now = Self.epoch(start)
            let at = Self.epoch(end)
            for locale in [Self.us, Self.gb] {
                #expect(UsageTime.runOutWhen(at: at, now: now, locale: locale, timeZone: zone) == duration)
                let forms = UsageTime.runOutForms(at: at, now: now, locale: locale, timeZone: zone, style: .clock)
                #expect(forms[0].hasPrefix("Runs out tomorrow "))
                #expect(forms[3].hasPrefix("Out Sun "))
            }
        }
    }

    @Test(arguments: UsageRunOutStyle.allCases)
    func pastForecastIsNeverFuture(style: UsageRunOutStyle) {
        for at: Double in [0, 99, 100] {
            #expect(UsageTime.runsOut(at: at, now: 100, style: style) == "Forecast passed")
            #expect(UsageTime.runOutForms(at: at, now: 100, style: style).allSatisfy { $0 == "Forecast passed" })
            var forecast = UsageForecast(window: "7d", usedPct: 70, resetsAt: 1000,
                verdict: .runsOut(exhaustsAt: at), ratePctPerHour: 10, source: .daemon)
            forecast.runOutStyle = style
            #expect(forecast.verdictWord(now: Date(timeIntervalSince1970: 100)) == "Forecast passed")
            #expect(!forecast.headline(now: Date(timeIntervalSince1970: 100)).contains("Runs out"))
        }
    }

    @Test func resetWinsForBothForecastSources() {
        let now = 1_800_000_000.0
        let samples: [UsageSample] = [UsageSample(at: now - 1800, usedPct: 50), UsageSample(at: now, usedPct: 60)]
        for offset: Double in [3600, 7200, 7201] {
            let window = CoreUsageWindow(name: "7d", usedPct: 60, resetsAt: now + offset)
            let daemon = CoreUsageForecast(exhaustsAt: now + 7200, pace: "on")
            for source: CoreUsageForecast? in [nil, daemon] {
                let forecast = UsageForecaster.forecast(window: window, daemon: source, samples: samples, now: now)
                if offset <= 7200 { #expect(forecast.verdict == .comfortable) }
                else { #expect(forecast.verdict == .runsOut(exhaustsAt: now + 7200)) }
            }
        }
    }
}
