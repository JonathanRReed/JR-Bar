import AppKit
import EventKit

/// The shelf's reminders glance — Alcove's Reminders row: the next few
/// incomplete reminders with their due times and a check-off circle
/// that writes back to Reminders. Same privacy rule as the calendar
/// (T52): `hidden` on denial, the read happens only after the person
/// asks, nothing syncs anywhere.
@MainActor
@Observable
final class ShelfRemindersModel {
    /// What the card renders. `hidden` covers denied/restricted —
    /// pretending the list is empty when the system said no would lie.
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

    /// How many rows the card shows before the "+N more" tail.
    nonisolated static let rowLimit = 3

    /// The explicit opt-in — called from the card's reminders button,
    /// never at launch or on a timer.
    func authorizeAndLoad() {
        let store = self.store ?? EKEventStore()
        self.store = store
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            load(from: store)
        case .denied, .restricted:
            state = .hidden
        case .notDetermined, .writeOnly:
            store.requestFullAccessToReminders { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self, let store = self.store else { return }
                    if granted {
                        self.load(from: store)
                    } else {
                        self.state = .hidden
                    }
                }
            }
        @unknown default:
            state = .hidden
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Incomplete reminders due by the end of tomorrow — overdue ones
    /// count, since a missed reminder is exactly the row's job. Dueless
    /// reminders follow the dated ones.
    private func load(from store: EKEventStore) {
        let horizon = Calendar.current.date(
            byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: horizon, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    /// The row's action without a check-off: open Reminders.app on the
    /// item — `x-apple-reminderkit://` names it by identifier.
    func openInReminders(_ entry: Entry) {
        guard let url = URL(string: "x-apple-reminderkit://reminders/\(entry.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
