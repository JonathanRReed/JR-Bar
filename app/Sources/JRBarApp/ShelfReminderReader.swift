import Foundation

/// One reminders fetch for the app. New requests wait for the running fetch;
/// each model keeps only its latest waiting request. Stopping forgets replies,
/// never the native fetch or its store.
@MainActor
final class ShelfReminderReader {
    static let shared = ShelfReminderReader(store: SystemShelfEventStore.shared)
    typealias Reply = @MainActor @Sendable ([ShelfRemindersModel.Entry]?) -> Void

    let store: any ShelfEventStore
    private var pending: [UUID: Reply] = [:]
    private var active: [UUID: Reply] = [:]
    private var inFlight: Int?
    private var generation = 0

    init(store: any ShelfEventStore) { self.store = store }

    func request(for owner: UUID, completion: @escaping Reply) {
        pending[owner] = completion
        startPending()
    }

    func forget(_ owner: UUID) {
        pending.removeValue(forKey: owner)
        active.removeValue(forKey: owner)
    }

    /// Project on EventKit's callback queue. Only value rows enter the main actor.
    nonisolated static func callback<Reminder>(
        project: @escaping @Sendable (Reminder) -> ShelfRemindersModel.Entry?,
        completion: @escaping Reply
    ) -> @Sendable ([Reminder]?) -> Void {
        { reminders in
            let entries = reminders?.compactMap(project)
            _ = Task { @MainActor in completion(entries) }
        }
    }

    nonisolated static func entry(id: String?, title: String?, due: Date?) -> ShelfRemindersModel.Entry? {
        guard let id, !id.isEmpty else { return nil }
        let title = title ?? ""
        return ShelfRemindersModel.Entry(id: id, title: title.isEmpty ? "Reminder" : title, due: due)
    }

    private func startPending() {
        guard inFlight == nil, !pending.isEmpty else { return }
        generation += 1
        let generation = self.generation
        inFlight = generation
        active = pending
        pending.removeAll()
        store.fetchReminders { [self] entries in
            guard inFlight == generation else { return }
            let replies = active
            active.removeAll()
            // Keep the flight occupied through delivery, including reentrant refreshes.
            for reply in replies.values { reply(entries) }
            inFlight = nil
            startPending()
        }
    }
}
