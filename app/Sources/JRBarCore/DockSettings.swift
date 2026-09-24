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
        // A blob from before the split has no switcher pick: back then
        // an external renderer parked the whole card, ⌥⇥ included, so
        // DockDoor's own switcher answered it. That stays true until the
        // pick is made — an upgrade never starts a tap nobody chose.
        if let picked = try? c.decodeIfPresent(DockSwitcherProvider.self, forKey: .switcherProvider) {
            switcherProvider = picked
        } else {
            switcherProvider = DockSwitcherProvider.legacy(for: provider)
        }
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

/// Who answers ⌥⇥ and ⌘⇥: JR-Bar's own switcher, an installed
/// counterpart the card hands the chords to (AltTab, DockDoor, Witch,
/// Contexts), or nobody of ours — `off` leaves both chords to macOS and
/// whatever else binds them. Any pick but `jrbar` parks our chords; the
/// tap still runs for the preview's keys when the watcher is up.
public enum DockSwitcherProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, altTab, dockDoor, witch, contexts, off

    /// The pick a pre-split blob implies from its renderer: JR-Bar kept
    /// its chords, DockDoor answered ⌥⇥ with its own switcher, and
    /// ActiveDock's pick left the chords to nobody of ours.
    public static func legacy(for renderer: DockProvider) -> DockSwitcherProvider {
        switch renderer {
        case .jrbar: return .jrbar
        case .dockDoor: return .dockDoor
        case .activeDock: return .off
        }
    }
}

/// One remembered switcher pick — Contexts' Fast Search: a short query
/// and the window (app name + title stem) it last landed on, so the same
/// query ranks that window first next time. Local, in `app-state.json`
/// only; the card's Forget clears the list.
public struct DockLearnedPick: Codable, Equatable, Sendable {
    public var query: String
    public var pick: String

    public init(query: String, pick: String) {
        self.query = query
        self.pick = pick
    }
}

/// What opens a Dock preview — DockDoor 1.39.5's trigger modes. Hover
/// is the rest-on-an-icon default; the other two make it deliberate for
/// anyone who finds hover panels noisy while aiming at the Dock.
public enum DockPreviewTrigger: String, Codable, CaseIterable, Sendable {
    /// Rest on an icon for the delay.
    case hover
    /// Rest on an icon while ⌥ is held.
    case optionHover
    /// Middle-click an icon — Apple's Dock ignores that button.
    case middleClick
}

/// How the ⌥⇥ strip orders its windows.
public enum DockSwitcherOrder: String, Codable, CaseIterable, Sendable {
    /// The most recent window first — the window server's z-order.
    case recent
    /// Each app's windows together, the apps in the order of their most
    /// recent window — Witch's and AltTab's grouped strip.
    case byApp
}

/// What the ⌥⇥ strip's cards show.
public enum DockSwitcherStyle: String, Codable, CaseIterable, Sendable {
    /// Each window's still, over its app's icon — captures, like the
    /// previews' thumbnails.
    case stills
    /// The app's icon only: no capture, so no recording dot.
    case icons
}

/// The preview's named spacing stops. The stored value is the scale
/// itself, so a fine-tuned 0.85 sits between stops and the card calls
/// it Custom. Tight is the default; Standard is the look before the
/// 2026-09-24 pass (bar a concentric glass corner); Roomy is the old
/// air and then some.
public enum DockPreviewSpacing: String, CaseIterable, Sendable {
    case tight, standard, roomy

    /// The scale this stop stores.
    public var scale: Double {
        switch self {
        case .tight: return 0.6
        case .standard: return 1.0
        case .roomy: return 1.4
        }
    }

    /// The stop's name on the card's segmented control.
    public var title: String {
        switch self {
        case .tight: return "Tight"
        case .standard: return "Standard"
        case .roomy: return "Roomy"
        }
    }

    /// The stop `scale` sits on, or nil when it sits between stops.
    public static func stop(for scale: Double) -> DockPreviewSpacing? {
        allCases.first { abs($0.scale - scale) < 0.001 }
    }
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
    /// What opens a preview: a rest (the default), a rest with ⌥ held,
    /// or a middle click on the icon.
    public var previewTrigger: DockPreviewTrigger
    /// Scrolling on a Dock icon: up opens its preview at once, down
    /// hides the app — HyperDock's classic. Off by default.
    public var scrollGestures: Bool
    /// Clicking the front app's own Dock icon minimizes its windows —
    /// the Windows-taskbar habit DockDoor offers. Off by default.
    public var clickToMinimize: Bool
    /// The switcher's learned type-ahead, most recent first.
    public var learnedPicks: [DockLearnedPick]
    /// The card under the pointer plays live (one stream on that one
    /// window) instead of showing a still — AltTab's and DockDoor's
    /// live previews, at the cost of macOS's recording dot staying on
    /// while it plays. Off by default.
    public var liveCard: Bool
    /// ⌥` opens the front app's preview on its Dock tile with the first
    /// card walked — the keyboard walk with no pointer at all. Off by
    /// default: it takes the accent key ⌥` types on US layouts.
    public var frontAppChord: Bool
    /// How much air the preview keeps inside its glass: one scale for
    /// every inset, gap and corner (`DockPreviewMetrics`), and the ⌥⇥
    /// switcher's too. 0.6 is Tight, the default; 1.0 is Standard.
    public var previewSpacing: Double {
        didSet { previewSpacing = Self.clampedSpacing(previewSpacing) }
    }
    /// Points between the Dock icon's edge and the preview's glass —
    /// DockDoor's buffer from the Dock. Four by default, so the preview
    /// reads as the icon's own.
    public var dockGap: Double {
        didSet { dockGap = Self.clampedDockGap(dockGap) }
    }
    /// The preview rides above the Dock and covers the name bubble the
    /// Dock draws over a hovered icon — the header already names the
    /// app. Off, it sits under the Dock's level and keeps a band clear
    /// for the bubble, the look before this setting.
    public var coverDockLabel: Bool
    /// Each card takes its window's shape — a tall window a narrow card,
    /// a wide one a wide card — with the still filling it, instead of a
    /// 16:10 box that letterboxes anything else. Off by default.
    public var cardsHugWindows: Bool
    /// The ⌥⇥ strip's order: most recent window first (the default), or
    /// grouped by app.
    public var switcherOrder: DockSwitcherOrder
    /// Running apps with no open window get a card of their own at the
    /// strip's end. Off by default — the strip lists windows.
    public var switcherShowsWindowless: Bool
    /// The strip's card faces: window stills (the default) or app icons.
    public var switcherStyle: DockSwitcherStyle

    public static let delayRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultDelay: Double = 0.25
    public static let compactLimitRange: ClosedRange<Int> = 0...12
    public static let defaultCompactLimit: Int = 6
    public static let spacingRange: ClosedRange<Double> = 0.5...1.6
    public static let defaultSpacing: Double = DockPreviewSpacing.tight.scale
    public static let dockGapRange: ClosedRange<Double> = 0...40
    public static let defaultDockGap: Double = 4

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
                previewThisDisplay: Bool = false,
                previewTrigger: DockPreviewTrigger = .hover,
                scrollGestures: Bool = false,
                clickToMinimize: Bool = false,
                learnedPicks: [DockLearnedPick] = [],
                liveCard: Bool = false,
                frontAppChord: Bool = false,
                previewSpacing: Double = DockEnhanceSettings.defaultSpacing,
                dockGap: Double = DockEnhanceSettings.defaultDockGap,
                coverDockLabel: Bool = true,
                cardsHugWindows: Bool = false,
                switcherOrder: DockSwitcherOrder = .recent,
                switcherShowsWindowless: Bool = false,
                switcherStyle: DockSwitcherStyle = .stills) {
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
        self.previewTrigger = previewTrigger
        self.scrollGestures = scrollGestures
        self.clickToMinimize = clickToMinimize
        self.learnedPicks = learnedPicks
        self.liveCard = liveCard
        self.frontAppChord = frontAppChord
        self.previewSpacing = Self.clampedSpacing(previewSpacing)
        self.dockGap = Self.clampedDockGap(dockGap)
        self.coverDockLabel = coverDockLabel
        self.cardsHugWindows = cardsHugWindows
        self.switcherOrder = switcherOrder
        self.switcherShowsWindowless = switcherShowsWindowless
        self.switcherStyle = switcherStyle
    }

    static func clampedCompactLimit(_ value: Int) -> Int {
        min(compactLimitRange.upperBound, max(compactLimitRange.lowerBound, value))
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, value))
    }

    /// A spacing off the scale's ends lands on the nearer end; a value
    /// that isn't a number is the default.
    static func clampedSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpacing }
        return min(spacingRange.upperBound, max(spacingRange.lowerBound, value))
    }

    static func clampedDockGap(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDockGap }
        return min(dockGapRange.upperBound, max(dockGapRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case previewDelay, showThumbnails, largePreviews, includeOffscreenWindows
        case holdDockOpen, compactListLimit, windowSwitcher, appSwitcher, excludedBundleIDs
        case hoverPreviews, switcherThisDisplay, previewThisDisplay
        case previewTrigger, scrollGestures, clickToMinimize, learnedPicks, liveCard
        case frontAppChord
        case previewSpacing, dockGap, coverDockLabel
        case cardsHugWindows
        case switcherOrder, switcherShowsWindowless, switcherStyle
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
        previewTrigger = (try? c.decodeIfPresent(DockPreviewTrigger.self, forKey: .previewTrigger)) ?? .hover
        scrollGestures = (try? c.decodeIfPresent(Bool.self, forKey: .scrollGestures)) ?? false
        clickToMinimize = (try? c.decodeIfPresent(Bool.self, forKey: .clickToMinimize)) ?? false
        learnedPicks = (try? c.decodeIfPresent([DockLearnedPick].self, forKey: .learnedPicks)) ?? []
        liveCard = (try? c.decodeIfPresent(Bool.self, forKey: .liveCard)) ?? false
        frontAppChord = (try? c.decodeIfPresent(Bool.self, forKey: .frontAppChord)) ?? false
        previewSpacing = Self.clampedSpacing(
            (try? c.decodeIfPresent(Double.self, forKey: .previewSpacing)) ?? Self.defaultSpacing)
        dockGap = Self.clampedDockGap(
            (try? c.decodeIfPresent(Double.self, forKey: .dockGap)) ?? Self.defaultDockGap)
        coverDockLabel = (try? c.decodeIfPresent(Bool.self, forKey: .coverDockLabel)) ?? true
        cardsHugWindows = (try? c.decodeIfPresent(Bool.self, forKey: .cardsHugWindows)) ?? false
        switcherOrder = (try? c.decodeIfPresent(DockSwitcherOrder.self, forKey: .switcherOrder)) ?? .recent
        switcherShowsWindowless = (try? c.decodeIfPresent(Bool.self, forKey: .switcherShowsWindowless)) ?? false
        switcherStyle = (try? c.decodeIfPresent(DockSwitcherStyle.self, forKey: .switcherStyle)) ?? .stills
    }
}

/// The edge Apple's Dock hugs — read off its AX frame, never set.
/// `top` is deliberately absent — the menu bar owns that edge.
public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case bottom
    case left
    case right
}
