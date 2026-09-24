import AppKit
import EventKit
import JRBarCore

/// The shelf's reminders glance — Alcove's Reminders row: the next few
/// incomplete reminders with their due times and a check-off circle
/// that writes back to Reminders. Same privacy rule as the calendar
/// (T52): `hidden` on denial or with the switch off, the read happens
/// only after the person granted access, nothing syncs anywhere.
@MainActor
@Observable
final class ShelfRemindersModel {
    /// What the card renders. `hidden` covers the switch off and
    /// denied/restricted — pretending the list is empty when the system
    /// said no would lie. `needsPermission` draws nothing either.
    enum State: Equatable {
        case hidden
        case needsPermission
        case idle            // authorized, nothing due
        case items([Entry])
    }

    struct Entry: Equatable, Identifiable {
        /// `calendarItemIdentifier` — the re-resolve key for complete().
        let id: String
        let title: String
        /// The due date when the reminder carries one; nil sorts last.
        let due: Date?
    }

    private(set) var state: State = .needsPermission
    private var store: EKEventStore?
    private var refreshTimer: Timer?
    /// Bumps on `stop` — async hops (the permission answer, the fetch)
    /// can land after unpin, and landing must not restart the refresh
    /// timer the stop just killed.
    private var epoch = 0

    /// How many rows the card shows before the "+N more" tail.
    nonisolated static let rowLimit = 3

    func stop() {
        epoch += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Pin-side entry: the switch off hides the row; on, the glance
    /// reads where access was already granted and restarts the cadence
    /// `stop` killed on unpin. It never asks — the ask lives on the
    /// Notch settings' Reminders switch and Setup's permission row, so
    /// the card carries no "Show reminders" button on every open.
    func sync(enabled: Bool) {
        guard enabled else {
            stop()
            state = .hidden
            return
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            let store = self.store ?? EKEventStore()
            self.store = store
            load(from: store)
        case .denied, .restricted:
            state = .hidden
        default:
            state = .needsPermission
        }
    }

    /// Incomplete reminders due by the end of tomorrow — overdue ones
    /// count, since a missed reminder is exactly the row's job. Dueless
    /// reminders follow the dated ones.
    private func load(from store: EKEventStore) {
        let horizon = Calendar.current.date(
            byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: horizon, calendars: nil)
        let epoch = self.epoch
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == epoch else { return }
                let items = (reminders ?? [])
                    .map { Entry(id: $0.calendarItemIdentifier,
                                 title: $0.title?.isEmpty == false ? $0.title! : "Reminder",
                                 due: $0.dueDateComponents?.date) }
                    .sorted { lhs, rhs in
                        switch (lhs.due, rhs.due) {
                        case let (l?, r?): return l < r
                        case (nil, _?): return false
                        case (_?, nil): return true
                        case (nil, nil): return lhs.title < rhs.title
                        }
                    }
                self.state = items.isEmpty ? .idle : .items(items)
                self.scheduleRefresh()
            }
        }
    }

    /// Re-read on a slow cadence while the card is pinned — the list
    /// changes in Reminders.app too.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let store = self.store else { return }
                self.load(from: store)
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// The circle's action: mark complete in Reminders and reload.
    /// The identifier re-resolves — a reminder deleted mid-row never
    /// earns a save.
    func complete(_ entry: Entry) {
        guard let store else { return }
        guard let reminder = store.calendarItem(withIdentifier: entry.id) as? EKReminder
        else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            return
        }
        load(from: store)
    }

    // MARK: Quick add

    /// A typed line read as a reminder: the words, and the due date the
    /// line names — "Call Sam tomorrow at 3pm" is "Call Sam", due
    /// tomorrow at 15:00; "Pay rent Friday" is due Friday, no time.
    struct QuickAdd: Equatable {
        let title: String
        /// Day only, or day and time when the line named one.
        let due: DateComponents?
    }

    /// The line's reminder, or nil when nothing is left to title it.
    /// NSDataDetector finds the date; its words leave the title, with
    /// the connector before them ("at", "by", "on") and a leading
    /// "remind me to". A phrase with no time in it ("tomorrow",
    /// "Friday") stays a day — the detector's own noon would be a lie.
    nonisolated static func quickAdd(_ text: String, calendar: Calendar = .current) -> QuickAdd? {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var due: DateComponents?
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(title.startIndex..., in: title)
        if let match = detector?.firstMatch(in: title, range: range), let date = match.date,
           let found = Range(match.range, in: title) {
            let phrase = String(title[found])
            let fields: Set<Calendar.Component> = hasTime(phrase)
                ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            due = calendar.dateComponents(fields, from: date)
            title.removeSubrange(found)
        }
        title = cleanTitle(title)
        guard !title.isEmpty else { return nil }
        return QuickAdd(title: title, due: due)
    }

    /// A due date as the quick add's preview says it: "Today, 15:00",
    /// "Tomorrow", "Fri 26 Sep, 09:00".
    nonisolated static func whenText(_ date: Date, hasTime: Bool, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInTomorrow(date) {
            day = "Tomorrow"
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        guard hasTime else { return day }
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    nonisolated static func hasTime(_ phrase: String) -> Bool {
        let lower = phrase.lowercased()
        if lower.contains(where: \.isNumber) { return true }
        return ["noon", "midnight", "morning", "afternoon", "evening", "tonight", "hour", "minute"]
            .contains { lower.contains($0) }
    }

    private nonisolated static func cleanTitle(_ raw: String) -> String {
        var words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let connectors: Set<String> = ["at", "by", "on", "due"]
        while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
        var title = words.joined(separator: " ")
        for lead in ["remind me to ", "remind me "] where title.lowercased().hasPrefix(lead) {
            title = String(title.dropFirst(lead.count))
            break
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—"))
        guard let first = title.first else { return "" }
        return first.uppercased() + title.dropFirst()
    }

    /// Save a typed line into the default Reminders list, with an alert
    /// at its time when it named one, and reload. False when there is
    /// nothing to add, no access, or the save failed.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard let store, let parsed = Self.quickAdd(text),
              let list = store.defaultCalendarForNewReminders() else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = parsed.title
        reminder.calendar = list
        if let due = parsed.due {
            reminder.dueDateComponents = due
            if due.hour != nil, let when = Calendar.current.date(from: due) {
                reminder.addAlarm(EKAlarm(absoluteDate: when))
            }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return false
        }
        load(from: store)
        return true
    }

    // MARK: About a session

    /// When "Remind Me About This" comes back.
    enum Later: CaseIterable {
        case inAnHour, thisEvening, tomorrowMorning

        var title: String {
            switch self {
            case .inAnHour: return "In an Hour"
            case .thisEvening: return "This Evening"
            case .tomorrowMorning: return "Tomorrow Morning"
            }
        }
    }

    /// The due moment for `later`: an hour from now; 18:00 today (an
    /// hour from now once that has passed); 09:00 tomorrow.
    nonisolated static func due(_ later: Later, now: Date, calendar: Calendar = .current) -> DateComponents {
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        let hourOn = now.addingTimeInterval(3600)
        switch later {
        case .inAnHour:
            return calendar.dateComponents(fields, from: hourOn)
        case .thisEvening:
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? hourOn
            return calendar.dateComponents(fields, from: evening > now ? evening : hourOn)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? hourOn
            return calendar.dateComponents(fields, from: morning)
        }
    }

    /// The reminder a session leaves: its name to look at, and where it
    /// ran so the person can find it again.
    nonisolated static func sessionReminder(label: String, provider: String,
                                            cwd: String?) -> (title: String, notes: String) {
        let name = SessionLabel.providerName(provider)
        var notes = "\(name) session"
        if let cwd, !cwd.isEmpty {
            notes += " in \((cwd as NSString).abbreviatingWithTildeInPath)"
        }
        return ("Look at \(label)", notes + ". Left from JR-Bar's notch.")
    }

    /// The link a session's reminder carries back to it:
    /// `jrbar://session?id=<id>`, which raises the session's terminal or
    /// app. The id holds colons (`claude:session:<uuid>`), so it rides
    /// fully percent-encoded in the query, never as a path segment.
    nonisolated static func sessionLink(_ id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var components = URLComponents()
        components.scheme = AppCommand.scheme
        components.host = "session"
        components.percentEncodedQuery = "id=" + encoded
        return components.url
    }

    /// "Remind Me About This" on a session: a reminder in the default
    /// list, due and alerted at `later`, whose link opens the session
    /// again. False without access or when the save failed.
    @discardableResult
    func remind(about label: String, session id: String, provider: String, cwd: String?,
                later: Later, now: Date = Date()) -> Bool {
        guard let store, let list = store.defaultCalendarForNewReminders() else { return false }
        let made = Self.sessionReminder(label: label, provider: provider, cwd: cwd)
        let due = Self.due(later, now: now)
        let reminder = EKReminder(eventStore: store)
        reminder.title = made.title
        reminder.notes = made.notes
        reminder.url = Self.sessionLink(id)
        reminder.calendar = list
        reminder.dueDateComponents = due
        if let when = Calendar.current.date(from: due) { reminder.addAlarm(EKAlarm(absoluteDate: when)) }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return false
        }
        load(from: store)
        return true
    }

    /// Whether the glance can write now — access granted and read.
    var canWrite: Bool {
        switch state {
        case .idle, .items: return store != nil
        case .hidden, .needsPermission: return false
        }
    }

    /// The row's action without a check-off: open Reminders.app on the
    /// item — `x-apple-reminderkit://` names it by identifier.
    func openInReminders(_ entry: Entry) {
        guard let url = URL(string: "x-apple-reminderkit://reminders/\(entry.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
