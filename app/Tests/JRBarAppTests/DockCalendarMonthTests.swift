import AppKit
import EventKit
import JRBarCore
import JRBarTestSupport
import os
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Dock calendar month", .timeLimit(.minutes(2)))
struct DockCalendarMonthTests {
    static let locales = ["en_US", "en_GB", "de_DE", "ja_JP"]

    static func calendar(_ locale: String, zone: String = "America/New_York") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: locale)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                     calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func event(_ start: Date, _ end: Date, allDay: Bool = false,
                      color: ShelfCalendarModel.CalendarColor = .init(red: 0.2, green: 0.5, blue: 0.9)) -> ShelfCalendarModel.Event {
        ShelfCalendarModel.Event(title: "Synthetic event", start: start, end: end, url: nil,
                                 isAllDay: allDay, calendarColor: color, location: "Room 4")
    }

    @Test("locale weekdays, leap years and month boundaries", arguments: locales)
    func monthMath(locale: String) throws {
        let cal = Self.calendar(locale)
        #expect(cal.firstWeekday == (["en_US", "ja_JP"].contains(locale) ? 1 : 2))
        let symbols = DockCalendarMonth.weekdays(calendar: cal, locale: Locale(identifier: locale))
        #expect(symbols.count == 7)
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = Locale(identifier: locale)
        #expect(symbols.first == formatter.veryShortStandaloneWeekdaySymbols[cal.firstWeekday - 1])
        for year in [2023, 2024, 2100, 2000] {
            for month in 1...12 {
                let first = Self.date(year, month, 1, calendar: cal)
                let cells = DockCalendarMonth.days(in: first, calendar: cal)
                let days = cells.compactMap { $0 }
                let expected = try #require(cal.range(of: .day, in: .month, for: first))
                #expect(cells.count == 42)
                #expect(days.count == expected.count)
                #expect(days.first == first)
                let offset = try #require(cells.firstIndex { $0 != nil })
                #expect((offset + cal.firstWeekday - 1) % 7 + 1 == cal.component(.weekday, from: first))
                #expect(days.map { cal.component(.day, from: $0) } == Array(expected))
                let following = DockCalendarMonth.shifted(first, by: 1, calendar: cal)
                #expect(DockCalendarMonth.shifted(following, by: -1, calendar: cal) == first)
            }
        }
        #expect(DockCalendarMonth.days(in: Self.date(2024, 2, 1, calendar: cal), calendar: cal)
            .compactMap { $0 }.count == 29)
    }

    @Test("DST weeks use local day intervals and exclusive event ends", arguments: locales)
    func overlap(locale: String) {
        let cal = Self.calendar(locale)
        for month in [3, 11] {
            let day = Self.date(2024, month, month == 3 ? 10 : 3, calendar: cal)
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            #expect(next.timeIntervalSince(day) == Double(month == 3 ? 23 : 25) * 3600)
            let previous = cal.date(byAdding: .day, value: -1, to: day)!
            let after = cal.date(byAdding: .day, value: 2, to: day)!
            let spanning = Self.event(previous, after)
            let allDay = Self.event(day, next, allDay: true)
            let ended = Self.event(previous, day)
            let tomorrow = Self.event(next, after)
            let rows = DockCalendarMonth.events(on: day, in: [spanning, ended, tomorrow, allDay], calendar: cal)
            #expect(rows == [allDay, spanning])
            #expect(DockCalendarMonth.events(on: next, in: [allDay], calendar: cal).isEmpty)
            #expect(DockCalendarMonth.events(on: previous, in: [spanning], calendar: cal) == [spanning])
        }
    }

    @Test("dots preserve calendar colours, cap at three and mark overflow")
    func dots() {
        let cal = Self.calendar("en_US")
        let day = Self.date(2024, 2, 29, calendar: cal)
        let events = (0..<5).map { index in
            Self.event(day, day.addingTimeInterval(3600),
                       color: .init(red: Double(index) / 5, green: 0.5, blue: 0.8))
        }
        for count in 0...5 {
            let summary = DockCalendarMonth.dots(Array(events.prefix(count)))
            #expect(summary.colors == events.prefix(min(count, 3)).map(\.calendarColor))
            #expect(summary.overflow == (count > 3))
        }
    }

    @Test("month cache keys include timezone, expire, and share store invalidation")
    func cache() {
        let cal = Self.calendar("en_US")
        let now = Self.date(2024, 3, 12, calendar: cal)
        let start = Self.date(2024, 3, 1, calendar: cal)
        let end = Self.date(2024, 4, 1, calendar: cal)
        let reads = OSAllocatedUnfairLock(initialState: [DateInterval]())
        let access = OSAllocatedUnfairLock(initialState: true)
        let inside = Self.event(now, now.addingTimeInterval(3600))
        let spanning = Self.event(start.addingTimeInterval(-3600), end.addingTimeInterval(3600), allDay: true)
        let outside = Self.event(end, end.addingTimeInterval(3600))
        let reader = ShelfCalendarReader(fetchMonth: { range in
            reads.withLock { $0.append(range) }
            return [inside, spanning, outside]
        }, authorization: { access.withLock { $0 } ? .fullAccess : .denied })
        #expect(reader.events(inMonth: now, calendar: cal, now: now) == [inside, spanning])
        _ = reader.events(inMonth: start, calendar: cal, now: now.addingTimeInterval(59))
        #expect(reads.withLock { $0 } == [DateInterval(start: start, end: end)])
        _ = reader.events(inMonth: now, calendar: cal, now: now.addingTimeInterval(60))
        #expect(reads.withLock { $0.count } == 2)
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        _ = reader.events(inMonth: now, calendar: cal, now: now.addingTimeInterval(61))
        #expect(reads.withLock { $0.count } == 3)
        let utc = Self.calendar("en_US", zone: "UTC")
        _ = reader.events(inMonth: now, calendar: utc, now: now.addingTimeInterval(62))
        #expect(reads.withLock { $0.count } == 4)
        _ = reader.events(inMonth: end, calendar: cal, now: now.addingTimeInterval(63))
        #expect(reads.withLock { $0.count } == 5)
        access.withLock { $0 = false }
        #expect(reader.events(inMonth: now, calendar: cal, now: now).isEmpty)
        #expect(reads.withLock { $0.count } == 5)
        access.withLock { $0 = true }
        _ = reader.events(inMonth: now, calendar: cal, now: now)
        #expect(reads.withLock { $0.count } == 6)
    }

    @Test("a store change during a month read prevents caching it")
    func changeDuringRead() async {
        let gate = TestGate()
        defer { gate.signal() }
        let entered = TestSignal()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let cal = Self.calendar("en_US")
        let now = Self.date(2024, 3, 12, calendar: cal)
        let reader = ShelfCalendarReader(fetchMonth: { _ in
            let count = reads.withLock { $0 += 1; return $0 }
            if count == 1 { entered.signal(); gate.wait() }
            return []
        })
        let query = Task.detached { reader.events(inMonth: now, calendar: cal, now: now) }
        #expect(await entered.wait())
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        gate.signal()
        _ = await query.value
        _ = reader.events(inMonth: now, calendar: cal, now: now)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test("List is the old-state default and Month persists through the settings facade")
    @MainActor func persistence() throws {
        for json in ["{}", #"{"calendarView":"unknown"}"#, #"{"calendarView":null}"#] {
            let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8))
            #expect(decoded.calendarView == .list)
        }
        var settings = DockEnhanceSettings()
        let preferences = DockEnhancePreferences()
        preferences.read = { settings }
        preferences.write = { settings = $0 }
        preferences.calendarView = .month
        let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.calendarView == .month)
        #expect(decoded.calendarPreview && decoded.mediaPreview)
        #expect(preferences.calendarView == .month)
    }

    @MainActor private func settle(_ preview: DockCalendarPreview) async {
        await withCheckedContinuation { continuation in
            preview.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @Test("month queries use the shared store range API")
    func sharedStoreRange() {
        let store = SyntheticShelfEventStore()
        let reader = ShelfCalendarReader(authorization: { .fullAccess }, store: store)
        let cal = Self.calendar("en_US")
        let now = Self.date(2024, 3, 12, calendar: cal)
        _ = reader.events(inMonth: now, calendar: cal, now: now)
        _ = reader.events(from: now)
        #expect(store.calls.withLock { $0.months } == [cal.dateInterval(of: .month, for: now)!])
        #expect(store.calls.withLock { $0.events } == 1)
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        _ = reader.events(inMonth: now, calendar: cal, now: now)
        _ = reader.events(from: now)
        #expect(store.calls.withLock { $0.months.count } == 2)
        #expect(store.calls.withLock { $0.events } == 2)
    }

    @Test("only a visible month reads, navigation refreshes, and hiding unsubscribes")
    @MainActor func lifecycle() async {
        let monthReads = OSAllocatedUnfairLock(initialState: [DateInterval]())
        let listReads = OSAllocatedUnfairLock(initialState: 0)
        let reader = ShelfCalendarReader(fetch: { _ in listReads.withLock { $0 += 1 }; return [] },
            fetchMonth: { range in monthReads.withLock { $0.append(range) }; return [] })
        let preview = DockCalendarPreview(reader: reader)
        let cal = Self.calendar("en_GB")
        let now = Self.date(2024, 2, 14, calendar: cal)
        preview.calendar = cal
        preview.clock = { now }
        preview.authorization = { .fullAccess }
        let readers = DockNativePreviews(calendar: preview)
        let content = DockPreviewContent()
        content.bundleID = DockEnhanceMath.calendarBundleID
        var settings = DockEnhanceSettings(calendarView: .month, mediaPreview: false)
        readers.seed(content: content, settings: settings)
        #expect(content.calendarSelectedDay == now)
        #expect(monthReads.withLock { $0.isEmpty })
        readers.start(content: content, settings: settings)
        defer { readers.stop() }
        await settle(preview)
        #expect(monthReads.withLock { $0.count } == 1)
        #expect(listReads.withLock { $0 } == 0)
        let next = DockCalendarMonth.shifted(now, by: 1, calendar: cal)
        readers.showMonth(next)
        await settle(preview)
        #expect(content.calendarSelectedDay == next)
        #expect(monthReads.withLock { $0.count } == 2)
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        await settle(preview)
        #expect(monthReads.withLock { $0.count } == 3)
        settings.calendarView = .list
        readers.update(settings: settings)
        await settle(preview)
        #expect(content.calendarView == .list)
        #expect(listReads.withLock { $0 } == 1)
        readers.stop()
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        readers.showMonth(now)
        preview.refresh()
        await settle(preview)
        #expect(monthReads.withLock { $0.count } == 3)
        #expect(listReads.withLock { $0 } == 1)
    }

    @Test("navigating while a query is in flight drops the old month")
    @MainActor func navigationDuringRead() async {
        let cal = Self.calendar("en_US")
        let february = Self.date(2024, 2, 1, calendar: cal)
        let march = Self.date(2024, 3, 1, calendar: cal)
        let old = Self.event(february, february.addingTimeInterval(3600))
        let current = Self.event(march, march.addingTimeInterval(3600))
        let entered = TestSignal()
        let gate = TestGate()
        defer { gate.signal() }
        let reader = ShelfCalendarReader(fetchMonth: { range in
            if range.start == february { entered.signal(); gate.wait(); return [old] }
            return [current]
        })
        let preview = DockCalendarPreview(reader: reader)
        preview.authorization = { .fullAccess }
        preview.calendar = cal
        preview.clock = { february }
        preview.show(month: february)
        var deliveries: [DockCalendarPreview.State] = []
        preview.onChange = { deliveries.append($0) }
        preview.start()
        defer { preview.stop() }
        #expect(await entered.wait())
        preview.show(month: march)
        gate.signal()
        await settle(preview)
        #expect(deliveries.last == .events([current]))
        #expect(!deliveries.contains(.events([old])))
    }

    @Test("Month hugs six grid rows, with no event-list or empty-state reservation")
    @MainActor func layout() {
        let cal = Self.calendar("en_GB")
        let now = Self.date(2024, 2, 14, calendar: cal)
        let actions = DockPreviewActions(content: DockPreviewContent())
        for size in DockPreviewSize.allCases {
            var heights: [CGFloat] = []
            for month in [now, Self.date(2020, 8, 15, calendar: cal)] {
                for count in [0, 1, 20] {
                    let events = (0..<count).map { _ in Self.event(month, month.addingTimeInterval(3600)) }
                    let card = DockCalendarCard(state: .events(events), now: now, calendar: cal,
                        actions: actions, view: .month, month: month, selectedDay: .constant(month))
                        .environment(\.dockPreviewSize, size)
                    let host = NSHostingView(rootView: card)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width == size.widgetSize.width)
                    #expect(host.fittingSize.height < size.monthHeightLimit)
                    heights.append(host.fittingSize.height)
                }
            }
            let loading = DockCalendarCard(state: .loading, now: now, calendar: cal,
                actions: actions, view: .month, month: now).environment(\.dockPreviewSize, size)
            let loadingHost = NSHostingView(rootView: loading)
            loadingHost.layoutSubtreeIfNeeded()
            heights.append(loadingHost.fittingSize.height)
            #expect(Set(heights).count == 1)
            let empty = DockCalendarCard(state: .events([]), now: now, calendar: cal, actions: actions)
                .environment(\.dockPreviewSize, size)
            let host = NSHostingView(rootView: empty)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height < size.widgetSize.height)
        }
    }

    @Test("day clicks select the date's List; double clicks only open Calendar")
    @MainActor func dayClicks() async {
        var settings = DockEnhanceSettings(calendarView: .month)
        let preferences = DockEnhancePreferences()
        preferences.read = { settings }
        preferences.write = { settings = $0 }
        let controller = DockEnhanceController(preferences: preferences)
        let day = Self.date(2024, 2, 2, calendar: Self.calendar("en_GB"))
        controller.preview.calendarState = .events([])
        let panel = controller.ensurePanel()
        defer { panel.close() }
        var opened: [Date] = []
        controller.openCalendarDate = { opened.append($0) }
        panel.actions.calendarDay(day, clickCount: 1)
        #expect(controller.preview.calendarView == .list)
        #expect(controller.preview.calendarListDay == day)
        #expect(settings.calendarView == .list)
        #expect(opened.isEmpty)
        panel.actions.onCalendarView?(.month)
        #expect(controller.preview.calendarListDay == nil)
        #expect(settings.calendarView == .month)
        await controller.showCalendarDate(day)
        #expect(opened == [day])
        #expect(settings.calendarView == .month)
        let actions = DockPreviewActions(content: DockPreviewContent())
        var singles = 0
        var doubles = 0
        actions.onCalendarDay = { _ in singles += 1 }
        actions.onCalendarDateOpen = { _ in doubles += 1 }
        actions.calendarDay(day, clickCount: 2)
        #expect(singles == 0 && doubles == 1)
    }

    @Test("selected-day List keeps the month read, including dates before today")
    @MainActor func selectedDayReader() async {
        let cal = Self.calendar("en_GB")
        let now = Self.date(2024, 2, 14, calendar: cal)
        let past = Self.date(2024, 2, 2, calendar: cal)
        let selectedEvent = Self.event(past, past.addingTimeInterval(3600))
        let listReads = OSAllocatedUnfairLock(initialState: 0)
        let reader = ShelfCalendarReader(fetch: { _ in listReads.withLock { $0 += 1 }; return [] },
                                        fetchMonth: { _ in [selectedEvent] })
        let calendarPreview = DockCalendarPreview(reader: reader)
        calendarPreview.authorization = { .fullAccess }
        calendarPreview.calendar = cal
        calendarPreview.clock = { now }
        let readers = DockNativePreviews(calendar: calendarPreview)
        let content = DockPreviewContent()
        content.bundleID = DockEnhanceMath.calendarBundleID
        content.calendarMonth = past
        content.calendarListDay = past
        readers.start(content: content, settings: DockEnhanceSettings(mediaPreview: false))
        defer { readers.stop() }
        await settle(calendarPreview)
        #expect(listReads.withLock { $0 } == 0)
        #expect(calendarPreview.month == past)
        #expect(content.calendarState == .events([selectedEvent]))
    }

    @Test("Calendar date navigation sends the documented date event to the chosen PID")
    func dateEvent() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var delivered = 0
        try DockCalendarDateOpener.send(day, pid: 4242) { packet in
            delivered += 1
            #expect(packet.eventClass == 0x77726274)
            #expect(packet.eventID == 0x61656339)
            #expect(packet.paramDescriptor(forKeyword: 0x77746474)?.dateValue == day)
            return .null()
        }
        #expect(delivered == 1)
    }

    @Test("macOS event links encode item identifiers and recurring occurrences")
    func eventLinks() {
        let cal = Self.calendar("en_US")
        let day = Self.date(2024, 2, 14, 9, calendar: cal)
        var sample = Self.event(day, day.addingTimeInterval(3600))
        #expect(sample.calendarURL()?.absoluteString == "ical://")
        sample.calendarItemIdentifier = "synthetic-event"
        #expect(sample.calendarURL()?.absoluteString == "ical://ekevent/synthetic-event?method=show&options=more")
        sample.calendarOccurrence = day
        #expect(sample.calendarURL()?.path == "/20240214T140000Z/synthetic-event")
        sample.isAllDay = true
        let midnight = Self.date(2024, 2, 14, calendar: cal)
        sample.calendarOccurrence = midnight
        #expect(sample.calendarURL(timeZone: cal.timeZone)?.path == "/20240214T000000Z/synthetic-event")
        sample.calendarItemIdentifier = "synthetic/id?value#fragment"
        let encoded = sample.calendarURL(timeZone: cal.timeZone)?.absoluteString ?? ""
        #expect(encoded.contains("synthetic%2Fid%3Fvalue%23fragment"))
        sample.calendarItemIdentifier = ""
        #expect(sample.calendarURL()?.absoluteString == "ical://")
    }

    @Test("event clocks follow locale and ended events never say Now")
    @MainActor func clocks() {
        let cal = Self.calendar("en_US", zone: "UTC")
        let day = Self.date(2024, 3, 12, 14, calendar: cal)
        let sample = Self.event(day, day.addingTimeInterval(3600))
        let before = day.addingTimeInterval(-60)
        let us = DockCalendarCard.timeLine(sample, now: before, calendar: cal, locale: Locale(identifier: "en_US"))
        let gb = DockCalendarCard.timeLine(sample, now: before, calendar: cal, locale: Locale(identifier: "en_GB"))
        #expect(us.contains("PM"))
        #expect(gb.contains("14:00"))
        #expect(!DockCalendarCard.timeLine(sample, now: day.addingTimeInterval(7200), calendar: cal).contains("Now"))
    }
}
