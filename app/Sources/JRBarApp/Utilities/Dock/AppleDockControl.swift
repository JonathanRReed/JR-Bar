import AppKit
import Foundation

/// The seam `AppleDockControl` writes `autohide` (and `autohide-delay`)
/// through — verbs small enough that a test can substitute an in-memory
/// store. The real implementation is a `UserDefaults` suite on
/// `com.apple.dock`.
protocol AppleDockDefaults {
    func setBool(_ value: Bool, forKey key: String)
    /// `autohide-delay` is a float.
    func setDouble(_ value: Double, forKey key: String)
    /// Removes a key — needed when the value saved was "absent", since
    /// restore must hand back "no key", not a 0.
    func removeValue(forKey key: String)
    /// Flushes pending writes to cfprefsd before the Dock restart that
    /// makes them take — the relaunch reads `com.apple.dock` on its way
    /// up, so the writes must be visible first.
    func synchronize()
}

/// `com.apple.dock` via a `UserDefaults` suite — writes go through
/// cfprefsd, never the plist file.
struct UserDefaultsAppleDockDefaults: AppleDockDefaults {
    private let defaults = UserDefaults(suiteName: AppleDockControl.suiteName)
    func setBool(_ value: Bool, forKey key: String) { defaults?.set(value, forKey: key) }
    func setDouble(_ value: Double, forKey key: String) { defaults?.set(value, forKey: key) }
    func removeValue(forKey key: String) { defaults?.removeObject(forKey: key) }
    func synchronize() { defaults?.synchronize() }
}

/// What `autohide-delay` held before the old bar's hide — tri-state
/// because the key can be absent, and "absent" restores as a removal,
/// not a 0.
enum AppleDockSavedDelay: Equatable, Sendable {
    case nothing
    case absent
    case value(Double)
}

/// What survives of the save-and-restore control the Replace bar used
/// over Apple's Dock's `autohide`: the restore. The bar and its hide
/// are gone (09-15: the Dock is Enhance only). A build that ran it
/// saved `autohide` and `autohide-delay` as they were before its first
/// hide, mirrored into our own defaults so a crash mid-hide couldn't
/// strand the Dock hidden; init picks those values up and `restore()`
/// puts them back, so a Mac the bar left with Apple's Dock hidden gets
/// it back on the first launch of this build.
///
/// `restore()` is the only write to `com.apple.dock`, and it restarts
/// the Dock (`killall Dock`) since `autohide` only takes on relaunch.
/// With nothing saved it is a no-op — it never invents a write. Every
/// transition is logged through `onLog` so the caller can surface it.
final class AppleDockControl {
    /// Apple's Dock preferences domain.
    static let suiteName = "com.apple.dock"
    static let autohideKey = "autohide"
    static let autohideDelayKey = "autohide-delay"

    /// Keys in our own defaults that mirror the saved values — written
    /// by the old bar's hide, read here so the next launch's `restore()`
    /// still knows what to write back.
    private enum Persisted {
        static let autohide = "JRBarDock.savedAutohide"
        static let autohideDelay = "JRBarDock.savedAutohideDelay"
    }

    var defaults: any AppleDockDefaults
    /// Our own suite for the crash-safe mirror — injectable for tests.
    var persistence: UserDefaults
    /// Restarts the Dock so `autohide` takes effect — injectable; the
    /// default shells out to `killall Dock`.
    var restartDock: () -> Void = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
    /// One line per state change — the store pipes this to its log.
    var onLog: (String) -> Void = { _ in }

    /// The `autohide` value found before the old bar's first hide; nil
    /// when nothing was saved (and after `restore` hands it back).
    private(set) var savedAutohide: Bool?
    /// The `autohide-delay` value found before that hide — `.absent`
    /// means the key wasn't there and restore removes the bar's.
    private(set) var savedDelay: AppleDockSavedDelay = .nothing

    init(defaults: any AppleDockDefaults = UserDefaultsAppleDockDefaults(),
         persistence: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistence = persistence
        // Pick up a hide a previous life never restored.
        savedAutohide = persistence.object(forKey: Persisted.autohide) as? Bool
        if let stored = persistence.object(forKey: Persisted.autohideDelay) {
            savedDelay = (stored as? Double).map { .value($0) } ?? .absent
        }
    }

    /// Put back whatever `autohide` and `autohide-delay` held before
    /// the old bar's first hide. A no-op when nothing was saved —
    /// `restore` never invents a write. Returns true when a restore
    /// actually ran.
    @discardableResult
    func restore() -> Bool {
        guard savedAutohide != nil || savedDelay != .nothing else { return false }
        if let saved = savedAutohide {
            defaults.setBool(saved, forKey: Self.autohideKey)
        }
        switch savedDelay {
        case .value(let delay):
            defaults.setDouble(delay, forKey: Self.autohideDelayKey)
        case .absent:
            defaults.removeValue(forKey: Self.autohideDelayKey)
        case .nothing:
            break
        }
        defaults.synchronize()
        restartDock()
        savedAutohide = nil
        savedDelay = .nothing
        persistence.removeObject(forKey: Persisted.autohide)
        persistence.removeObject(forKey: Persisted.autohideDelay)
        onLog("Restored com.apple.dock autohide + autohide-delay; restarted Dock")
        return true
    }
}
