import AppKit
import Foundation
import OSLog

/// The seam `DockAutohideHold` toggles the running Dock's `autohide`
/// through — the private `CoreDock` verbs `HIServices` exports,
/// resolved at runtime the way `MenuBarAssessmentBackend` resolves
/// `MenuBarClientCore`. Where `AppleDockControl`'s defaults write
/// needs a `killall Dock` to take, this pair applies live: it is how
/// every Dock overlay holds Apple's Dock out while its panel is up
/// (and why DockDoor once shipped the "stuck out of autohide" bug —
/// the write *is* the `com.apple.dock` default, so a crash mid-hold
/// leaves it changed; the persisted marker below is the recovery).
///
/// A build where the symbols don't resolve gets no driver — the hold
/// stays off and previews simply let the Dock autohide, the pre-hold
/// behaviour.
protocol DockAutohideDriver {
    /// The Dock's live `autohide` — reads go through the Dock itself,
    /// not a cached defaults key.
    var isAutohideEnabled: Bool { get }
    /// Toggle it in place; also lands in `com.apple.dock` for us.
    func setAutohideEnabled(_ enabled: Bool)
}

/// `CoreDockGet/SetAutoHideEnabled` out of HIServices — a public-path
/// framework carrying the private pair since before the CoreDock
/// framework itself disappeared.
struct CoreDockAutohideDriver: DockAutohideDriver {
    /// The only home verified on macOS 27; the older names are kept
    /// so a build on an older OS still resolves.
    private static let candidates = [
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
    ]

    private let getEnabled: @convention(c) () -> Bool
    private let setEnabled: @convention(c) (Bool) -> Void

    /// nil where the framework or the pair doesn't resolve — callers
    /// treat nil as "no hold-out on this build".
    init?() {
        var resolved: (get: @convention(c) () -> Bool,
                       set: @convention(c) (Bool) -> Void)?
        for path in Self.candidates {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            guard let getSym = dlsym(handle, "CoreDockGetAutoHideEnabled"),
                  let setSym = dlsym(handle, "CoreDockSetAutoHideEnabled") else { continue }
            resolved = (
                unsafeBitCast(getSym, to: (@convention(c) () -> Bool).self),
                unsafeBitCast(setSym, to: (@convention(c) (Bool) -> Void).self))
            break
        }
        guard let resolved else { return nil }
        getEnabled = resolved.get
        setEnabled = resolved.set
    }

    var isAutohideEnabled: Bool { getEnabled() }
    func setAutohideEnabled(_ enabled: Bool) { setEnabled(enabled) }
}

/// The preview's hold on an auto-hiding Dock: while a panel is up the
/// Dock's `autohide` is switched off so the pointer can leave the
/// icons for the cards without the stage sliding away; the value it
/// held goes back the moment the panel closes.
///
/// Crash-safety mirrors `AppleDockControl`: the value found before
/// the first hold is mirrored into our own defaults, so the next
/// launch's `recoverIfNeeded()` can hand it back even when `release()`
/// never ran. A hold taken while `autohide` was already off saves
/// nothing and releases as a no-op.
final class DockAutohideHold {
    /// Key in `persistence` mirroring the pre-hold `autohide`.
    private static let persistedKey = "JRBarDock.autohideHold.saved"

    var driver: (any DockAutohideDriver)?
    /// Our own suite for the crash-safe mirror — injectable for tests.
    var persistence: UserDefaults
    /// The `defaults`+restart fallback for recovery when the driver is
    /// gone: a stranded hold is worth one Dock bounce; a live hold
    /// never uses this path.
    var fallbackWrite: (Bool) -> Void
    /// One line per state change — the store pipes this to its log.
    var onLog: (String) -> Void = { _ in }

    /// The `autohide` found before a hold — set by `hold()` this life
    /// or picked up from `persistence` as a stale marker a crashed
    /// life left. Either way it is the user's own value.
    private(set) var savedAutohide: Bool?
    /// True only while a `hold()` this life is open — the difference
    /// between "we are holding" and "a dead life left a marker", which
    /// is what lets `recoverIfNeeded()` run on every settings apply
    /// without cutting a live hold.
    private var liveHold = false

    init(driver: (any DockAutohideDriver)? = CoreDockAutohideDriver(),
         persistence: UserDefaults = .standard,
         fallbackWrite: ((Bool) -> Void)? = nil) {
        self.driver = driver
        self.persistence = persistence
        self.fallbackWrite = fallbackWrite ?? { enabled in
            UserDefaults(suiteName: AppleDockControl.suiteName)?.set(enabled, forKey: AppleDockControl.autohideKey)
            UserDefaults(suiteName: AppleDockControl.suiteName)?.synchronize()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Dock"]
            try? process.run()
        }
        // Pick up a hold a previous life never released.
        savedAutohide = persistence.object(forKey: Self.persistedKey) as? Bool
    }

    /// True while a hold this life is open.
    var holding: Bool { liveHold }

    /// Called as each preview opens: pin the Dock out. A no-op when
    /// already held, when the driver is missing, or when `autohide`
    /// is off — a Dock that is always out needs no holding. A stale
    /// marker is kept, not overwritten: it is the user's original
    /// value, older than anything we would read now.
    func hold() {
        guard let driver, !liveHold else { return }
        guard driver.isAutohideEnabled else { return }
        liveHold = true
        if savedAutohide == nil {
            savedAutohide = true
            persistence.set(true, forKey: Self.persistedKey)
        }
        driver.setAutohideEnabled(false)
        onLog("Held com.apple.dock autohide off while the preview is up")
    }

    /// Called as each preview closes: hand the held value back. The
    /// Dock re-hides on its own once the pointer is off it.
    func release() {
        guard let saved = savedAutohide else { liveHold = false; return }
        savedAutohide = nil
        liveHold = false
        persistence.removeObject(forKey: Self.persistedKey)
        if let driver {
            driver.setAutohideEnabled(saved)
            onLog("Released the Dock hold — autohide back to \(saved)")
        } else {
            fallbackWrite(saved)
            onLog("Released the Dock hold through defaults+restart — autohide back to \(saved)")
        }
    }

    /// The launch-time sweep: a hold the last life never released gets
    /// its saved value written back once, then forgotten. Deliberately
    /// skips a live hold — `applySettings()` runs on every card edit,
    /// which lands here mid-preview.
    func recoverIfNeeded() {
        guard !liveHold else { return }
        release()
    }
}
