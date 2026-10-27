import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage clock formatting")
struct UsageTimeFormattingTests {
    private static let stamp = 1_800_000_000.0
    private static let locales = ["en_US", "en_GB", "fr_FR", "ar_EG", "th_TH"]
    private static let zones = ["GMT", "America/Chicago", "Asia/Kolkata"]

    @Test(arguments: locales, zones)
    func clockMatchesFoundation(localeID: String, zoneID: String) throws {
        let locale = Locale(identifier: localeID)
        let zone = try #require(TimeZone(identifier: zoneID))
        let reference = DateFormatter()
        reference.locale = locale
        reference.timeZone = zone
        reference.setLocalizedDateFormatFromTemplate("jm")
        for offset in [0.0, 60, 3600, 86400] {
            let epoch = Self.stamp + offset
            let expected = reference.string(from: Date(timeIntervalSince1970: epoch))
            #expect(UsageTime.clock(epoch, locale: locale, timeZone: zone) == expected)
        }
    }

    @Test(arguments: locales, zones)
    func resetMatchesFoundation(localeID: String, zoneID: String) throws {
        let locale = Locale(identifier: localeID)
        let zone = try #require(TimeZone(identifier: zoneID))
        for days in [1.0, 8] {
            let epoch = Self.stamp + days * 86400
            let reference = DateFormatter()
            reference.locale = locale
            reference.timeZone = zone
            reference.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEjm" : "MMM d jm")
            let expected = reference.string(from: Date(timeIntervalSince1970: epoch))
            #expect(UsageTime.resetLine(epoch, now: Self.stamp, locale: locale, timeZone: zone) == expected)
        }
    }

    @Test func concurrentClocksKeepTheirConfiguration() async {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let locale = Locale(identifier: Self.locales[index % Self.locales.count])
                    let zone = TimeZone(secondsFromGMT: index % 3 * 3600)!
                    let epoch = Self.stamp + Double(index) * 3600
                    let reference = DateFormatter()
                    reference.locale = locale
                    reference.timeZone = zone
                    reference.setLocalizedDateFormatFromTemplate("jm")
                    let expected = reference.string(from: Date(timeIntervalSince1970: epoch))
                    return UsageTime.clock(epoch, locale: locale, timeZone: zone) == expected
                }
            }
            for await matches in group { #expect(matches) }
        }
    }

    @Test(arguments: locales, zones)
    func keepAwakeClockMatchesFoundation(localeID: String, zoneID: String) throws {
        var reading = KeepAwakeReading(state: .off)
        reading.locale = Locale(identifier: localeID)
        reading.timeZone = try #require(TimeZone(identifier: zoneID))
        let reference = DateFormatter()
        reference.locale = reading.locale
        reference.timeZone = reading.timeZone
        reference.setLocalizedDateFormatFromTemplate("jmm")
        let date = Date(timeIntervalSince1970: Self.stamp)
        #expect(reading.clock(date) == reference.string(from: date))
    }

    @Test func warmReadsReuseTheFormatter() {
        let cache = UsageDateFormatters()
        let locale = Locale(identifier: "en_US")
        let zone = TimeZone(secondsFromGMT: 0)!
        let first = cache.withFormatter(locale: locale, timeZone: zone, format: .template("jm")) { $0 }
        for minute in 0..<100 {
            let next = cache.withFormatter(locale: locale, timeZone: zone, format: .template("jm")) { $0 }
            #expect(next === first)
            let date = Date(timeIntervalSince1970: Self.stamp + Double(minute * 60))
            let text = cache.withFormatter(locale: locale, timeZone: zone, format: .template("jm")) {
                $0.string(from: date)
            }
            #expect(text == first.string(from: date))
        }
    }

    @Test func oldConfigurationsAreEvicted() {
        let cache = UsageDateFormatters()
        let locale = Locale(identifier: "en_US")
        let zone = TimeZone(secondsFromGMT: 0)!
        let first = cache.withFormatter(locale: locale, timeZone: zone, format: .template("jm")) { $0 }
        for hour in 1...UsageDateFormatters.capacity {
            let otherZone = TimeZone(secondsFromGMT: hour * 3600)!
            _ = cache.withFormatter(locale: locale, timeZone: otherZone, format: .template("jm")) { $0 }
        }
        let rebuilt = cache.withFormatter(locale: locale, timeZone: zone, format: .template("jm")) { $0 }
        #expect(rebuilt !== first)
    }

    @Test(arguments: locales)
    func dayPeriodsMatchFoundation(localeID: String) {
        let locale = Locale(identifier: localeID)
        let reference = DateFormatter()
        reference.locale = locale
        let expected = [reference.amSymbol, reference.pmSymbol].filter { !$0.isEmpty }
        #expect(UsageTime.dayPeriods(locale: locale) == expected)
    }

    @Test(arguments: zones)
    func shortClockKeepsTheCalendar(zoneID: String) throws {
        let identifiers: [Calendar.Identifier] = [.gregorian, .buddhist]
        for identifier in identifiers {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = try #require(TimeZone(identifier: zoneID))
            let reference = DateFormatter()
            reference.calendar = calendar
            reference.timeZone = calendar.timeZone
            reference.dateStyle = .none
            reference.timeStyle = .short
            let date = Date(timeIntervalSince1970: Self.stamp)
            #expect(UsageTime.shortClock(date, calendar: calendar) == reference.string(from: date))
        }
    }
}
