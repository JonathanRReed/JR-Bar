import JRBarCore
import JRBarUI
import SwiftUI

struct DockCalendarCard: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let state: DockCalendarPreview.State
    let now: Date
    var calendar: Calendar = .current
    let actions: DockPreviewActions
    var isCalendarApp = true

    var view: DockCalendarView = .list
    var month: Date = Date()
    var listDay: Date?
    var selectedDay: Binding<Date> = .constant(Date())
    var locale: Locale = .current

    var body: some View {
        DockWidget(title: "Calendar", symbol: "calendar", open: actions.onCalendarOpen, heightLimit: view == .month ? previewSize.monthHeightLimit : nil) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                if isCalendarApp {
                    Picker("Calendar view", selection: Binding(
                        get: { view }, set: { actions.onCalendarView?($0) }
                    )) {
                        ForEach(DockCalendarView.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented).controlSize(.small).labelsHidden()
                }
                calendarContent.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private var calendarContent: some View {
        switch state {
        case .loading:
            if view == .month && isCalendarApp { monthGrid([]) }
            else { Text("Loading events…").foregroundStyle(.secondary) }
        case .noAccess:
            HStack(spacing: previewSize.spacing) {
                Text("Calendar access is off").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Allow Access") { actions.onCalendarAuth?() }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true))
            }
        case .events(let events):
            if view == .month && isCalendarApp {
                monthGrid(events)
            } else if let listDay, isCalendarApp {
                dayList(events, day: listDay)
            } else if previewSize == .small {
                smallEvent(events)
            } else {
                DockContentList(maximumHeight: previewSize.widgetContentHeight - 28) { listEvents(events) }
            }
        }
    }

    private func dayList(_ events: [ShelfCalendarModel.Event], day: Date) -> some View {
        let rows = DockCalendarMonth.events(on: day, in: events, calendar: calendar)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            HStack {
                Text(day.formatted(style)).jrbarType(.caption)
                Spacer(minLength: 0)
                Button("Month") { actions.onCalendarView?(.month) }.buttonStyle(DockCapsuleButtonStyle())
            }
            if rows.isEmpty { Text("No events").foregroundStyle(.secondary) }
            else {
                DockContentList(maximumHeight: previewSize.widgetContentHeight - 60) {
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, event in eventRow(event) }
                    }
                }
                .id(day)
            }
        }
    }

    private func smallEvent(_ events: [ShelfCalendarModel.Event]) -> some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Text(now.formatted(.dateTime.weekday(.wide).day())).jrbarType(.title3)
            if let event = Self.upcoming(events, now: now).first {
                Text(event.title).jrbarType(.headline).lineLimit(3)
                Text(Self.timeLine(event, now: now, calendar: calendar, locale: locale))
                    .jrbarType(.caption).foregroundStyle(.secondary)
            } else {
                Text("No upcoming events").foregroundStyle(.secondary)
            }
        }
    }

    private func listEvents(_ events: [ShelfCalendarModel.Event]) -> some View {
        let rows = Array(Self.upcoming(events, now: now).prefix(previewSize == .medium ? 3 : 6))
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            if rows.isEmpty {
                Text("No upcoming events").foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, event in
                    let today = Self.isToday(event, now: now, calendar: calendar)
                    let previousToday = index > 0 && Self.isToday(rows[index - 1], now: now, calendar: calendar)
                    if previewSize == .large && (index == 0 || today != previousToday) {
                        Text(today ? "Today" : "Upcoming")
                            .jrbarType(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    eventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthGrid(_ events: [ShelfCalendarModel.Event]) -> some View {
        let days = DockCalendarMonth.days(in: month, calendar: calendar)
        let symbols = DockCalendarMonth.weekdays(calendar: calendar, locale: locale)
        let monthStyle = Date.FormatStyle(locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone).month(.wide).year()
        return VStack(alignment: .leading, spacing: previewSize.rowSpacing) {
            HStack {
                monthButton("Previous month", symbol: "chevron.left", offset: -1)
                Spacer(minLength: 0)
                Text(month.formatted(monthStyle)).fontWeight(.semibold)
                if state == .loading {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        .accessibilityLabel("Reading calendar events")
                }
                Spacer(minLength: 0)
                monthButton("Next month", symbol: "chevron.right", offset: 1)
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[index]).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: previewSize.rowSpacing), count: 7), spacing: previewSize.rowSpacing) {
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] {
                        dayCell(day, events: events)
                    } else {
                        Color.clear.frame(height: previewSize.calendarDayHeight).accessibilityHidden(true)
                    }
                }
            }

        }
    }

    private func monthButton(_ title: String, symbol: String, offset: Int) -> some View {
        Button {
            actions.onCalendarMonth?(DockCalendarMonth.shifted(month, by: offset, calendar: calendar))
        } label: {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func dayCell(_ day: Date, events: [ShelfCalendarModel.Event]) -> some View {
        let rows = DockCalendarMonth.events(on: day, in: events, calendar: calendar)
        let dots = DockCalendarMonth.dots(rows)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay.wrappedValue)
        let today = calendar.isDate(day, inSameDayAs: now)
        let dayStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day()
        return Button { choose(day, clicks: 1) } label: {
            VStack(spacing: 2) {
                Text(day.formatted(dayStyle))
                    .fontWeight(today || selected ? .bold : .regular)
                    .foregroundStyle(today ? Color.accentColor : Color.primary)
                HStack(spacing: 2) {
                    ForEach(dots.colors.indices, id: \.self) { index in
                        let tint = dots.colors[index]
                        Circle().fill(Color(red: tint.red, green: tint.green, blue: tint.blue))
                            .frame(width: 4, height: 4)
                    }
                    if dots.overflow { Text("+").jrbarType(.caption).fontWeight(.bold) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity).frame(height: previewSize.calendarDayHeight)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
            .overlay {
                if today {
                    RoundedRectangle(cornerRadius: JRBarTokens.Radius.control).strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { click in
            switch click {
            case .first: choose(day, clicks: 2)
            case .second: choose(day, clicks: 1)
            }
        })
        .accessibilityAction(named: "Open in Calendar") { choose(day, clicks: 2) }
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(today ? "Today, " : "")\(rows.count) events")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ day: Date, clicks: Int) {
        if clicks == 1 { selectedDay.wrappedValue = day }
        actions.calendarDay(day, clickCount: clicks)
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
        if event.start <= now && event.end > now { return "Now until \(end)" }
        let start = UsageTime.clock(event.start.timeIntervalSince1970, locale: locale, timeZone: calendar.timeZone)
        let hours = "\(start) to \(end)"
        guard !calendar.isDate(event.start, inSameDayAs: now) else { return hours }
        return "\(day) · \(hours)"
    }

    private func eventRow(_ event: ShelfCalendarModel.Event) -> some View {
        HStack(spacing: previewSize.spacing) {
            let tint = event.calendarColor
            Capsule()
                .fill(Color(red: tint.red, green: tint.green, blue: tint.blue))
                .frame(width: 3)
            Button { actions.onCalendarEvent?(event) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .jrbarType(previewSize.bodyType).fontWeight(.medium)
                        .lineLimit(previewSize == .medium ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.timeLine(event, now: now, calendar: calendar, locale: locale))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if previewSize == .large, let location = event.shortLocation {
                        Text(location).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if let url = event.url {
                Button("Join") { actions.onCalendarJoin?(url) }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: event.start <= now))
            }
        }
        .frame(minHeight: previewSize.detailRowHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
