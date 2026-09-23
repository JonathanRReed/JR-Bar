import Foundation

/// What JR-Bar has to tell the person outside a click — a lost
/// permission, a second install, an update that is ready — held until
/// the panel is open to say it. The panel's toast lives a few seconds;
/// posted while the panel is shut it was never seen.
///
/// One notice per opening, oldest first. Posting again under the same
/// key replaces the waiting notice instead of queueing it twice, and a
/// notice can be withdrawn once it no longer applies.
@MainActor
final class LaunchNotices {
    static let shared = LaunchNotices()

    struct Notice {
        let key: String
        let text: String
        let actionTitle: String
        let action: @MainActor () -> Void
    }

    private(set) var waiting: [Notice] = []

    func post(_ notice: Notice) {
        if let index = waiting.firstIndex(where: { $0.key == notice.key }) {
            waiting[index] = notice
        } else {
            waiting.append(notice)
        }
    }

    func withdraw(key: String) {
        waiting.removeAll { $0.key == key }
    }

    /// The next notice to show, taken off the queue.
    func next() -> Notice? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }
}
