import AppKit
import Foundation

/// The seam `AppleDockControl` reads and writes `autohide` (and
/// `autohide-delay`) through — verbs small enough that a test can
/// substitute an in-memory store. The real implementation is a
/// `UserDefaults` suite on `com.apple.dock`.
protocol AppleDockDefaults {
    func boolValue(forKey key: String) -> Bool?
    func setBool(_ value: Bool, forKey key: String)
    /// `autohide-delay` is a float. The defaults below let a bool-only
    /// fake keep conforming; a real store implements all five.
    func doubleValue(forKey key: String) -> Double?
    func setDouble(_ value: Double, forKey key: String)
    /// Removes a key — needed when the value we saved was "absent",
    /// since restore must hand back "no key", not a 0.
    func removeValue(forKey key: String)
    /// Flushes pending writes to cfprefsd before the Dock restart that
    /// makes them take — the relaunch reads `com.apple.dock` on its way
    /// up, so the writes must be visible first.
    func synchronize()
}

extension AppleDockDefaults {
    func doubleValue(forKey key: String) -> Double? { nil }
    func setDouble(_ value: Double, forKey key: String) {}
    func removeValue(forKey key: String) {}
    func synchronize() {}
}

/// `com.apple.dock` via a `UserDefaults` suite — reads and writes go
/// through cfprefsd, never the plist file.
struct UserDefaultsAppleDockDefaults: AppleDockDefaults {
    private let defaults = UserDefaults(suiteName: AppleDockControl.suiteName)
    func boolValue(forKey key: String) -> Bool? { defaults?.object(forKey: key) as? Bool }
    func setBool(_ value: Bool, forKey key: String) { defaults?.set(value, forKey: key) }
    func doubleValue(forKey key: String) -> Double? { defaults?.object(forKey: key) as? Double }
    func setDouble(_ value: Double, forKey key: String) { defaults?.set(value, forKey: key) }
    func removeValue(forKey key: String) { defaults?.removeObject(forKey: key) }
    func synchronize() { defaults?.synchronize() }
}

/// What `autohide-delay` held before our hide — tri-state because the
/// key can be absent, and "absent" restores as a removal, not a 0.
enum AppleDockSavedDelay: Equatable, Sendable {
    case nothing
    case absent
    case value(Double)
}

/// The save-and-restore control over Apple's Dock's `autohide` that
/// the Replace bar used. The bar is gone; `restore()` stays so a Mac
/// the bar left with Apple's Dock hidden gets it back, and the hide
/// path is kept only because the tests pin the restore against it.
///
/// All mutation funnels through `setAppleDockHidden(_:)` and
/// `restore()` — nothing else writes `com.apple.dock`, and every write
/// restarts the Dock (`killall Dock`) since `autohide` only takes on
/// relaunch. The value found on the first hide is remembered and
/// `restore()` puts it back; a restore with nothing saved is a no-op.
/// Reads are always live, so the card can show the dock's real state.
///
/// Reads happen on whatever caller provides; every transition is
/// logged through `onLog` so the caller can surface it.
final class AppleDockControl {
    /// Apple's Dock preferences domain.
    static let suiteName = "com.apple.dock"
    static let autohideKey = "autohide"
    static let autohideDelayKey = "autohide-delay"
    /// The reveal delay we write on hide — long enough that a pointer
    /// on the screen's edge can never summon Apple's Dock over ours
    /// (autohide alone leaves it one hover away).
    static let hiddenDelay: Double = 1000

    /// Keys in our own defaults that mirror the saved values, so a
    /// crash mid-hide can't strand the user's dock hidden forever —
    /// the next launch's `restore()` still knows what to write back.
    private enum Persisted {
        static let autohide = "JRBarDock.savedAutohide"
        static let autohideDelay = "JRBarDock.savedAutohideDelay"
        /// Marker stored when the delay key was absent before us.
        static let delayWasAbsent = "absent"
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

    /// The `autohide` value found before our first hide; nil until a
    /// hide runs (and after `restore` hands it back).
    private(set) var savedAutohide: Bool?
    /// The `autohide-delay` value found before our first hide —
    /// `.absent` means the key wasn't there and restore removes ours.
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

    /// Apple's current `autohide` — absent means off, same as the
    /// Dock's own default.
    var isAppleDockHidden: Bool {
        defaults.boolValue(forKey: Self.autohideKey) ?? false
    }

    /// The caller's explicit control: write `autohide`, restart the
    /// Dock. Hiding saves the live values once — `autohide` AND
    /// `autohide-delay`, which we pin at `hiddenDelay` so the hidden
    /// dock can't peek back — so `restore()` can put the user's
    /// settings back. A hide that finds the values already pinned
    /// (re-entering Replace, or the user's own identical setup) skips
    /// the write and the restart — `killall Dock` is a visible bounce,
    /// not something to spend on a no-op. Unhiding writes `autohide`
    /// directly (use `restore()` to return to whatever was there
    /// before us).
    func setAppleDockHidden(_ hidden: Bool) {
        if hidden {
            if savedAutohide == nil {
                savedAutohide = defaults.boolValue(forKey: Self.autohideKey) ?? false
                persistence.set(savedAutohide, forKey: Persisted.autohide)
                onLog("Saved com.apple.dock autohide=\(savedAutohide == true)")
            }
            if savedDelay == .nothing {
                if let delay = defaults.doubleValue(forKey: Self.autohideDelayKey) {
                    savedDelay = .value(delay)
                    persistence.set(delay, forKey: Persisted.autohideDelay)
                } else {
                    savedDelay = .absent
                    persistence.set(Persisted.delayWasAbsent, forKey: Persisted.autohideDelay)
                }
                onLog("Saved com.apple.dock autohide-delay")
            }
            if isPinned {
                onLog("com.apple.dock already pinned (autohide + \(Int(Self.hiddenDelay))s delay); no restart")
                return
            }
            defaults.setBool(true, forKey: Self.autohideKey)
            defaults.setDouble(Self.hiddenDelay, forKey: Self.autohideDelayKey)
            defaults.synchronize()
            restartDock()
            onLog("Set com.apple.dock autohide=true, autohide-delay=\(Int(Self.hiddenDelay)); restarted Dock")
            return
        }
        defaults.setBool(false, forKey: Self.autohideKey)
        defaults.synchronize()
        restartDock()
        onLog("Set com.apple.dock autohide=\(hidden); restarted Dock")
    }

    /// True when `com.apple.dock` already holds our hidden state —
    /// `autohide` on AND the reveal delay pinned at `hiddenDelay`.
    private var isPinned: Bool {
        isAppleDockHidden
            && defaults.doubleValue(forKey: Self.autohideDelayKey) == Self.hiddenDelay
    }

    /// The one-shot re-assert the hide schedules ~1 s after the Dock
    /// restart: if the relaunch raced the defaults write — or anything
    /// else touched the keys while our hide is live — put the pinned
    /// values back and bounce the Dock once more. A no-op when our
    /// hide isn't live or the values still hold; deliberately not a
    /// poll loop, one correction is enough.
    func reassertPinned() {
        guard savedAutohide != nil || savedDelay != .nothing else { return }
        guard !isPinned else { return }
        defaults.setBool(true, forKey: Self.autohideKey)
        defaults.setDouble(Self.hiddenDelay, forKey: Self.autohideDelayKey)
        defaults.synchronize()
        restartDock()
        onLog("Re-asserted com.apple.dock autohide + autohide-delay; restarted Dock")
    }

    /// Put back whatever `autohide` and `autohide-delay` held before
    /// our first hide. A no-op when nothing was saved — `restore`
    /// never invents a write. Returns true when a restore actually ran.
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
