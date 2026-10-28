import Foundation

/// Seasonal touches: on a holiday the toys dress for it — a garland on
/// the Screen Bar, a centrepiece in the notch card, a prop on the tank's
/// sand with a few drifting particles, and an outfit on the buddy. One
/// switch turns the feature on (off by default); every holiday then has
/// its own switch, all on.
///
/// The days come from the person's calendars when they list them (the
/// holiday calendars and Birthdays, read through the same EventKit access
/// the notch uses) and from JR-Bar's own date rules otherwise. Everything
/// here is pure: the app hands in what it read and the day it is.
public enum SeasonalHoliday: String, CaseIterable, Codable, Sendable, Identifiable {
    case newYear
    case lunarNewYear
    case groundhogDay
    case valentines
    case stPatricks
    case ramadanEid
    case easter
    case earthDay
    case pride
    case independenceDay
    case halloween
    case diaDeMuertos
    case thanksgiving
    case hanukkah
    case christmas
    case kwanzaa
    case birthday

    public var id: String { rawValue }

    /// The name in Settings.
    public var displayName: String {
        switch self {
        case .newYear: return "New Year"
        case .lunarNewYear: return "Lunar New Year"
        case .groundhogDay: return "Groundhog Day"
        case .valentines: return "Valentine's Day"
        case .stPatricks: return "St. Patrick's Day"
        case .ramadanEid: return "Ramadan & Eid"
        case .easter: return "Easter"
        case .earthDay: return "Earth Day"
        case .pride: return "Pride"
        case .independenceDay: return "Independence Day"
        case .halloween: return "Halloween"
        case .diaDeMuertos: return "Día de los Muertos"
        case .thanksgiving: return "Thanksgiving"
        case .hanukkah: return "Hanukkah"
        case .christmas: return "Christmas"
        case .kwanzaa: return "Kwanzaa"
        case .birthday: return "Birthdays"
        }
    }

    /// When it comes round, for the Settings list.
    public var when: String {
        switch self {
        case .newYear: return "31 December and 1 January"
        case .lunarNewYear: return "The first three days of the lunar year"
        case .groundhogDay: return "2 February"
        case .valentines: return "14 February"
        case .stPatricks: return "17 March"
        case .ramadanEid: return "The month of Ramadan and three days of Eid al-Fitr"
        case .easter: return "Easter Sunday"
        case .earthDay: return "22 April"
        case .pride: return "All of June"
        case .independenceDay: return "4 July"
        case .halloween: return "31 October"
        case .diaDeMuertos: return "1 and 2 November"
        case .thanksgiving: return "The fourth Thursday of November"
        case .hanukkah: return "Eight nights, a candle more each night"
        case .christmas: return "24 and 25 December"
        case .kwanzaa: return "26 December to 1 January, a candle a day"
        case .birthday: return "The people you tag in your Birthdays calendar"
        }
    }

    /// Which wins when two fall on one day: lower first. A birthday,
    /// then a single day, then the short spans, then the long ones.
    var precedence: Int {
        switch self {
        case .birthday: return 0
        case .groundhogDay, .valentines, .stPatricks, .easter, .earthDay, .independenceDay,
             .halloween, .thanksgiving: return 1
        case .christmas, .newYear, .diaDeMuertos, .lunarNewYear: return 2
        case .kwanzaa, .hanukkah: return 3
        case .ramadanEid: return 4
        case .pride: return 5
        }
    }
}

/// One day's touch: which holiday, and where in it the day falls.
public struct SeasonalOccasion: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case ramadan, eid
    }

    public var holiday: SeasonalHoliday
    /// The day within a span, from 1: Hanukkah's night (the candles lit),
    /// Kwanzaa's day. 1 for a single day.
    public var day: Int
    /// Ramadan or Eid, for `ramadanEid`.
    public var phase: Phase?
    /// Whose birthday: the tagged person's name from the Birthdays
    /// calendar. nil only when the calendar gave no name.
    public var name: String?
    /// Whether the person's calendars named the day (rather than the
    /// built-in rule).
    public var fromCalendar: Bool

    public init(holiday: SeasonalHoliday, day: Int = 1, phase: Phase? = nil, name: String? = nil,
                fromCalendar: Bool = false) {
        self.holiday = holiday
        self.day = day
        self.phase = phase
        self.name = name
        self.fromCalendar = fromCalendar
    }

    /// The small words a surface may show: "Alex's birthday", "Happy
    /// birthday", "Night 3". nil when the art says it all.
    public var caption: String? {
        switch holiday {
        case .birthday:
            guard let name, let first = name.split(separator: " ").first else { return "Happy birthday" }
            return "\(first)'s birthday"
        case .hanukkah: return "Night \(day)"
        case .kwanzaa: return "Day \(day)"
        case .ramadanEid: return phase == .eid ? "Eid Mubarak" : nil
        default: return nil
        }
    }
}

/// Someone from the Birthdays calendar whose day the toys celebrate.
public struct SeasonalPerson: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The contact's identifier when the calendar names one, else the
    /// name itself.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The feature's settings: off by default; on, every holiday is on
/// until switched off. Tagged people stay on this Mac.
public struct SeasonalSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Holidays switched off, by raw value. Unknown names are kept, so a
    /// newer build's holiday survives a round trip through an older one.
    public var off: [String] = []
    /// The people whose birthdays the toys celebrate, besides yours.
    public var celebrated: [SeasonalPerson] = []

    public init(enabled: Bool = false, off: [String] = [], celebrated: [SeasonalPerson] = []) {
        self.enabled = enabled
        self.off = off
        self.celebrated = celebrated
    }

    public func isOn(_ holiday: SeasonalHoliday) -> Bool { !off.contains(holiday.rawValue) }

    public mutating func set(_ holiday: SeasonalHoliday, on: Bool) {
        off.removeAll { $0 == holiday.rawValue }
        if !on { off.append(holiday.rawValue) }
    }

    public func celebrates(_ id: String) -> Bool { celebrated.contains { $0.id == id } }

    private enum CodingKeys: String, CodingKey { case enabled, off, celebrated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        off = (try? c.decodeIfPresent([String].self, forKey: .off)) ?? []
        celebrated = (try? c.decodeIfPresent([SeasonalPerson].self, forKey: .celebrated)) ?? []
    }
}

/// One all-day event from a holiday calendar or Birthdays, as read.
public struct SeasonalCalendarEntry: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    /// From the Birthdays calendar.
    public var isBirthday: Bool
    /// The birthday's contact, when the calendar names one.
    public var contactID: String?

    public init(title: String, start: Date, end: Date, isBirthday: Bool = false, contactID: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isBirthday = isBirthday
        self.contactID = contactID
    }

    /// The birthday's person: the title without its "’s Birthday".
    public var personName: String {
        let suffixes = ["’s Birthday", "'s Birthday", "’ Birthday", "' Birthday", " Birthday"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// The person as the tag list keys them.
    public var person: SeasonalPerson {
        SeasonalPerson(id: contactID ?? personName, name: personName)
    }
}

/// JR-Bar's own date rules — used for any holiday the person's calendars
/// don't list, and for all of them when calendar access is off.
public enum SeasonalRules {
    /// Every built-in occasion that falls on `date`'s day. `region` is
    /// the person's region code ("US", "CA"…): Thanksgiving, Independence
    /// Day and Groundhog Day follow it.
    public static func occasions(on date: Date, calendar: Calendar = .current,
                                 region: String? = Locale.current.region?.identifier) -> [SeasonalOccasion] {
        var found: [SeasonalOccasion] = []
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
        let region = region?.uppercased() ?? "US"
        func add(_ holiday: SeasonalHoliday, day: Int = 1, phase: SeasonalOccasion.Phase? = nil) {
            found.append(SeasonalOccasion(holiday: holiday, day: day, phase: phase))
        }
        switch (month, day) {
        case (12, 31), (1, 1): add(.newYear)
        default: break
        }
        if month == 2, day == 2, ["US", "CA"].contains(region) { add(.groundhogDay) }
        if month == 2, day == 14 { add(.valentines) }
        if month == 3, day == 17 { add(.stPatricks) }
        if month == 4, day == 22 { add(.earthDay) }
        if month == 6 { add(.pride, day: day) }
        if month == 7, day == 4, region == "US" { add(.independenceDay) }
        if month == 10, day == 31 { add(.halloween) }
        if month == 11, day == 1 || day == 2 { add(.diaDeMuertos, day: day) }
        if month == 12, day == 24 || day == 25 { add(.christmas, day: day - 23) }
        if month == 12, day >= 26 { add(.kwanzaa, day: day - 25) }
        if month == 1, day == 1 { add(.kwanzaa, day: 7) }
        if let easter = easterSunday(year: year), easter.month == month, easter.day == day { add(.easter) }
        if isThanksgiving(year: year, month: month, day: day, region: region, calendar: calendar) {
            add(.thanksgiving)
        }
        if let night = hanukkahNight(on: date, calendar: calendar) { add(.hanukkah, day: night) }
        if let ramadan = ramadanEid(on: date, calendar: calendar) {
            add(.ramadanEid, day: ramadan.day, phase: ramadan.phase)
        }
        if let lunar = lunarNewYearDay(on: date, calendar: calendar) { add(.lunarNewYear, day: lunar) }
        return found
    }

    /// Easter Sunday in the Gregorian calendar (the anonymous computus).
    public static func easterSunday(year: Int) -> (month: Int, day: Int)? {
        guard year > 1582 else { return nil }
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return (month, day)
    }

    /// The US's fourth Thursday of November, or Canada's second Monday
    /// of October.
    static func isThanksgiving(year: Int, month: Int, day: Int, region: String,
                               calendar: Calendar) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        if region == "CA" {
            guard month == 10 else { return false }
            return nthWeekday(2, weekday: 2, month: 10, year: year, calendar: gregorian) == day
        }
        guard region == "US", month == 11 else { return false }
        return nthWeekday(4, weekday: 5, month: 11, year: year, calendar: gregorian) == day
    }

    /// The day of the month of the `n`th `weekday` (1 is Sunday).
    static func nthWeekday(_ n: Int, weekday: Int, month: Int, year: Int, calendar: Calendar) -> Int? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7
        return 1 + offset + (n - 1) * 7
    }

    /// Hanukkah's night on `date`, 1…8: the first candle is lit on the
    /// evening of 24 Kislev, so that day is night 1.
    public static func hanukkahNight(on date: Date, calendar: Calendar = .current) -> Int? {
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = calendar.timeZone
        let local = calendar.startOfDay(for: date)
        guard let year = hebrew.dateComponents([.year], from: local).year,
              let start = hebrew.date(from: DateComponents(year: year, month: 3, day: 24)) else { return nil }
        let days = daysBetween(hebrew.startOfDay(for: start), local, calendar: calendar)
        return (0..<8).contains(days) ? days + 1 : nil
    }

    /// Ramadan's day on `date`, or the day of Eid al-Fitr (1…3), from
    /// the Umm al-Qura calendar. Moon-sighting can move the real day by
    /// one; a calendar that lists it wins over this.
    public static func ramadanEid(on date: Date, calendar: Calendar = .current)
        -> (day: Int, phase: SeasonalOccasion.Phase)? {
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = calendar.timeZone
        let parts = islamic.dateComponents([.month, .day], from: calendar.startOfDay(for: date).addingTimeInterval(12 * 3600))
        guard let month = parts.month, let day = parts.day else { return nil }
        if month == 9 { return (day, .ramadan) }
        if month == 10, day <= 3 { return (day, .eid) }
        return nil
    }

    /// The day of the lunar new year on `date`, 1…3.
    public static func lunarNewYearDay(on date: Date, calendar: Calendar = .current) -> Int? {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = calendar.timeZone
        let parts = chinese.dateComponents([.month, .day, .isLeapMonth],
                                           from: calendar.startOfDay(for: date).addingTimeInterval(12 * 3600))
        guard parts.month == 1, parts.isLeapMonth != true, let day = parts.day, day <= 3 else { return nil }
        return day
    }

    static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: a)
        let end = calendar.startOfDay(for: b)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

/// Today's touch, from what the calendars said and the rules.
public enum SeasonalResolver {
    /// The holiday a calendar event's title names, if it is one of the
    /// sets. Case, accents and apostrophes don't matter.
    public static func holiday(named title: String) -> SeasonalHoliday? {
        let t = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("lunar new year", "chinese new year", "spring festival") { return .lunarNewYear }
        if has("rosh hashana", "islamic new year", "hijri") { return nil }
        if has("new year") { return .newYear }
        if has("groundhog") { return .groundhogDay }
        if has("valentine") { return .valentines }
        if has("patrick") { return .stPatricks }
        if has("eid al-adha", "eid al adha", "eid ul-adha") { return nil }
        if has("ramadan", "eid al-fitr", "eid al fitr", "eid ul-fitr", "eid-al-fitr", "eid ul fitr") { return .ramadanEid }
        if has("easter") { return .easter }
        if has("earth day") { return .earthDay }
        if has("pride") { return .pride }
        if has("independence day", "fourth of july", "4th of july") { return .independenceDay }
        if has("halloween") { return .halloween }
        if has("dia de los muertos", "dia de muertos", "day of the dead") { return .diaDeMuertos }
        if has("thanksgiving") { return .thanksgiving }
        if has("hanukkah", "chanukah", "hanukah", "chanukkah") { return .hanukkah }
        if has("christmas") { return .christmas }
        if has("kwanzaa") { return .kwanzaa }
        return nil
    }

    /// How long a span holiday runs from the first day a calendar lists,
    /// for calendars that name only its start.
    static func span(of holiday: SeasonalHoliday, title: String) -> Int {
        switch holiday {
        case .hanukkah: return 8
        case .kwanzaa: return 7
        case .lunarNewYear: return 3
        case .ramadanEid: return title.lowercased().contains("eid") ? 3 : 30
        default: return 1
        }
    }

    /// What `date` wears, or nil: the highest-precedence holiday that is
    /// switched on and falls today, by the calendars (`entries`, nil
    /// while access is off) or the rules. A birthday counts only for
    /// someone tagged in the Birthdays calendar's list, the person's own
    /// included: theirs is there when it's on their contact card.
    public static func occasion(on date: Date, settings: SeasonalSettings,
                                entries: [SeasonalCalendarEntry]?,
                                calendar: Calendar = .current,
                                region: String? = Locale.current.region?.identifier) -> SeasonalOccasion? {
        guard settings.enabled else { return nil }
        let candidates = all(on: date, settings: settings, entries: entries,
                             calendar: calendar, region: region)
        return candidates.first
    }

    /// Every occasion on `date` that is switched on, best first.
    public static func all(on date: Date, settings: SeasonalSettings,
                           entries: [SeasonalCalendarEntry]?,
                           calendar: Calendar = .current,
                           region: String? = Locale.current.region?.identifier) -> [SeasonalOccasion] {
        var found = SeasonalRules.occasions(on: date, calendar: calendar, region: region)
        let today = calendar.startOfDay(for: date)
        // Earliest first, so a span's day counts from the first day listed.
        let listedEntries = (entries ?? []).filter { !$0.isBirthday }.sorted { $0.start < $1.start }
        for entry in listedEntries {
            guard let holiday = holiday(named: entry.title) else { continue }
            let first = calendar.startOfDay(for: entry.start)
            let lastExclusive = max(calendar.startOfDay(for: entry.end), first.addingTimeInterval(1))
            let listed = SeasonalRules.daysBetween(first, today, calendar: calendar)
            let covers = today >= first && today < lastExclusive
            let length = span(of: holiday, title: entry.title)
            let spanDay = listed >= 0 && listed < length ? listed + 1 : nil
            guard covers || spanDay != nil else { continue }
            if let i = found.firstIndex(where: { $0.holiday == holiday }) {
                found[i].fromCalendar = true
                continue
            }
            var occasion = SeasonalOccasion(holiday: holiday, day: spanDay ?? 1, fromCalendar: true)
            if holiday == .ramadanEid {
                let title = entry.title.lowercased()
                occasion.phase = title.contains("eid") ? .eid : .ramadan
            }
            found.append(occasion)
        }
        for entry in entries ?? [] where entry.isBirthday {
            guard calendar.isDate(entry.start, inSameDayAs: date),
                  settings.celebrates(entry.person.id) else { continue }
            found.append(SeasonalOccasion(holiday: .birthday, name: entry.personName, fromCalendar: true))
        }
        return found
            .filter { settings.isOn($0.holiday) }
            .enumerated()
            .sorted { a, b in
                let pa = a.element.holiday.precedence
                let pb = b.element.holiday.precedence
                if pa != pb { return pa < pb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// The people in the Birthdays calendar, each once, soonest first,
    /// for the tag list.
    public static func birthdayPeople(_ entries: [SeasonalCalendarEntry]) -> [SeasonalPerson] {
        var seen = Set<String>()
        var people: [SeasonalPerson] = []
        for entry in entries.filter(\.isBirthday).sorted(by: { $0.start < $1.start }) {
            let person = entry.person
            guard !person.name.isEmpty, seen.insert(person.id).inserted else { continue }
            people.append(person)
        }
        return people
    }
}
