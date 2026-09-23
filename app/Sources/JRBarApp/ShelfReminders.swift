import AppKit
import EventKit

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

    /// The row's action without a check-off: open Reminders.app on the
    /// item — `x-apple-reminderkit://` names it by identifier.
    func openInReminders(_ entry: Entry) {
        guard let url = URL(string: "x-apple-reminderkit://reminders/\(entry.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
