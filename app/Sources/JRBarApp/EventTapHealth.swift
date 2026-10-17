import AppKit
import CoreGraphics

/// What to do when the window server switches an event tap off.
///
/// A tap that times out, or is disabled by user input, is delivered a
/// "disabled" event, and the tap's owner asks for it to be switched back on.
/// That is only a request: when the Accessibility grant has been pulled or
/// reset, the tap stays off and nothing says so. The owner then believed the
/// tap was live, so the media-key capsules or the Dock switcher went
/// quiet until the app was relaunched.
enum EventTapHealth {
    /// The two calls the check needs, so a test can answer them.
    struct Control: Sendable {
        var enable: @Sendable (CFMachPort, Bool) -> Void
        var isEnabled: @Sendable (CFMachPort) -> Bool

        static let system = Control(
            enable: { CGEvent.tapEnable(tap: $0, enable: $1) },
            isEnabled: { CGEvent.tapIsEnabled(tap: $0) })
    }

    /// Asks for `tap` to be switched back on and says whether it is on now.
    /// False means the system refused: the owner marks the tap not live,
    /// takes it down, and leaves the retry to its usual triggers and to
    /// `EventTapRevival`.
    static func reenable(_ tap: CFMachPort, control: Control = .system) -> Bool {
        control.enable(tap, true)
        return control.isEnabled(tap)
    }
}

/// Brings a tap back when the person returns to the app.
///
/// An owner registers how to tell that its tap is down and how to ask for it
/// again. Each time the app becomes active, every tap that is down is asked
/// for once: the usual moment for a grant to have been given again is the
/// person coming back from System Settings.
@MainActor
final class EventTapRevival {
    static let shared = EventTapRevival()

    private struct Entry {
        let owner: () -> AnyObject?
        let isLive: () -> Bool
        let revive: () -> Void
    }

    private var entries: [String: Entry] = [:]

    /// The shared instance lives for the whole run; a test's own instance
    /// listens on its own center, which goes with it.
    init(center: NotificationCenter = .default) {
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    /// Registers one owner's tap under `key`. The registration lapses with
    /// the owner, and a second one under the same key replaces the first.
    func register<Owner: AnyObject>(_ owner: Owner, key: String,
                                    isLive: @escaping @MainActor (Owner) -> Bool,
                                    revive: @escaping @MainActor (Owner) -> Void) {
        entries[key] = Entry(
            owner: { [weak owner] in owner },
            isLive: { [weak owner] in
                guard let owner else { return true }
                return MainActor.assumeIsolated { isLive(owner) }
            },
            revive: { [weak owner] in
                guard let owner else { return }
                MainActor.assumeIsolated { revive(owner) }
            })
    }

    /// Asks for every tap that is down. Internal so a test can call it
    /// without posting a notification.
    func appBecameActive() {
        for (key, entry) in entries {
            guard entry.owner() != nil else {
                entries[key] = nil
                continue
            }
            if !entry.isLive() { entry.revive() }
        }
    }
}
