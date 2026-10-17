import CoreFoundation

/// The status-item gap, written to the same place Bartender's
/// "reduce spacing" writes it: `NSStatusItemSpacing` and
/// `NSStatusItemSelectionPadding` in the current-host global
/// preferences domain (`defaults -currentHost write -g`). Status
/// items read the values when they come up, so the change reaches a
/// running item only on its app's next launch — the bar itself never
/// reflows live, ours or Apple's.
enum MenuBarSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"

    struct Preferences {
        var read: (String) -> CFPropertyList?
        var set: (String, CFPropertyList?) -> Void
        var synchronize: () -> Bool

        static var live: Self {
            let app = kCFPreferencesAnyApplication
            let user = kCFPreferencesCurrentUser
            let host = kCFPreferencesCurrentHost
            return Self(
                read: { CFPreferencesCopyValue($0 as CFString, app, user, host) },
                set: { CFPreferencesSetValue($0 as CFString, $1, app, user, host) },
                synchronize: { CFPreferencesSynchronize(app, user, host) })
        }
    }

    /// `spacing > 0` writes both keys (the selection padding tracks
    /// the gap at half); `spacing == 0` removes them — called only
    /// when the settings say we wrote them before, so a hand-set
    /// `defaults` tweak is never clobbered by a utility that never
    /// touched it.
    final class Writer {
        private let preferences: Preferences
        private var pendingRestore: (spacing: CFPropertyList?, padding: CFPropertyList?)?

        init(preferences: Preferences = .live) {
            self.preferences = preferences
        }

        func write(spacing: Int, managed: Bool) -> Bool {
            guard restore() else { return false }
            guard spacing > 0 || managed else { return true }
            let previous = (spacing: preferences.read(spacingKey), padding: preferences.read(paddingKey))
            preferences.set(spacingKey, spacing > 0 ? spacing as CFNumber : nil)
            preferences.set(paddingKey, spacing > 0 ? max(0, spacing / 2) as CFNumber : nil)
            if preferences.synchronize() { return true }
            pendingRestore = previous
            _ = restore()
            return false
        }

        private func restore() -> Bool {
            guard let previous = pendingRestore else { return true }
            preferences.set(spacingKey, previous.spacing)
            preferences.set(paddingKey, previous.padding)
            guard preferences.synchronize() else { return false }
            pendingRestore = nil
            return true
        }
    }
}
