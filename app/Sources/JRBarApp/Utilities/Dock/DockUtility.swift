import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Dock utility (docs/TOY-PARITY.md, "Dock — Enhance"): Apple's
/// Dock stays, and `enhance` — the AX hover watcher — floats window
/// previews over it. The main thread constructs it once, wires
/// `settings` to the persisted `DockSettings`, sets the persist
/// callback, and calls `start()`/`stop()` from the card toggle and
/// `applySettings()` on every settings change.
///
/// The Replace bar is gone; what survives of it is `appleDock`, the
/// save-and-restore control over `com.apple.dock autohide`, kept so a
/// Mac the old bar left with Apple's Dock hidden gets it back on the
/// first launch of this build.
@MainActor
@Observable
final class DockUtility {
    /// The live settings read — wire to `UtilitiesStore`'s dock state.
    var settings: @MainActor () -> DockSettings = { DockSettings() }
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it and re-applies the utility —
    /// the same shape `MenuBarUtility` uses.
    var onSettingsChange: (@MainActor (DockSettings) -> Void)?

    /// Apple's own dock's hide/restore control — restore-only now.
    let appleDock: AppleDockControl
    /// The hover watcher: the AX poll and the preview panel.
    let enhance: DockEnhanceController

    /// True while the watcher runs.
    private(set) var running = false

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `AppleDockControl()` can't be a default value — callers pass
    /// nil and the main-actor body builds it.
    init(appleDock: AppleDockControl? = nil) {
        self.appleDock = appleDock ?? AppleDockControl()
        let preferences = DockEnhancePreferences()
        self.enhance = DockEnhanceController(preferences: preferences)
        preferences.read = { [weak self] in self?.settings().enhance ?? DockEnhanceSettings() }
        preferences.write = { [weak self] updated in
            self?.update { $0.enhance = updated }
        }
    }

    /// Turn the watcher on. No-op unless the card is on. Apple's Dock
    /// is the stage, so any hide of ours still in place is undone
    /// first.
    func start() {
        guard !running else { return }
        guard settings().enabled else { return }
        running = true
        appleDock.restore()
        enhance.start()
    }

    func stop() {
        guard running else { return }
        enhance.stop()
        running = false
    }

    /// The caller's "settings changed" nudge: start on enable, stop on
    /// disable; the watcher reads its knobs live, so nothing else needs
    /// re-applying.
    func applySettings() {
        migrateLegacyEnhanceDefaults()
        // A previous life's Replace bar may have left Apple's Dock
        // hidden under our saved values — hand them back regardless of
        // whether the watcher is running.
        appleDock.restore()
        let current = settings()
        if current.enabled, !running {
            start()
        } else if !current.enabled, running {
            stop()
        }
    }

    /// True once the pre-schema `UserDefaults` knobs have been folded
    /// into `DockSettings.enhance` — the write itself persists through
    /// the store, so a second pass only ever finds removed keys.
    private var migratedEnhanceDefaults = false

    /// Builds before `DockSettings.enhance` wrote two `UserDefaults`
    /// keys — a contract violation (`app-state.json` owns persisted
    /// state). Fold whichever exist into the settings once, then drop
    /// the keys; an unset key means "no value to carry".
    private func migrateLegacyEnhanceDefaults() {
        guard !migratedEnhanceDefaults else { return }
        migratedEnhanceDefaults = true
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: DockEnhancePreferences.legacyDelayKey) as? Double
        let thumbnails = defaults.object(forKey: DockEnhancePreferences.legacyThumbnailsKey) as? Bool
        guard delay != nil || thumbnails != nil else { return }
        update { draft in
            if let delay { draft.enhance.previewDelay = delay }
            if let thumbnails { draft.enhance.showThumbnails = thumbnails }
        }
        defaults.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
        defaults.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
    }

    /// The card's "Open Settings" for the Accessibility row.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The card's "Open Settings" for the Screen Recording row.
    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Card writes

    /// A card edit: mutate a copy of the persisted settings and hand it
    /// to the store, whose `state` write persists and re-applies.
    func update(_ mutate: (inout DockSettings) -> Void) {
        var draft = settings()
        mutate(&draft)
        onSettingsChange?(draft)
    }

    /// A binding into the persisted settings; the store's `didSet`
    /// debounces the write, so a dragged slider doesn't stream saves.
    func bind<T>(_ keyPath: WritableKeyPath<DockSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}
