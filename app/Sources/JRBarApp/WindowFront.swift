import AppKit

/// How a JR-Bar window comes in front of the app you're in. JR-Bar is an
/// accessory app, never frontmost on its own, and activation is
/// cooperative on macOS 14+: the deprecated `activate(ignoringOtherApps:)`
/// could open a window behind the frontmost app — the "nothing happens"
/// report. Every window a click, a key or a link opens comes forward
/// through `bring`. One that comes up on its own (What's New's launch
/// showing, the tank left on at quit) orders in without it and leaves
/// the app you're in active.
@MainActor
enum WindowFront {
    /// How long the frontmost app has to yield before Launch Services
    /// is asked instead.
    static let fallbackDelay: TimeInterval = 0.25

    /// Activates the app and puts `window` in front and key on the
    /// Space you're on, out of the Dock if it was minimised.
    static func bring(_ window: NSWindow, fallback: Fallback = .live) {
        // Both calls: the pairing that reliably forces it on macOS 26/27.
        NSRunningApplication.current.activate()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        orderIn(window, isOnActiveSpace: window.isOnActiveSpace) { front in
            front.makeKeyAndOrderFront(nil)
            front.makeKey()
        }
        armFallback(fallback)
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
    /// through anyway. The live one waits on the main queue, reads
    /// `NSApp.isActive` when it fires, and opens this bundle; the tests
    /// hand in their own.
    struct Fallback {
        var wait: @MainActor (_ delay: TimeInterval, _ then: @escaping @MainActor () -> Void) -> Void
        var isActive: @MainActor () -> Bool
        var openSelf: @MainActor () -> Void

        static var live: Fallback {
            Fallback(wait: { delay, then in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { then() }
                }
            }, isActive: {
                NSApp.isActive
            }, openSelf: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
            })
        }
    }

    /// `fallbackDelay` after the order-in, asks Launch Services to open
    /// us unless the app has come active by then. The check is made
    /// when the wait ends, not when it starts: activation lands a beat
    /// after the request. Internal for the test.
    static func armFallback(_ fallback: Fallback) {
        fallback.wait(fallbackDelay) {
            guard !fallback.isActive() else { return }
            fallback.openSelf()
        }
    }
}
