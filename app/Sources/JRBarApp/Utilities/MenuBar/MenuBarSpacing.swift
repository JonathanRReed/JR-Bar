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

    /// `spacing > 0` writes both keys (the selection padding tracks
    /// the gap at half); `spacing == 0` removes them — called only
    /// when the settings say we wrote them before, so a hand-set
    /// `defaults` tweak is never clobbered by a utility that never
    /// touched it.
    static func write(spacing: Int, managed: Bool) {
        let app = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesCurrentHost
        if spacing > 0 {
            CFPreferencesSetValue(spacingKey as CFString, spacing as CFNumber, app, user, host)
            CFPreferencesSetValue(paddingKey as CFString,
                                  max(0, spacing / 2) as CFNumber, app, user, host)
        } else if managed {
            CFPreferencesSetValue(spacingKey as CFString, nil, app, user, host)
            CFPreferencesSetValue(paddingKey as CFString, nil, app, user, host)
        } else {
            return
        }
        CFPreferencesAppSynchronize(app)
    }
}
