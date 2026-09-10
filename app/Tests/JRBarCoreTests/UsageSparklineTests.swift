import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage sparkline")
struct UsageSparklineTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    static func day(_ date: String, tokens: Int) -> UsageHistoryDay {
        // Split over the three token fields so the reduction has to add
        // them up rather than read one of them.
        UsageHistoryDay(date: date, tokensIn: tokens / 2, tokensOut: tokens / 4, cacheRead: tokens - tokens / 2 - tokens / 4, costUsd: 0)
    }

    @Test("a week of history reduces to seven totals, oldest first")
    func sevenDays() {
        let history = UsageHistory(provider: "claude", range: "7d", days: [
            Self.day("2026-09-04", tokens: 100), Self.day("2026-09-05", tokens: 200), Self.day("2026-09-06", tokens: 0),
            Self.day("2026-09-07", tokens: 400), Self.day("2026-09-08", tokens: 800), Self.day("2026-09-09", tokens: 300),
            Self.day("2026-09-10", tokens: 600),
        ])
        let values = UsageSparkline.tokensPerDay(history, endingOn: Self.date("2026-09-10"), calendar: Self.calendar)
        #expect(values.count == UsageSparkline.days)
        #expect(values == [100, 200, 0, 400, 800, 300, 600])
        #expect(values.last == 600, "the newest day is last, so the bar under the pointer is today")
    }

    @Test("days the history does not carry are zero, and older days are dropped")
    func gaps() {
        let history = UsageHistory(provider: "codex", range: "30d", days: [
            Self.day("2026-08-01", tokens: 999_999),      // outside the window
            Self.day("2026-09-06", tokens: 50),
            Self.day("2026-09-10", tokens: 70),
        ])
        let values = UsageSparkline.tokensPerDay(history, endingOn: Self.date("2026-09-10"), calendar: Self.calendar)
        #expect(values == [0, 0, 50, 0, 0, 0, 70])
        #expect(!values.contains(999_999), "a day older than the window never reaches the strip")
    }

    @Test("normalising scales to the peak and survives an all-zero week")
    func normalising() {
        #expect(UsageSparkline.normalised([0, 25, 50, 100]) == [0, 0.25, 0.5, 1])
        #expect(UsageSparkline.normalised([0, 0, 0]) == [0, 0, 0], "no divide by zero, just a flat baseline")
        #expect(UsageSparkline.normalised([]) == [])
        #expect(UsageSparkline.normalised([-5, 10]) == [0, 1], "a negative day cannot draw below the baseline")
    }

    @Test("a week with nothing in it has no signal, so the row draws no sparkline")
    func signal() {
        #expect(!UsageSparkline.hasSignal([0, 0, 0, 0, 0, 0, 0]))
        #expect(!UsageSparkline.hasSignal([]))
        #expect(UsageSparkline.hasSignal([0, 0, 1]))
    }

    @Test("an empty history reduces to a quiet week rather than nothing")
    func empty() {
        let values = UsageSparkline.tokensPerDay(UsageHistory(provider: "gemini", range: "7d"),
                                                 endingOn: Self.date("2026-09-10"), calendar: Self.calendar)
        #expect(values == [0, 0, 0, 0, 0, 0, 0])
        #expect(!UsageSparkline.hasSignal(values))
    }
}
