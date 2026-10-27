import Foundation
import Testing
@testable import JRBarCore

/// Seasonal touches' dates: JR-Bar's own rules, the calendars' names for
/// the days, the switches, birthdays and which holiday wins a shared day.
/// All synthetic: no real calendar or contact is read.
@Suite("Seasonal dates")
struct SeasonalTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func rules(_ date: Date, region: String = "US") -> [SeasonalHoliday] {
        SeasonalRules.occasions(on: date, calendar: calendar, region: region).map(\.holiday)
    }

    private static let on = SeasonalSettings(enabled: true)

    @Test("fixed days land where they belong")
    func fixedDays() {
        #expect(Self.rules(Self.day(2026, 10, 31)) == [.halloween])
        #expect(Self.rules(Self.day(2026, 10, 30)).isEmpty)
        #expect(Self.rules(Self.day(2027, 2, 2)) == [.groundhogDay])
        // Valentine's Day 2027 falls in Ramadan; the single day wins it.
        #expect(Self.rules(Self.day(2027, 2, 14)).contains(.valentines))
        #expect(SeasonalResolver.occasion(on: Self.day(2027, 2, 14), settings: Self.on, entries: nil,
                                          calendar: Self.calendar, region: "US")?.holiday == .valentines)
        #expect(Self.rules(Self.day(2027, 3, 17)) == [.stPatricks])
        #expect(Self.rules(Self.day(2027, 4, 22)) == [.earthDay])
        #expect(Self.rules(Self.day(2027, 6, 15)) == [.pride])
        #expect(Self.rules(Self.day(2027, 7, 4)) == [.independenceDay])
        #expect(Self.rules(Self.day(2026, 11, 2)) == [.diaDeMuertos])
        #expect(Self.rules(Self.day(2026, 12, 24)).contains(.christmas))
        #expect(Self.rules(Self.day(2026, 12, 31)).contains(.newYear))
        #expect(Self.rules(Self.day(2027, 1, 1)).contains(.newYear))
    }

    @Test("regional days follow the region")
    func regional() {
        #expect(Self.rules(Self.day(2026, 11, 26)) == [.thanksgiving], "US: fourth Thursday")
        #expect(Self.rules(Self.day(2026, 11, 26), region: "CA").isEmpty)
        #expect(Self.rules(Self.day(2026, 10, 12), region: "CA") == [.thanksgiving], "Canada: second Monday")
        #expect(!Self.rules(Self.day(2027, 7, 4), region: "GB").contains(.independenceDay))
        #expect(!Self.rules(Self.day(2027, 2, 2), region: "FR").contains(.groundhogDay))
    }

    @Test("Easter by the computus")
    func easter() {
        #expect(SeasonalRules.easterSunday(year: 2026)! == (4, 5))
        #expect(SeasonalRules.easterSunday(year: 2027)! == (3, 28))
        #expect(SeasonalRules.easterSunday(year: 2028)! == (4, 16))
        #expect(Self.rules(Self.day(2027, 3, 28)) == [.easter])
    }

    @Test("Hanukkah lights a candle more each night from 24 Kislev")
    func hanukkah() {
        // 2026: the first candle on the evening of Friday 4 December.
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2026, 12, 3), calendar: Self.calendar) == nil)
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2026, 12, 4), calendar: Self.calendar) == 1)
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2026, 12, 11), calendar: Self.calendar) == 8)
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2026, 12, 12), calendar: Self.calendar) == nil)
        // 2027 runs past New Year.
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2027, 12, 24), calendar: Self.calendar) == 1)
        #expect(SeasonalRules.hanukkahNight(on: Self.day(2027, 12, 31), calendar: Self.calendar) == 8)
    }

    @Test("Ramadan and Eid from the Umm al-Qura calendar, Lunar New Year from the Chinese")
    func lunarCalendars() {
        // Ramadan 1448 begins 8 February 2027; Eid al-Fitr is 9 March.
        let ramadan = SeasonalRules.ramadanEid(on: Self.day(2027, 2, 8), calendar: Self.calendar)
        #expect(ramadan?.phase == .ramadan && ramadan?.day == 1)
        let eid = SeasonalRules.ramadanEid(on: Self.day(2027, 3, 9), calendar: Self.calendar)
        #expect(eid?.phase == .eid && eid?.day == 1)
        #expect(SeasonalRules.ramadanEid(on: Self.day(2027, 4, 20), calendar: Self.calendar) == nil)
        // The Year of the Goat begins 6 February 2027.
        #expect(SeasonalRules.lunarNewYearDay(on: Self.day(2027, 2, 6), calendar: Self.calendar) == 1)
        #expect(SeasonalRules.lunarNewYearDay(on: Self.day(2027, 2, 8), calendar: Self.calendar) == 3)
        #expect(SeasonalRules.lunarNewYearDay(on: Self.day(2027, 2, 9), calendar: Self.calendar) == nil)
        #expect(SeasonalRules.lunarNewYearDay(on: Self.day(2027, 2, 5), calendar: Self.calendar) == nil)
    }

    @Test("Kwanzaa counts its days into the new year")
    func kwanzaa() {
        let first = SeasonalRules.occasions(on: Self.day(2026, 12, 26), calendar: Self.calendar, region: "US")
        #expect(first.first { $0.holiday == .kwanzaa }?.day == 1)
        let last = SeasonalRules.occasions(on: Self.day(2027, 1, 1), calendar: Self.calendar, region: "US")
        #expect(last.first { $0.holiday == .kwanzaa }?.day == 7)
    }

    @Test("calendar titles name the sets, and leave the days left plain")
    func titles() {
        #expect(SeasonalResolver.holiday(named: "Christmas Day") == .christmas)
        #expect(SeasonalResolver.holiday(named: "Christmas Eve") == .christmas)
        #expect(SeasonalResolver.holiday(named: "New Year’s Eve") == .newYear)
        #expect(SeasonalResolver.holiday(named: "Lunar New Year") == .lunarNewYear)
        #expect(SeasonalResolver.holiday(named: "Chinese New Year") == .lunarNewYear)
        #expect(SeasonalResolver.holiday(named: "Rosh Hashanah") == nil)
        #expect(SeasonalResolver.holiday(named: "First Day of Hanukkah") == .hanukkah)
        #expect(SeasonalResolver.holiday(named: "Chanukah") == .hanukkah)
        #expect(SeasonalResolver.holiday(named: "Eid al-Fitr") == .ramadanEid)
        #expect(SeasonalResolver.holiday(named: "Eid al-Adha") == nil)
        #expect(SeasonalResolver.holiday(named: "Día de los Muertos") == .diaDeMuertos)
        #expect(SeasonalResolver.holiday(named: "St. Patrick's Day") == .stPatricks)
        #expect(SeasonalResolver.holiday(named: "Independence Day") == .independenceDay)
        for plain in ["Memorial Day", "Veterans Day", "Good Friday", "Ash Wednesday", "Yom Kippur",
                      "Martin Luther King Jr. Day", "Juneteenth", "Election Day", "Tax Day",
                      "Daylight Saving Time starts"] {
            #expect(SeasonalResolver.holiday(named: plain) == nil, "\(plain) stays plain")
        }
    }

    @Test("off means nothing, and each holiday has its own switch")
    func switches() {
        let halloween = Self.day(2026, 10, 31)
        #expect(SeasonalResolver.occasion(on: halloween, settings: SeasonalSettings(), entries: nil,
                                          calendar: Self.calendar, region: "US") == nil)
        #expect(SeasonalResolver.occasion(on: halloween, settings: Self.on, entries: nil,
                                          calendar: Self.calendar, region: "US")?.holiday == .halloween)
        var settings = Self.on
        settings.set(.halloween, on: false)
        #expect(!settings.isOn(.halloween))
        #expect(SeasonalResolver.occasion(on: halloween, settings: settings, entries: nil,
                                          calendar: Self.calendar, region: "US") == nil)
        settings.set(.halloween, on: true)
        #expect(settings.off.isEmpty)
    }

    @Test("a calendar's day counts even where the rules have none, and spans run from its first day")
    func calendarDays() {
        // A calendar that keeps Ramadan a day later than Umm al-Qura.
        let start = Self.day(2027, 2, 9, hour: 0)
        let entries = [SeasonalCalendarEntry(title: "Ramadan begins", start: start,
                                             end: start.addingTimeInterval(86_400))]
        let third = SeasonalResolver.all(on: Self.day(2027, 2, 11), settings: Self.on, entries: entries,
                                         calendar: Self.calendar, region: "US")
        #expect(third.first?.holiday == .ramadanEid && third.first?.fromCalendar == true)
        // A Hanukkah listed only by its first day still runs eight nights.
        let hanukkah = Self.day(2030, 12, 20, hour: 0)
        let listed = [SeasonalCalendarEntry(title: "Hanukkah", start: hanukkah, end: hanukkah.addingTimeInterval(86_400))]
        let sixth = SeasonalResolver.occasion(on: Self.day(2030, 12, 25), settings: Self.on, entries: listed,
                                              calendar: Self.calendar, region: "XX")
        #expect(sixth?.holiday == .hanukkah || sixth?.holiday == .christmas)
        let nights = SeasonalResolver.all(on: Self.day(2030, 12, 25), settings: Self.on, entries: listed,
                                          calendar: Self.calendar, region: "XX")
        #expect(nights.first { $0.holiday == .hanukkah }?.day ?? 0 >= 5)
    }

    @Test("a shared day goes to the birthday, then the single day, then the long spans")
    func precedence() {
        // Halloween inside nothing else; Pride under Independence Day? No — June
        // holds Pride alone, and a birthday in June outranks it.
        var settings = Self.on
        let june = Self.day(2027, 6, 9)
        let own = DateComponents(month: 6, day: 9)
        let mine = SeasonalResolver.occasion(on: june, settings: settings, entries: nil, ownBirthday: own,
                                             calendar: Self.calendar, region: "US")
        #expect(mine?.holiday == .birthday && mine?.name == nil)
        #expect(mine?.caption == "Happy birthday")
        settings.set(.birthday, on: false)
        let pride = SeasonalResolver.occasion(on: june, settings: settings, entries: nil, ownBirthday: own,
                                              calendar: Self.calendar, region: "US")
        #expect(pride?.holiday == .pride)
        // Christmas Day outranks a Kwanzaa or Hanukkah night it shares.
        let christmas = SeasonalResolver.occasion(on: Self.day(2027, 12, 25), settings: Self.on, entries: nil,
                                                  calendar: Self.calendar, region: "US")
        #expect(christmas?.holiday == .christmas)
    }

    @Test("only tagged people's birthdays count, and names come from the calendar's title")
    func birthdays() {
        let day = Self.day(2027, 5, 3, hour: 0)
        let entries = [
            SeasonalCalendarEntry(title: "Alex Rivera’s Birthday", start: day, end: day.addingTimeInterval(86_400),
                                  isBirthday: true, contactID: "contact-alex"),
            SeasonalCalendarEntry(title: "Sam Lee’s Birthday", start: day, end: day.addingTimeInterval(86_400),
                                  isBirthday: true, contactID: "contact-sam"),
        ]
        #expect(SeasonalResolver.occasion(on: Self.day(2027, 5, 3), settings: Self.on, entries: entries,
                                          calendar: Self.calendar, region: "US") == nil, "nobody tagged")
        var settings = Self.on
        settings.celebrated = [SeasonalPerson(id: "contact-sam", name: "Sam Lee")]
        let sam = SeasonalResolver.occasion(on: Self.day(2027, 5, 3), settings: settings, entries: entries,
                                            calendar: Self.calendar, region: "US")
        #expect(sam?.holiday == .birthday && sam?.name == "Sam Lee")
        #expect(sam?.caption == "Sam's birthday")
        #expect(SeasonalResolver.birthdayPeople(entries).map(\.name) == ["Alex Rivera", "Sam Lee"])
    }

    @Test("settings read tolerantly and keep unknown holidays")
    func decoding() throws {
        let toys = try JSONDecoder().decode(ToysState.self, from: Data("{}".utf8))
        #expect(!toys.seasonal.enabled)
        let json = #"{"enabled":true,"off":["hanukkah","someFutureDay"],"celebrated":"nope"}"#
        let settings = try JSONDecoder().decode(SeasonalSettings.self, from: Data(json.utf8))
        #expect(settings.enabled && !settings.isOn(.hanukkah) && settings.isOn(.christmas))
        #expect(settings.off.contains("someFutureDay"))
        #expect(settings.celebrated.isEmpty)
        var state = ToysState()
        state.seasonal = settings
        let round = try JSONDecoder().decode(ToysState.self, from: JSONEncoder().encode(state))
        #expect(round.seasonal == settings)
    }

    @Test("every holiday has a name and a when, and all seventeen sets are here")
    func catalogue() {
        #expect(SeasonalHoliday.allCases.count == 17)
        for holiday in SeasonalHoliday.allCases {
            #expect(!holiday.displayName.isEmpty && !holiday.when.isEmpty)
        }
    }
}
