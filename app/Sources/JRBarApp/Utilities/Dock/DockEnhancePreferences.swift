import AppKit
import JRBarCore

// MARK: - Preferences

/// Enhance mode's knobs — a facade over `DockSettings.enhance`, which
/// lives in `app-state.json` like every other Dock knob. `DockUtility`
/// wires `read`/`write` to its settings closure and `update` path, so
/// a card edit persists through the store's debounce and re-applies.
///
/// Builds that predate the schema wrote two `UserDefaults` keys
/// instead; `DockUtility` folds them into the settings once (see
/// `migrateLegacyEnhanceDefaults`) and removes them.
@MainActor
final class DockEnhancePreferences {
    /// The live settings read — wired to `DockUtility.settings`.
    var read: @MainActor () -> DockEnhanceSettings = { DockEnhanceSettings() }
    /// The card's write path — wired to `DockUtility.update`.
    var write: (@MainActor (DockEnhanceSettings) -> Void)?

    /// Seconds the pointer must rest on a Dock icon before the preview
    /// opens — Apple's own ~250 ms hover feel.
    var previewDelay: Double {
        get { read().previewDelay }
        set { write?({ var s = read(); s.previewDelay = newValue; return s }()) }
    }
    /// Live window thumbnails via one-shot `SCScreenshotManager`
    /// captures; off falls back to icon + title cards and needs no
    /// Screen Recording permission.
    var showThumbnails: Bool {
        get { read().showThumbnails }
        set { write?({ var s = read(); s.showThumbnails = newValue; return s }()) }
    }
    /// Bigger cards.
    var largePreviews: Bool {
        get { read().largePreviews }
        set { write?({ var s = read(); s.largePreviews = newValue; return s }()) }
    }
    /// Windows on other Spaces and minimized windows list too.
    var includeOffscreenWindows: Bool {
        get { read().includeOffscreenWindows }
        set { write?({ var s = read(); s.includeOffscreenWindows = newValue; return s }()) }
    }
    /// Hold an auto-hiding Dock out while a preview is up.
    var holdDockOpen: Bool {
        get { read().holdDockOpen }
        set { write?({ var s = read(); s.holdDockOpen = newValue; return s }()) }
    }
    /// Past this count the panel lists titles instead of thumbnails.
    var compactListLimit: Int {
        get { read().compactListLimit }
        set { write?({ var s = read(); s.compactListLimit = newValue; return s }()) }
    }
    /// ⌥⇥ raises the window switcher.
    var windowSwitcher: Bool {
        get { read().windowSwitcher }
        set { write?({ var s = read(); s.windowSwitcher = newValue; return s }()) }
    }
    /// ⌘⇥ raises the app switcher instead of the system's — off by
    /// default, it eats the OS's own chord.
    var appSwitcher: Bool {
        get { read().appSwitcher }
        set { write?({ var s = read(); s.appSwitcher = newValue; return s }()) }
    }
    /// Bundle ids that never earn a preview.
    var excludedBundleIDs: [String] {
        get { read().excludedBundleIDs }
        set { write?({ var s = read(); s.excludedBundleIDs = newValue; return s }()) }
    }
    /// Resting on a Dock icon opens a preview at all.
    var hoverPreviews: Bool {
        get { read().hoverPreviews }
        set { write?({ var s = read(); s.hoverPreviews = newValue; return s }()) }
    }
    /// ⌥⇥ lists only the pointer's display.
    var switcherThisDisplay: Bool {
        get { read().switcherThisDisplay }
        set { write?({ var s = read(); s.switcherThisDisplay = newValue; return s }()) }
    }
    /// A preview lists only the windows on its Dock's display.
    var previewThisDisplay: Bool {
        get { read().previewThisDisplay }
        set { write?({ var s = read(); s.previewThisDisplay = newValue; return s }()) }
    }
    /// What opens a preview — a rest, a rest with ⌥, or a middle click.
    var previewTrigger: DockPreviewTrigger {
        get { read().previewTrigger }
        set { write?({ var s = read(); s.previewTrigger = newValue; return s }()) }
    }
    /// Scroll up on an icon previews it at once; down hides the app.
    var scrollGestures: Bool {
        get { read().scrollGestures }
        set { write?({ var s = read(); s.scrollGestures = newValue; return s }()) }
    }
    /// ⌥` previews the front app from its Dock tile.
    var frontAppChord: Bool {
        get { read().frontAppChord }
        set { write?({ var s = read(); s.frontAppChord = newValue; return s }()) }
    }
    /// The card under the pointer plays live — the recording dot stays
    /// on while it does.
    var liveCard: Bool {
        get { read().liveCard }
        set { write?({ var s = read(); s.liveCard = newValue; return s }()) }
    }
    /// Clicking the front app's own Dock icon minimizes its windows.
    var clickToMinimize: Bool {
        get { read().clickToMinimize }
        set { write?({ var s = read(); s.clickToMinimize = newValue; return s }()) }
    }

    static let delayRange: ClosedRange<Double> = DockEnhanceSettings.delayRange
    static let defaultDelay: Double = DockEnhanceSettings.defaultDelay
    /// The pre-schema `UserDefaults` keys, kept for the one-shot
    /// migration `DockUtility.migrateLegacyEnhanceDefaults` runs.
    static let legacyDelayKey = "JRBarDock.enhance.previewDelay"
    static let legacyThumbnailsKey = "JRBarDock.enhance.thumbnails"
}
