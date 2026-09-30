import Foundation

/// Two stores name whether the Screen Bar is shown: the app's own
/// `app-state.json` (`showScreenBar`, which owns the window) and the
/// daemon's `virtual_status_device_enabled` (which owns the `screen_bar`
/// device). This is the bookkeeping that keeps them in step, kept apart
/// from `AppDelegate` so every case can be decided without a daemon.
///
/// A toggle made while the daemon is down is the person's choice, so it
/// wins when the daemon comes back: the daemon's value at that moment is
/// only what it last heard, and the app never told it. Every other
/// mismatch is a change made somewhere else (Settings › Devices, another
/// client), and the app adopts it.
struct ScreenBarDaemonSync {
    /// What the app should do with one look at the two values.
    enum Decision: Equatable {
        /// Nothing to do: not connected yet, or no value to compare.
        case none
        /// Both stores already say the same thing.
        case agree
        /// The daemon still shows the old value while our write lands.
        case wait
        /// Write this value to the daemon.
        case push(Bool)
        /// Follow the daemon: it holds a newer choice than the app's.
        case adopt(Bool)
    }

    /// How long our own write may take to echo back before a mismatch
    /// counts as somebody else's change.
    static let pendingWindow: TimeInterval = 10

    /// The two stores have been compared at least once since the daemon
    /// connected.
    private(set) var synced = false
    /// The person toggled while the daemon was down and the daemon has not
    /// heard about it. Spent by the first look after it reconnects.
    private(set) var changedOffline = false
    /// A write we sent whose echo has not landed yet: while it is in
    /// flight a mismatch is the old value, not a new choice.
    private(set) var pending: (value: Bool, at: Date)?

    /// The person toggled the Screen Bar to `shown`. A click while the
    /// daemon is connected is written straight away and supersedes an
    /// earlier offline click; a click while it is down waits for the
    /// reconnect.
    mutating func toggled(shown: Bool, live: Bool, now: Date) {
        if live {
            pending = (shown, now)
            changedOffline = false
        } else {
            changedOffline = true
        }
    }

    /// One look at the settings document, on every core change.
    /// `daemonValue` is nil when the document is absent or carries no
    /// `virtual_status_device_enabled`.
    mutating func reconcile(live: Bool, daemonValue: Bool?, appValue: Bool, now: Date) -> Decision {
        guard live else {
            // The offline choice survives every pass while the daemon is down.
            synced = false
            pending = nil
            return .none
        }
        if changedOffline {
            // Spent exactly once, whatever the daemon's retained value says.
            changedOffline = false
            synced = true
            if daemonValue == appValue { return .agree }
            pending = (appValue, now)
            return .push(appValue)
        }
        guard let daemonValue else {
            // First contact and the daemon has never heard the fact: push
            // the app's remembered visibility so its `screen_bar` device
            // agrees with the window that is actually up.
            guard !synced else { return .none }
            synced = true
            pending = (appValue, now)
            return .push(appValue)
        }
        if daemonValue == appValue {
            synced = true
            if pending?.value == daemonValue { pending = nil }
            return .agree
        }
        if let pending, now.timeIntervalSince(pending.at) < Self.pendingWindow { return .wait }
        pending = nil
        // A daemon value that is present and disagrees is the user's
        // latest choice (Settings › Devices, another client), and it is
        // also the first-contact initializer for the app's value when the
        // two stores had never met. Adopt it; don't write back.
        synced = true
        return .adopt(daemonValue)
    }

    /// The write was refused, or failed while the daemon stayed up: what
    /// it carried is no longer in flight, so the next mismatch is adopted.
    mutating func pushRefused() {
        pending = nil
    }

    /// The write failed because the daemon went away under it. The
    /// daemon may never have heard it, so it is kept as an offline
    /// choice and sent on the next connect.
    mutating func pushLostOffline() {
        pending = nil
        changedOffline = true
    }
}
