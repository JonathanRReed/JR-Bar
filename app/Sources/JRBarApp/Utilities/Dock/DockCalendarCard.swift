import JRBarCore
import SwiftUI

struct DockCalendarCard: View {
    let state: DockCalendarPreview.State
    let now: Date
    var calendar: Calendar = .current
    let actions: DockPreviewActions
    var isCalendarApp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .loading:
                Text("Loading events…").foregroundStyle(.secondary)
            case .noAccess:
                HStack(spacing: 12) {
                    Text("Calendar access is off").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Allow Access") { actions.onCalendarAuth?() }
                        .buttonStyle(DockCapsuleButtonStyle(prominent: true))
                }
            case .events(let events):
                let rows = Self.upcoming(events, now: now)
                if rows.isEmpty {
                    Text("No upcoming events").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, event in
                        let today = Self.isToday(event, now: now, calendar: calendar)
                        let previousToday = index > 0 && Self.isToday(rows[index - 1], now: now, calendar: calendar)
                        if index == 0 || today != previousToday {
                            Text(today ? "Today" : "Upcoming")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        eventRow(event)
                    }
                }
            }
            if isCalendarApp {
                Button("Open Calendar") { actions.onCalendarOpen?() }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: false))
            }
        }
        .font(.system(size: 12))
        .frame(width: 320, alignment: .leading)
    }

    static func upcoming(_ events: [ShelfCalendarModel.Event], now: Date) -> [ShelfCalendarModel.Event] {
        ShelfCalendarModel.upcoming(events, now: now, limit: 6)
    }

    static func isToday(_ event: ShelfCalendarModel.Event, now: Date, calendar: Calendar) -> Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return event.start < tomorrow && event.end > calendar.startOfDay(for: now)
    }

    static func timeLine(_ event: ShelfCalendarModel.Event, now: Date,
                         calendar: Calendar = .current, locale: Locale = .current) -> String {
        let dayStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale,
                                        calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        let day = event.start.formatted(dayStyle)
        if event.isAllDay {
            return isToday(event, now: now, calendar: calendar) ? "All day" :
                "\(day) · All day"
        }
        let endClock = UsageTime.clock(event.end.timeIntervalSince1970, locale: locale, timeZone: calendar.timeZone)
        let referenceDay = event.start <= now ? now : event.start
        let end = calendar.isDate(event.end, inSameDayAs: referenceDay)
            ? endClock : "\(event.end.formatted(dayStyle)) \(endClock)"
        if event.start <= now { return "Now until \(end)" }
        let start = UsageTime.clock(event.start.timeIntervalSince1970, locale: locale, timeZone: calendar.timeZone)
        let hours = "\(start) to \(end)"
        guard !calendar.isDate(event.start, inSameDayAs: now) else { return hours }
        return "\(day) · \(hours)"
    }

    private func eventRow(_ event: ShelfCalendarModel.Event) -> some View {
        HStack(spacing: 9) {
            let tint = event.calendarColor
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: tint.red, green: tint.green, blue: tint.blue))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.timeLine(event, now: now, calendar: calendar))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let location = event.shortLocation {
                    Text(location).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = event.url {
                Button("Join") { actions.onCalendarJoin?(url) }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: event.start <= now))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
