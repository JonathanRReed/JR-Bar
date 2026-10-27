import Foundation
@preconcurrency import EventKit

/// The app's one EventKit store. The notch's calendar glance, its meeting
/// heads-up and seasonal touches all read through it, so the calendar
/// database is opened once and every reader sits behind the same Calendar
/// grant: nothing here ever asks for access. Reads take the lock, so two
/// readers on two queues never use the store at once.
final class SharedEventStore: @unchecked Sendable {
    static let shared = SharedEventStore()

    private let lock = NSLock()
    private var store: EKEventStore?

    /// Run `body` with the store, made on first use.
    func read<T>(_ body: (EKEventStore) -> T) -> T {
        lock.withLock {
            let store = self.store ?? EKEventStore()
            self.store = store
            return body(store)
        }
    }
}
