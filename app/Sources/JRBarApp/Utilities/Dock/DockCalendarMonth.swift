import Foundation

/// Calendar arithmetic uses day boundaries, including days shorter or longer than 24 hours.
enum DockCalendarMonth {
    static func days(in month: Date, calendar: Calendar) -> [Date?] {
        guard let range = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: range.start)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        var result = Array<Date?>(repeating: nil, count: offset)
        for index in 0..<count.count {
            result.append(calendar.date(byAdding: .day, value: index, to: range.start))
        }
        result += Array<Date?>(repeating: nil, count: 42 - result.count)
        return result
    }

    static func weekdays(calendar: Calendar, locale: Locale) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        let symbols = formatter.veryShortStandaloneWeekdaySymbols!
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    static func events(on day: Date, in events: [ShelfCalendarModel.Event],
                       calendar: Calendar) -> [ShelfCalendarModel.Event] {
        guard let range = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events.filter { $0.start < range.end && $0.end > range.start }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.start < $1.start
            }
    }

    struct Dots {
        let colors: [ShelfCalendarModel.CalendarColor]
        let overflow: Bool
    }

    static func dots(_ events: [ShelfCalendarModel.Event]) -> Dots {
        Dots(colors: events.prefix(3).map(\.calendarColor), overflow: events.count > 3)
    }

    static func shifted(_ month: Date, by offset: Int, calendar: Calendar) -> Date {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }
}
