import Foundation

/// What JR-Bar has to tell the person outside a click — a lost
/// permission, a second install, an update that is ready, the end of a
/// deep-work stretch — said on the panel when it is open, else held
/// until it opens. The panel's toast lives a few seconds; posted while
/// the panel is shut it was never seen.
///
/// One notice per opening, oldest first. Posting again under the same
/// key replaces the waiting notice instead of queueing it twice, and a
/// notice can be withdrawn once it no longer applies. The delegate wires
/// the hands once: whether the panel is open, its toast, and the
/// Notification Center banner that goes with a notice worth keeping.
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

    var panelIsOpen: () -> Bool = { false }
    var showToast: (Notice) -> Void = { _ in }
    var deliverBanner: (_ identifier: String, _ title: String, _ body: String) -> Void = { _, _, _ in }
    var withdrawBanner: (_ identifier: String) -> Void = { _ in }

    /// Said now on an open panel, else held for its next opening.
    func say(_ notice: Notice) {
        if panelIsOpen() {
            showToast(notice)
        } else {
            post(notice)
        }
    }

    /// The panel just opened: one waiting notice, the oldest.
    func panelOpened() {
        if let notice = next() { showToast(notice) }
    }

    func post(_ notice: Notice) {
        if let index = waiting.firstIndex(where: { $0.key == notice.key }) {
            waiting[index] = notice
        } else {
            waiting.append(notice)
        }
    }

    /// The notice and its banner no longer apply.
    func withdraw(key: String) {
        waiting.removeAll { $0.key == key }
        withdrawBanner(key)
    }

    /// The next notice to show, taken off the queue.
    func next() -> Notice? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }
}
