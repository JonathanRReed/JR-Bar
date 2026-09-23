import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// "Follow the sun": the tz database's city for the Mac's time zone, and
/// NOAA's sunrise equations on it. Pinned against published sun times
/// for real cities, to a few minutes — a tank needs no better.
@Suite("Aquarium sun")
struct AquariumSunTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func date(_ text: String, _ zone: TimeZone) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    private func near(_ a: Date?, _ b: Date, minutes: Double = 6) -> Bool {
        guard let a else { return false }
        return abs(a.timeIntervalSince(b)) <= minutes * 60
    }

    @Test("ISO 6709 in zone.tab's two widths, and the malformed rejected")
    func parsesCoordinates() {
        let chicago = AquariumSun.parseISO6709("+415100-0873900")
        #expect(chicago != nil)
        #expect(abs(chicago!.latitude - 41.85) < 0.0001)
        #expect(abs(chicago!.longitude - -87.65) < 0.0001)
        let la = AquariumSun.parseISO6709("+340308-1181434")!
        #expect(abs(la.latitude - (34 + 3 / 60.0 + 8 / 3600.0)) < 0.0001)
        #expect(abs(la.longitude - -(118 + 14 / 60.0 + 34 / 3600.0)) < 0.0001)
        let sydney = AquariumSun.parseISO6709("-3352+15113")!
        #expect(sydney.latitude < 0 && sydney.longitude > 0)
        for junk in ["", "+4151", "415100-0873900", "+4151x0-0873900", "+416100-0873900",
                     "+415100-087390", "+9900+00000"] {
            #expect(AquariumSun.parseISO6709(junk) == nil, "\(junk)")
        }
    }

    @Test("the table skips comments and rows that don't parse")
    func parsesTable() {
        let table = AquariumSun.parseZoneTab("""
        # a comment
        US\t+415100-0873900\tAmerica/Chicago\tCentral (most areas)
        XX\tnonsense\tNowhere/Else
        GB\t+513030-0000731\tEurope/London

        """)
        #expect(table.count == 2)
        #expect(table["America/Chicago"] != nil)
        #expect(table["Europe/London"] != nil)
        #expect(table["Nowhere/Else"] == nil)
        #expect(AquariumSun.coordinate(for: TimeZone(identifier: "UTC")!, table: table) == nil)
        #expect(AquariumSun.coordinate(for: chicago, table: table) != nil)
    }

    @Test("Chicago's solstices land within minutes of the published times")
    func chicagoSolstices() {
        let place = AquariumSun.Coordinate(latitude: 41.85, longitude: -87.65)
        let june = AquariumSun.day(on: date("2026-06-21 12:00", chicago), at: place, zone: chicago)
        #expect(near(june.sunrise, date("2026-06-21 05:15", chicago)))
        #expect(near(june.sunset, date("2026-06-21 20:29", chicago)))
        let december = AquariumSun.day(on: date("2026-12-21 12:00", chicago), at: place, zone: chicago)
        #expect(near(december.sunrise, date("2026-12-21 07:15", chicago)))
        #expect(near(december.sunset, date("2026-12-21 16:22", chicago)))
    }

    @Test("a sunset past UTC midnight still lands on the local day")
    func westCoastSunset() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let place = AquariumSun.Coordinate(latitude: 34.05, longitude: -118.24)
        let day = AquariumSun.day(on: date("2026-06-21 23:30", zone), at: place, zone: zone)
        #expect(near(day.sunset, date("2026-06-21 20:08", zone)))
        #expect(near(day.sunrise, date("2026-06-21 05:42", zone)))
    }

    @Test("the poles: a polar night stays dark, a midnight sun stays bright")
    func poles() {
        let zone = TimeZone(identifier: "Europe/Oslo")!
        let tromso = AquariumSun.Coordinate(latitude: 69.65, longitude: 18.96)
        let winter = AquariumSun.day(on: date("2026-12-21 12:00", zone), at: tromso, zone: zone)
        #expect(winter.alwaysDark)
        #expect(AquariumSun.night(at: date("2026-12-21 12:00", zone), day: winter) == 1)
        let summer = AquariumSun.day(on: date("2026-06-21 00:30", zone), at: tromso, zone: zone)
        #expect(!summer.alwaysDark && summer.sunrise == nil && summer.sunset == nil)
        #expect(AquariumSun.night(at: date("2026-06-21 00:30", zone), day: summer) == 0)
    }

    @Test("a 7:00 sunrise and a 20:00 sunset read exactly like the clock's hours")
    func matchesTheClock() {
        let zone = chicago
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = AquariumSun.Day(sunrise: date("2026-03-10 07:00", zone),
                                  sunset: date("2026-03-10 20:00", zone))
        for time in ["00:30", "05:59", "06:30", "07:00", "07:45", "12:00", "19:00",
                     "19:30", "20:00", "20:45", "21:00", "23:59"] {
            let at = date("2026-03-10 \(time)", zone)
            let sun = AquariumSun.night(at: at, day: day)
            let clock = AquariumBehavior.realTimeNight(at: at, calendar: calendar)
            #expect(abs(sun - clock) < 0.0001, "\(time): sun \(sun) vs clock \(clock)")
        }
    }

    @Test("a December afternoon in Chicago is dark by half past five")
    func winterAfternoon() {
        let place = AquariumSun.Coordinate(latitude: 41.85, longitude: -87.65)
        let noon = date("2026-12-21 12:00", chicago)
        let day = AquariumSun.day(on: noon, at: place, zone: chicago)
        #expect(AquariumSun.night(at: noon, day: day) == 0)
        #expect(AquariumSun.night(at: date("2026-12-21 17:30", chicago), day: day) == 1)
        let dusk = AquariumSun.night(at: date("2026-12-21 16:22", chicago), day: day)
        #expect(dusk > 0.4 && dusk < 0.6, "half dark at sunset: \(dusk)")
        #expect(AquariumBehavior.realTimeNight(at: date("2026-12-21 17:30", chicago),
                                               calendar: { var c = Calendar(identifier: .gregorian)
                                                   c.timeZone = chicago; return c }()) == 0,
                "the fixed hours still call it day — the gap this closes")
    }

    @Test("the Mac's own zone.tab reads, and names Chicago's city")
    func systemTable() throws {
        try #require(FileManager.default.fileExists(atPath: AquariumSun.zoneTabPath))
        let place = try #require(AquariumSun.zoneTable["America/Chicago"])
        #expect(abs(place.latitude - 41.85) < 0.01)
        #expect(AquariumSun.zoneTable.count > 300)
    }

    @Test("the sun mode round-trips")
    func settingsRoundTrip() throws {
        var settings = AquariumSettings()
        settings.dayNight = .sun
        let back = try JSONDecoder().decode(AquariumSettings.self,
                                            from: JSONEncoder().encode(settings))
        #expect(back.dayNight == .sun)
    }
}
