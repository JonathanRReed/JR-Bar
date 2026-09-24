import AppKit

/// How a JR-Bar window comes in front of the app you're in. JR-Bar is an
/// accessory app, never frontmost on its own, and activation is
/// cooperative on macOS 14+: the deprecated `activate(ignoringOtherApps:)`
/// could open a window behind the frontmost app — the "nothing happens"
/// report. Every window a click, a key or a link opens comes forward
/// through `bring`. One that comes up on its own (What's New's launch
/// showing, the tank left on at quit) orders in without it and leaves
/// the app you're in active. Setup's first-run showing is the one in
/// between: it asks to come active, as it always has, but with no
/// fallback, so a login launch never forces it past the app you're in.
@MainActor
enum WindowFront {
    /// How long the frontmost app has to yield before Launch Services
    /// is asked instead.
    static let fallbackDelay: TimeInterval = 0.25

    /// Activates the app and puts `window` in front and key on the
    /// Space you're on, out of the Dock if it was minimised. A nil
    /// `fallback` only asks: no Launch Services step follows.
    static func bring(_ window: NSWindow, fallback: Fallback? = .live) {
        // Both calls: the pairing that reliably forces it on macOS 26/27.
        NSRunningApplication.current.activate()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        orderIn(window, isOnActiveSpace: window.isOnActiveSpace) { front in
            front.makeKeyAndOrderFront(nil)
            front.makeKey()
        }
        guard let fallback else { return }
        armFallback(fallback, isShowing: { [weak window] in window?.isVisible ?? false })
    }

    /// Runs `order` with `window` pulled onto the active Space. A window
    /// left on another Space orders front there and reads as nothing
    /// happening; `.moveToActiveSpace` brings it here for the order-in,
    /// then comes straight off so it stays put afterwards. A window that
    /// already carries the behaviour keeps it, and one on every Space
    /// is never given it: AppKit throws from `setCollectionBehavior:`
    /// with both. Internal for the test, which orders nothing in.
    static func orderIn(_ window: NSWindow, isOnActiveSpace: Bool, _ order: (NSWindow) -> Void) {
        let behavior = window.collectionBehavior
        let pull = !isOnActiveSpace
            && !behavior.contains(.moveToActiveSpace)
            && !behavior.contains(.canJoinAllSpaces)
        if pull { window.collectionBehavior.insert(.moveToActiveSpace) }
        order(window)
        if pull { window.collectionBehavior.remove(.moveToActiveSpace) }
    }

    /// The Launch Services fallback's clock and facts. When the frontmost
    /// app does not yield, the activation request is dropped and the
    /// window opens inactive (grey controls, no key focus) or behind it;
    /// opening ourselves through Launch Services is the sanctioned way
    /// through anyway. The live one waits on the main queue, watches
    /// for the app coming active (`ActivationWatch`), and opens this
    /// bundle; the tests hand in their own.
    struct Fallback {
        var wait: @MainActor (_ delay: TimeInterval, _ then: @escaping @MainActor () -> Void) -> Void
        /// Starts a watch on the app's activation. The closure it hands
        /// back ends the watch and says whether the app was active at
        /// any point since.
        var watchActivation: @MainActor () -> (@MainActor () -> Bool)
        var openSelf: @MainActor () -> Void

        static var live: Fallback {
            Fallback(wait: { delay, then in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { then() }
                }
            }, watchActivation: {
                let activation = ActivationWatch()
                return { activation.end() }
            }, openSelf: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
            })
        }
    }

    /// `fallbackDelay` after the order-in, asks Launch Services to open
    /// us, but only for an app that never came active in the meantime
    /// and a window still up. Active at any point, the request landed,
    /// and whatever is in front when the wait ends is your own pick (a
    /// ⌘-Tab away inside the quarter second); a window closed inside
    /// it leaves nothing to bring. Internal for the test.
    static func armFallback(_ fallback: Fallback, isShowing: @escaping @MainActor () -> Bool) {
        let cameActive = fallback.watchActivation()
        fallback.wait(fallbackDelay) {
            // Always asked first: it ends the watch.
            guard !cameActive(), isShowing() else { return }
            fallback.openSelf()
        }
    }

    /// Whether the app was active at any point from the watch's start
    /// to its `end`: at the start, on `didBecomeActiveNotification` in
    /// between, or at the end. A moment's activation is enough: a read
    /// when the wait ends can't tell "never came" from "came, then you
    /// moved on". Internal for the test, which hands in its own center
    /// and flag.
    @MainActor
    final class ActivationWatch {
        private let center: NotificationCenter
        private let isActive: @MainActor () -> Bool
        private var cameActive: Bool
        private var observer: NSObjectProtocol?

        init(center: NotificationCenter = .default,
             isActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
            self.center = center
            self.isActive = isActive
            cameActive = isActive()
            // No queue: AppKit posts it on the main thread, and the
            // note lands the moment it does.
            observer = center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                          object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameActive = true }
            }
        }

        /// Stops listening and answers; a later activation is not heard.
        func end() -> Bool {
            if let observer { center.removeObserver(observer) }
            observer = nil
            return cameActive || isActive()
        }
    }
}
