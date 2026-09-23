import Foundation

/// The Dock utility's persisted state (docs/TOY-PARITY.md, "Dock").
/// One mode: **Enhance** keeps Apple's Dock and floats window
/// previews over it. The Replace bar was cut on 2026-09-15 — one dock
/// done well beats two done halfway — and its keys (`mode`, `edge`,
/// `pinned`, `magnification`, …) are ignored on decode.
///
/// Lives inside `UtilitiesState.dock` — `app-state.json`, never
/// `UserDefaults` — and decodes tolerantly at every level the way
/// `MenuBarSettings` does: a missing or mistyped key falls back to its
/// default and unknown keys are ignored, so an older or newer build
/// can share the file.
/// Who renders the dock utility (docs/TOY-PARITY.md): JR-Bar's own
/// Enhance watcher, or an installed counterpart handed the surface —
/// DockDoor (free) or ActiveDock (paid). An external pick parks our
/// watcher while the choice stands.
public enum DockProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, dockDoor, activeDock
}

public struct DockSettings: Codable, Equatable, Sendable {
    /// The card toggle.
    public var enabled: Bool
    /// Who draws the previews. `.jrbar` is the native watcher; anything
    /// else delegates to the named app and parks ours.
    public var provider: DockProvider
    /// The hover-preview knobs.
    public var enhance: DockEnhanceSettings
    /// Who owns the ⌥⇥ / ⌘⇥ chords — its own pick, so handing the
    /// previews to DockDoor no longer takes JR-Bar's switcher with them.
    public var switcherProvider: DockSwitcherProvider

    public init(enabled: Bool = false, provider: DockProvider = .jrbar,
                enhance: DockEnhanceSettings = DockEnhanceSettings(),
                switcherProvider: DockSwitcherProvider = .jrbar) {
        self.enabled = enabled
        self.provider = provider
        self.enhance = enhance
        self.switcherProvider = switcherProvider
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, enhance
        case switcherProvider
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        provider = (try? c.decodeIfPresent(DockProvider.self, forKey: .provider)) ?? .jrbar
        enhance = (try? c.decodeIfPresent(DockEnhanceSettings.self, forKey: .enhance)) ?? DockEnhanceSettings()
        switcherProvider = (try? c.decodeIfPresent(DockSwitcherProvider.self, forKey: .switcherProvider)) ?? .jrbar
    }

    /// Whether JR-Bar's own hover watcher should run: the card on,
    /// JR-Bar picked to render, and hover previews wanted.
    public var previewsWanted: Bool {
        enabled && provider == .jrbar && enhance.hoverPreviews
    }

    /// Whether JR-Bar's switcher chords should be live — independent of
    /// who renders the previews.
    public var switcherWanted: Bool {
        enabled && switcherProvider == .jrbar && (enhance.windowSwitcher || enhance.appSwitcher)
    }
}

/// Who answers ⌥⇥ and ⌘⇥: JR-Bar's own switcher, or an installed
/// counterpart the card hands the chords to (AltTab, Witch, Contexts).
/// A counterpart pick parks our chords — the tap still runs for the
/// preview's keys when the watcher is up.
public enum DockSwitcherProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, altTab, witch, contexts
}

/// The hover-preview knobs (docs/TOY-PARITY.md, "Dock — Enhance"):
/// how long the pointer must rest on an Apple-Dock icon before the
/// preview panel opens, whether the panel's cards carry live
/// `SCScreenshotManager` thumbnails or plain icon + title cards, the
/// card size, whether an auto-hiding Dock is held out while the panel
/// is up, and the window count that switches cards to a compact list.
public struct DockEnhanceSettings: Codable, Equatable, Sendable {
    /// Seconds of rest before the preview opens — Apple's own ~250 ms.
    public var previewDelay: Double {
        didSet { previewDelay = Self.clampedDelay(previewDelay) }
    }
    /// Thumbnails (one capture per window when the preview opens) need
    /// Screen Recording; off is icon + title cards.
    public var showThumbnails: Bool
    /// Bigger cards — 208×130 instead of 144×90 — for people who read
    /// the thumbnail rather than the title.
    public var largePreviews: Bool
    /// Thumbnails for windows on other Spaces and minimized windows
    /// too; the cards list every window either way.
    public var includeOffscreenWindows: Bool
    /// While a preview is up, an auto-hiding Dock's `autohide` is
    /// switched off so the pointer can leave the icons for the cards —
    /// the DockDoor hold. Restored the moment the panel closes; a
    /// Dock that never hides needs no holding.
    public var holdDockOpen: Bool
    /// Past this many windows the panel switches from thumbnail cards
    /// to a compact title list (and skips captures entirely — the
    /// indicator-free path for a many-windowed app). 0 is never.
    public var compactListLimit: Int {
        didSet { compactListLimit = Self.clampedCompactLimit(compactListLimit) }
    }
    /// ⌥⇥ raises the centered window switcher — DockDoor's switcher,
    /// the chord AltTab made. Off leaves option-Tab to whatever app
    /// binds it.
    public var windowSwitcher: Bool
    /// ⌘⇥ raises the app switcher instead of the system's — DockDoor's
    /// Cmd-Tab replacement. Off by default: eating the system's own
    /// chord is aggressive, and an off day leaves the OS untouched.
    public var appSwitcher: Bool
    /// Bundle ids that never earn a preview — DockDoor's app filters.
    /// A tile whose app is listed here rests and opens nothing.
    public var excludedBundleIDs: [String]
    /// Resting on a Dock icon opens its preview. Off keeps the card on
    /// for the switcher alone — ⌥⇥ without hover panels.
    public var hoverPreviews: Bool
    /// The ⌥⇥ strip lists only the windows on the pointer's display.
    public var switcherThisDisplay: Bool
    /// A preview lists only the windows on the display its Dock is on.
    public var previewThisDisplay: Bool

    public static let delayRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultDelay: Double = 0.25
    public static let compactLimitRange: ClosedRange<Int> = 0...12
    public static let defaultCompactLimit: Int = 6

    public init(previewDelay: Double = DockEnhanceSettings.defaultDelay,
                showThumbnails: Bool = true,
                largePreviews: Bool = false,
                includeOffscreenWindows: Bool = true,
                holdDockOpen: Bool = true,
                compactListLimit: Int = DockEnhanceSettings.defaultCompactLimit,
                windowSwitcher: Bool = true,
                appSwitcher: Bool = false,
                excludedBundleIDs: [String] = [],
                hoverPreviews: Bool = true,
                switcherThisDisplay: Bool = false,
                previewThisDisplay: Bool = false) {
        self.previewDelay = Self.clampedDelay(previewDelay)
        self.showThumbnails = showThumbnails
        self.largePreviews = largePreviews
        self.includeOffscreenWindows = includeOffscreenWindows
        self.holdDockOpen = holdDockOpen
        self.compactListLimit = Self.clampedCompactLimit(compactListLimit)
        self.windowSwitcher = windowSwitcher
        self.appSwitcher = appSwitcher
        self.excludedBundleIDs = excludedBundleIDs
        self.hoverPreviews = hoverPreviews
        self.switcherThisDisplay = switcherThisDisplay
        self.previewThisDisplay = previewThisDisplay
    }

    static func clampedCompactLimit(_ value: Int) -> Int {
        min(compactLimitRange.upperBound, max(compactLimitRange.lowerBound, value))
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case previewDelay, showThumbnails, largePreviews, includeOffscreenWindows
        case holdDockOpen, compactListLimit, windowSwitcher, appSwitcher, excludedBundleIDs
        case hoverPreviews, switcherThisDisplay, previewThisDisplay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewDelay = Self.clampedDelay(
            (try? c.decodeIfPresent(Double.self, forKey: .previewDelay)) ?? Self.defaultDelay)
        showThumbnails = (try? c.decodeIfPresent(Bool.self, forKey: .showThumbnails)) ?? true
        largePreviews = (try? c.decodeIfPresent(Bool.self, forKey: .largePreviews)) ?? false
        includeOffscreenWindows = (try? c.decodeIfPresent(Bool.self, forKey: .includeOffscreenWindows)) ?? true
        holdDockOpen = (try? c.decodeIfPresent(Bool.self, forKey: .holdDockOpen)) ?? true
        compactListLimit = Self.clampedCompactLimit(
            (try? c.decodeIfPresent(Int.self, forKey: .compactListLimit)) ?? Self.defaultCompactLimit)
        windowSwitcher = (try? c.decodeIfPresent(Bool.self, forKey: .windowSwitcher)) ?? true
        appSwitcher = (try? c.decodeIfPresent(Bool.self, forKey: .appSwitcher)) ?? false
        excludedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)) ?? []
        hoverPreviews = (try? c.decodeIfPresent(Bool.self, forKey: .hoverPreviews)) ?? true
        switcherThisDisplay = (try? c.decodeIfPresent(Bool.self, forKey: .switcherThisDisplay)) ?? false
        previewThisDisplay = (try? c.decodeIfPresent(Bool.self, forKey: .previewThisDisplay)) ?? false
    }
}

/// The edge Apple's Dock hugs — read off its AX frame, never set.
/// `top` is deliberately absent — the menu bar owns that edge.
public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case bottom
    case left
    case right

    /// True for `bottom`: the row runs horizontally.
    public var isHorizontal: Bool { self == .bottom }
}
