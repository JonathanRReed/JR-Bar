import Foundation
@preconcurrency import EventKit
import JRBarCore

/// Value-only access lets tests exercise every consumer without opening EventKit.
protocol ShelfEventStore: AnyObject, Sendable {
    func events(from now: Date) -> [ShelfCalendarModel.Event]
    func events(in range: DateInterval) -> [ShelfCalendarModel.Event]
    func seasonal(now: Date, birthdays: Bool) -> SeasonalReading
    func requestAccess(to entity: EKEntityType, completion: @escaping @Sendable (Bool) -> Void)
    @MainActor func fetchReminders(_ completion: @escaping @MainActor @Sendable ([ShelfRemindersModel.Entry]?) -> Void)
    func completeReminder(id: String) throws -> Bool
    func addReminder(_ draft: ShelfReminderDraft) throws -> Bool
}

struct ShelfReminderDraft {
    let title: String
    var due: DateComponents?
    var notes: String?
    var url: URL?
}

/// The app's only native store. Its lazy instance survives cards, permission prompts,
/// and outstanding fetches. A lock serializes synchronous access.
final class SystemShelfEventStore: ShelfEventStore, @unchecked Sendable {
    static let shared = SystemShelfEventStore()
    private let lock = NSLock()
    private var store: EKEventStore?

    private init() {}

    private func withStore<T>(_ body: (EKEventStore) throws -> T) rethrows -> T {
        try lock.withLock {
            let current = store ?? EKEventStore()
            store = current
            return try body(current)
        }
    }

    func events(from now: Date) -> [ShelfCalendarModel.Event] {
        withStore { store in
            let start = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-12 * 3600))
            let predicate = store.predicateForEvents(
                withStart: start, end: now.addingTimeInterval(ShelfCalendarReader.lookahead), calendars: nil)
            return store.events(matching: predicate).map(ShelfCalendarModel.project)
        }
    }

    func events(in range: DateInterval) -> [ShelfCalendarModel.Event] {
        withStore { store in
            let predicate = store.predicateForEvents(
                withStart: range.start, end: range.end, calendars: nil)
            return store.events(matching: predicate).map(ShelfCalendarModel.project)
        }
    }

    func seasonal(now: Date, birthdays: Bool) -> SeasonalReading {
        withStore { store in
            let today = Calendar.current.startOfDay(for: now)
            let calendars = store.calendars(for: .event)
            let holidays = calendars.filter {
                $0.type != .birthday && $0.title.localizedCaseInsensitiveContains("holiday")
            }
            let birthdayCalendars = calendars.filter { $0.type == .birthday }
            var entries: [SeasonalCalendarEntry] = []
            if !holidays.isEmpty {
                let predicate = store.predicateForEvents(
                    withStart: today.addingTimeInterval(-SeasonalSource.lookBack),
                    end: today.addingTimeInterval(2 * 86_400), calendars: holidays)
                entries += store.events(matching: predicate).map {
                    SeasonalCalendarEntry(title: $0.title ?? "", start: $0.startDate, end: $0.endDate)
                }
            }
            if birthdays, !birthdayCalendars.isEmpty {
                let predicate = store.predicateForEvents(
                    withStart: today, end: today.addingTimeInterval(366 * 86_400), calendars: birthdayCalendars)
                entries += store.events(matching: predicate).map {
                    SeasonalCalendarEntry(title: $0.title ?? "", start: $0.startDate, end: $0.endDate,
                                          isBirthday: true, contactID: $0.birthdayContactIdentifier)
                }
            }
            return SeasonalReading(entries: entries, holidayCalendars: holidays.count)
        }
    }

    func requestAccess(to entity: EKEntityType, completion: @escaping @Sendable (Bool) -> Void) {
        withStore { store in
            if entity == .reminder {
                store.requestFullAccessToReminders { granted, _ in completion(granted) }
            } else {
                store.requestFullAccessToEvents { granted, _ in completion(granted) }
            }
        }
    }

    func fetchReminders(_ completion: @escaping @MainActor @Sendable ([ShelfRemindersModel.Entry]?) -> Void) {
        withStore { store in
            let horizon = Calendar.current.date(
                byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: horizon, calendars: nil)
            // Never cancel. The coordinator keeps this store alive until the reply finishes.
            // Project without the lock: EventKit's own queue delivers the reminders, and
            // waiting there on a lock another thread holds inside EventKit could hang both.
            let callback = ShelfReminderReader.callback(project: { (reminder: EKReminder) in
                ShelfReminderReader.entry(id: reminder.calendarItemIdentifier, title: reminder.title,
                                          due: reminder.dueDateComponents?.date)
            }, completion: completion)
            _ = store.fetchReminders(matching: predicate, completion: callback)
        }
    }

    func completeReminder(id: String) throws -> Bool {
        try withStore { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            return true
        }
    }

    func addReminder(_ draft: ShelfReminderDraft) throws -> Bool {
        try withStore { store in
            guard let list = store.defaultCalendarForNewReminders() else { return false }
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = list
            reminder.notes = draft.notes
            reminder.url = draft.url
            if let due = draft.due {
                reminder.dueDateComponents = due
                if due.hour != nil, let when = Calendar.current.date(from: due) {
                    reminder.addAlarm(EKAlarm(absoluteDate: when))
                }
            }
            try store.save(reminder, commit: true)
            return true
        }
    }
}
