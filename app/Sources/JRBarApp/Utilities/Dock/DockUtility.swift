import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Dock utility, one object the wiring layer owns
/// (docs/TOY-PARITY.md, "Dock — Replace mode", the P1 rows, plus the
/// P2 hover-preview row). The main thread constructs it once, wires
/// `settings` to the persisted `DockSettings`, sets the persist
/// callbacks, and calls `start()`/`stop()` from the card toggle and
/// `applySettings()` on every settings change.
///
/// Two modes share the seat. **Replace** draws `DockPanel`s — one per
/// display the policy calls for — over `DockModel`'s workspace feed,
/// and hides Apple's Dock outright: `autohide` plus a pinned
/// `autohide-delay` so the screen edge can't summon it over our bar
/// (the user's `com.apple.dock` values are saved and restored on
/// disable/quit). **Enhance** keeps Apple's Dock and runs `enhance`,
/// the AX hover watcher that floats window previews over it — it
/// never draws the bar.
@MainActor
@Observable
final class DockUtility {
    /// The live settings read — wire to `UtilitiesStore`'s dock state.
    var settings: @MainActor () -> DockSettings = { DockSettings() }
    /// A pin toggle or reorder landed: persist the new `pinned` list.
    var onPinsChanged: (@MainActor ([String]) -> Void)?
    /// The `com.apple.dock` seed ran: persist this `pinned` list AND
    /// `seededFromAppleDock = true`.
    var onSeeded: (@MainActor ([String]) -> Void)?
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it and re-applies the utility —
    /// the same shape `MenuBarUtility` uses.
    var onSettingsChange: (@MainActor (DockSettings) -> Void)?

    /// The bar's contents — the card's preview and the panels share it.
    let model: DockModel
    /// Apple's own dock's hide/restore control.
    let appleDock: AppleDockControl
    /// Enhance mode's hover watcher — runs the AX poll and the preview
    /// panel. Idle unless `mode == .enhance`.
    let enhance: DockEnhanceController

    /// True while either mode is live.
    private(set) var running = false
    /// Which mode currently owns the screen — `applySettings` switches
    /// by leaving one and entering the other.
    private(set) var activeMode: DockMode?
    private var panels: [DockPanel] = []
    private var magnifiers: [DockMagnifier] = []
    private var screenObserver: NSObjectProtocol?

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `DockModel()`/`AppleDockControl()` can't be default values —
    /// callers pass nil and the main-actor body builds them.
    init(model: DockModel? = nil, appleDock: AppleDockControl? = nil) {
        let model = model ?? DockModel()
        self.model = model
        self.appleDock = appleDock ?? AppleDockControl()
        let preferences = DockEnhancePreferences()
        self.enhance = DockEnhanceController(preferences: preferences)
        preferences.read = { [weak self] in self?.settings().enhance ?? DockEnhanceSettings() }
        preferences.write = { [weak self] updated in
            self?.update { $0.enhance = updated }
        }
        model.settings = { [weak self] in self?.settings() ?? DockSettings() }
        model.onPinsChanged = { [weak self] pins in self?.onPinsChanged?(pins) }
        model.onSeeded = { [weak self] pins in self?.onSeeded?(pins) }
        // Folder/tray edits made on the bar persist through the same
        // settings write path the card uses.
        model.onFoldersChanged = { [weak self] paths in
            self?.update { $0.folders = paths }
        }
        model.onTrayChanged = { [weak self] paths in
            self?.update { $0.tray = paths }
        }
        model.onItemsChanged = { [weak self] in
            self?.panels.forEach { $0.reanchor() }
        }
    }

    /// Turn on whatever the persisted mode is. No-op unless the card
    /// is on.
    func start() {
        guard !running else { return }
        let current = settings()
        guard current.enabled else { return }
        running = true
        enter(current.mode)
    }

    /// Everything down, and hand Apple's Dock back whatever our hide
    /// saved — the utility owns that restore because it owns the hide.
    /// (Termination already routes here through `UtilitiesStore.stop`,
    /// which calls `appleDock.restore()` again — a no-op the second
    /// time.)
    func stop() {
        if let mode = activeMode { leave(mode) }
        activeMode = nil
        running = false
    }

    /// The caller's "settings changed" nudge: a mode switch tears one
    /// mode down and brings the other up; inside Replace, panels that
    /// can absorb the change do (`apply`) and a display-policy or
    /// screen-set change rebuilds the set.
    func applySettings() {
        migrateLegacyEnhanceDefaults()
        let current = settings()
        guard running else {
            // Not running: a crash can leave Apple's Dock hidden under
            // our saved values — if Replace isn't coming up to claim
            // them, hand them back now.
            if !(current.enabled && current.mode == .replace) {
                appleDock.restore()
            }
            return
        }
        guard current.enabled else { stop(); return }
        if activeMode != current.mode {
            if let mode = activeMode { leave(mode) }
            enter(current.mode)
            return
        }
        guard current.mode == .replace else { return }
        // The card's folder/tray/widget edits land in the model —
        // dock-side edits come back through here too, idempotently.
        model.syncCollections()
        let wanted = targetScreens(policy: current.displayPolicy)
        let held = panels.map(\.dockScreen)
        if held != wanted || panels.contains(where: { $0.edge != current.edge }) {
            rebuildPanels()
            return
        }
        for panel in panels { panel.apply(settings: current) }
    }

    // MARK: Mode transitions

    /// Bring a mode's pieces up. Replace pins Apple's Dock hidden and
    /// draws the bar; Enhance puts back any hide of ours — Apple's
    /// Dock is its stage — and starts the watcher.
    private func enter(_ mode: DockMode) {
        activeMode = mode
        switch mode {
        case .replace:
            hideAppleDockForReplace()
            model.start()
            rebuildPanels()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildPanels() }
            }
        case .enhance:
            appleDock.restore()
            enhance.start()
        }
    }

    /// Tear a mode's pieces down. Leaving Replace restores Apple's
    /// Dock if our hide is still in place — the bar's reason for the
    /// hide is gone.
    private func leave(_ mode: DockMode) {
        switch mode {
        case .replace:
            for panel in panels { panel.dismiss() }
            panels = []
            magnifiers = []
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            model.stop()
            appleDock.restore()
        case .enhance:
            enhance.stop()
        }
    }

    // MARK: Apple's Dock

    /// Replace mode's automatic hide — unconditional: Replace means
    /// the bar owns the edge, so Apple's Dock gets `autohide` AND a
    /// pinned `autohide-delay` even when the user's own Dock already
    /// auto-hides (autohide alone leaves it one hover from covering
    /// our bar). `AppleDockControl` saves the user's values once —
    /// `restore()` on disable/quit and the card's "Restore Apple's
    /// Dock" button hand them back. The delayed one-shot re-assert
    /// covers a Dock relaunch that raced the defaults write.
    func hideAppleDockForReplace() {
        appleDock.setAppleDockHidden(true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.appleDock.reassertPinned() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reassertDelay, execute: work)
    }

    /// How long after the hide's Dock restart the pinned values are
    /// re-checked — long enough for the relaunch to have settled.
    static let reassertDelay: TimeInterval = 1.0

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

    /// Which screens get a bar: the main display, or all of them.
    private func targetScreens(policy: DockDisplayPolicy) -> [NSScreen] {
        switch policy {
        case .main: return NSScreen.main.map { [$0] } ?? []
        case .perDisplay: return NSScreen.screens
        }
    }

    private func rebuildPanels() {
        for panel in panels { panel.dismiss() }
        panels = []
        magnifiers = []
        let current = settings()
        for screen in targetScreens(policy: current.displayPolicy) {
            let magnifier = DockMagnifier()
            let panel = DockPanel(model: model, magnifier: magnifier,
                                  edge: current.edge, screen: screen,
                                  settings: current)
            magnifier.attach(to: screen)
            panels.append(panel)
            magnifiers.append(magnifier)
            panel.present()
        }
    }

    isolated deinit {
        for panel in panels { panel.dismiss() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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
