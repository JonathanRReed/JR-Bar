import Foundation

/// The Dock utility's persisted state (docs/TOY-PARITY.md, "Dock —
/// Replace mode"). The parity matrix gives the utility two modes:
/// **Enhance** keeps Apple's Dock and is a later phase; **Replace**
/// draws JR-Bar's own bar — the only mode this build implements. The
/// field is stored now so the enhance rows land without a schema
/// change.
///
/// Lives inside `UtilitiesState.dock` — `app-state.json`, never
/// `UserDefaults` — and decodes tolerantly at every level the way
/// `MenuBarSettings` does: a missing or mistyped key falls back to its
/// default and unknown keys are ignored, so an older or newer build
/// can share the file.
public struct DockSettings: Codable, Equatable, Sendable {
    /// The card toggle.
    public var enabled: Bool
    /// `enhance` keeps Apple's Dock (not yet built); `replace` draws
    /// our own bar. Defaults to `replace`, the working half — an
    /// enabled card must show something.
    public var mode: DockMode
    /// The screen edge the bar hugs.
    public var edge: DockEdge
    /// One bar on the main display, or one per display.
    public var displayPolicy: DockDisplayPolicy
    /// Icon point size at rest.
    public var iconSize: Double
    /// The pointer-proximity wave.
    public var magnification: DockMagnification
    /// The bar's backing material.
    public var material: DockMaterial
    /// A floating pill off the edge, or a band running the full edge.
    public var style: DockBarStyle
    /// `#RRGGBB` tint over the material; nil is the system look.
    /// Always stored canonical (`#RRGGBB`) — init and decode normalize,
    /// and a direct assignment goes through the same normalization via
    /// the observer (assignment inside `didSet` does not re-fire it).
    public var tintHex: String? {
        didSet { tintHex = tintHex.flatMap(normalizedColorHex) }
    }
    /// Slide off the edge after a delay; a pointer at the edge reveals.
    public var autoHide: DockAutoHide
    /// What marks a running app under its icon.
    public var runningIndicator: DockRunningIndicator
    /// Pinned apps, in dock order, by bundle id.
    public var pinned: [String]
    /// Whether the Finder tile shows. Finder is always running, so off
    /// drops it from the bar entirely; the pin list is kept so turning
    /// it back on restores the tile.
    public var showFinder: Bool
    /// Set once the `com.apple.dock` `persistent-apps` seed ran. The
    /// migration is one-shot — clearing this would re-seed over a pin
    /// list the user has since edited.
    public var seededFromAppleDock: Bool
    /// Folder-stack tiles, in dock order, by absolute path (P2). A
    /// path that doesn't exist right now just doesn't draw — the pin
    /// survives an ejected disk.
    public var folders: [String]
    /// The file tray's parked items, absolute paths in parked order
    /// (P3). Same deal: a missing file keeps its slot, skips its tile.
    public var tray: [String]
    /// The dock-widget toggles — clock face, battery tile (P4).
    public var widgets: DockWidgetSettings
    /// Enhance mode's knobs — the hover delay and whether previews
    /// capture live window thumbnails.
    public var enhance: DockEnhanceSettings

    /// The card's size dial.
    public static let iconSizeRange: ClosedRange<Double> = 24...96
    /// The default rest size — a touch under Apple's 64 so the bar
    /// reads as ours.
    public static let defaultIconSize: Double = 56

    public init(enabled: Bool = false, mode: DockMode = .replace, edge: DockEdge = .bottom,
                displayPolicy: DockDisplayPolicy = .main,
                iconSize: Double = DockSettings.defaultIconSize,
                magnification: DockMagnification = DockMagnification(),
                material: DockMaterial = .glass, style: DockBarStyle = .floating,
                tintHex: String? = nil, autoHide: DockAutoHide = DockAutoHide(),
                runningIndicator: DockRunningIndicator = .dot,
                pinned: [String] = [], showFinder: Bool = true,
                seededFromAppleDock: Bool = false,
                folders: [String] = [], tray: [String] = [],
                widgets: DockWidgetSettings = DockWidgetSettings(),
                enhance: DockEnhanceSettings = DockEnhanceSettings()) {
        self.enabled = enabled
        self.mode = mode
        self.edge = edge
        self.displayPolicy = displayPolicy
        self.iconSize = Self.clampedIconSize(iconSize)
        self.magnification = magnification
        self.material = material
        self.style = style
        self.tintHex = tintHex.flatMap(normalizedColorHex)
        self.autoHide = autoHide
        self.runningIndicator = runningIndicator
        self.pinned = Self.deduped(pinned)
        self.showFinder = showFinder
        self.seededFromAppleDock = seededFromAppleDock
        self.folders = Self.deduped(folders)
        self.tray = Self.deduped(tray)
        self.widgets = widgets
        self.enhance = enhance
    }

    static func clampedIconSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultIconSize }
        return min(iconSizeRange.upperBound, max(iconSizeRange.lowerBound, value))
    }

    /// Order kept, empties and repeats dropped — a pin with no bundle
    /// id can never resolve to an app. Public: the app target's
    /// `DockModel` shares it for the seed merge.
    public static func deduped(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, edge, displayPolicy, iconSize, magnification, material, style
        case tintHex, autoHide, runningIndicator, pinned, showFinder, seededFromAppleDock
        case folders, tray, widgets, enhance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        mode = (try? c.decodeIfPresent(DockMode.self, forKey: .mode)) ?? .replace
        edge = (try? c.decodeIfPresent(DockEdge.self, forKey: .edge)) ?? .bottom
        displayPolicy = (try? c.decodeIfPresent(DockDisplayPolicy.self, forKey: .displayPolicy)) ?? .main
        iconSize = Self.clampedIconSize(
            (try? c.decodeIfPresent(Double.self, forKey: .iconSize)) ?? Self.defaultIconSize)
        magnification = (try? c.decodeIfPresent(DockMagnification.self, forKey: .magnification)) ?? DockMagnification()
        material = (try? c.decodeIfPresent(DockMaterial.self, forKey: .material)) ?? .glass
        style = (try? c.decodeIfPresent(DockBarStyle.self, forKey: .style)) ?? .floating
        let rawTint = (try? c.decodeIfPresent(String.self, forKey: .tintHex)) ?? nil
        tintHex = rawTint.flatMap(normalizedColorHex)
        autoHide = (try? c.decodeIfPresent(DockAutoHide.self, forKey: .autoHide)) ?? DockAutoHide()
        runningIndicator = (try? c.decodeIfPresent(DockRunningIndicator.self, forKey: .runningIndicator)) ?? .dot
        pinned = Self.deduped((try? c.decodeIfPresent([String].self, forKey: .pinned)) ?? [])
        showFinder = (try? c.decodeIfPresent(Bool.self, forKey: .showFinder)) ?? true
        seededFromAppleDock = (try? c.decodeIfPresent(Bool.self, forKey: .seededFromAppleDock)) ?? false
        folders = Self.deduped((try? c.decodeIfPresent([String].self, forKey: .folders)) ?? [])
        tray = Self.deduped((try? c.decodeIfPresent([String].self, forKey: .tray)) ?? [])
        widgets = (try? c.decodeIfPresent(DockWidgetSettings.self, forKey: .widgets)) ?? DockWidgetSettings()
        enhance = (try? c.decodeIfPresent(DockEnhanceSettings.self, forKey: .enhance)) ?? DockEnhanceSettings()
    }
}

/// The two dock-widget toggles (docs/TOY-PARITY.md, Replace P4): a
/// clock face and a battery tile parked at the bar's file end. Both
/// off by default — a tile the user never asked for is clutter, not
/// a feature.
public struct DockWidgetSettings: Codable, Equatable, Sendable {
    /// The analog clock tile.
    public var clock: Bool
    /// The internal battery's charge tile — shows "no battery" on a
    /// desktop rather than inventing one.
    public var battery: Bool

    public init(clock: Bool = false, battery: Bool = false) {
        self.clock = clock
        self.battery = battery
    }

    private enum CodingKeys: String, CodingKey { case clock, battery }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clock = (try? c.decodeIfPresent(Bool.self, forKey: .clock)) ?? false
        battery = (try? c.decodeIfPresent(Bool.self, forKey: .battery)) ?? false
    }
}

/// Enhance mode's knobs (docs/TOY-PARITY.md, "Dock — Enhance mode"):
/// how long the pointer must rest on an Apple-Dock icon before the
/// preview panel opens, and whether the panel's rows carry live
/// `SCScreenshotManager` thumbnails or plain icon + title rows.
public struct DockEnhanceSettings: Codable, Equatable, Sendable {
    /// Seconds of rest before the preview opens — Apple's own ~250 ms.
    public var previewDelay: Double {
        didSet { previewDelay = Self.clampedDelay(previewDelay) }
    }
    /// Live thumbnails need Screen Recording; off is icon + title rows.
    public var showThumbnails: Bool

    public static let delayRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultDelay: Double = 0.25

    public init(previewDelay: Double = DockEnhanceSettings.defaultDelay,
                showThumbnails: Bool = true) {
        self.previewDelay = Self.clampedDelay(previewDelay)
        self.showThumbnails = showThumbnails
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey { case previewDelay, showThumbnails }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewDelay = Self.clampedDelay(
            (try? c.decodeIfPresent(Double.self, forKey: .previewDelay)) ?? Self.defaultDelay)
        showThumbnails = (try? c.decodeIfPresent(Bool.self, forKey: .showThumbnails)) ?? true
    }
}

/// Which Dock utility is on. `enhance` keeps Apple's Dock and floats
/// hover previews over it; `replace` draws our own bar.
public enum DockMode: String, Codable, CaseIterable, Sendable {
    case enhance
    case replace
}

/// The edge the bar anchors to. `top` is deliberately absent — the
/// menu bar owns that edge.
public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case bottom
    case left
    case right

    /// True for `bottom`: the row runs horizontally.
    public var isHorizontal: Bool { self == .bottom }
}

/// Where bars are drawn: a single bar following the main display, or
/// one bar on every attached display (DockDoor Pro's per-display row).
public enum DockDisplayPolicy: String, Codable, CaseIterable, Sendable {
    case main
    case perDisplay
}

/// The bar's backing. `glass` is `NSGlassEffectView` — the bar floats,
/// so the material rule allows it; `frosted` is a behind-window
/// `NSVisualEffectView`; `solid` is a flat fill (tinted); `clear`
/// keeps only a faint edge so the icons appear to sit on the desktop.
public enum DockMaterial: String, Codable, CaseIterable, Sendable {
    case glass
    case frosted
    case solid
    case clear
}

/// `floating` is a pill hugging the edge with margin; `fullWidth`
/// stretches the bar edge to edge.
public enum DockBarStyle: String, Codable, CaseIterable, Sendable {
    case floating
    case fullWidth
}

/// How the utility writes itself away when asked to hide.
public struct DockAutoHide: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Seconds the pointer must be off the bar before it slides away.
    public var delay: Double

    public static let delayRange: ClosedRange<Double> = 0...5
    public static let defaultDelay: Double = 0.5

    /// On by default — a replacement dock that never leaves the screen
    /// is a billboard, not a dock. A persisted `false` still decodes
    /// false; this is the new-install default.
    public init(enabled: Bool = true, delay: Double = DockAutoHide.defaultDelay) {
        self.enabled = enabled
        self.delay = Self.clampedDelay(delay)
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey { case enabled, delay }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        delay = Self.clampedDelay(
            (try? c.decodeIfPresent(Double.self, forKey: .delay)) ?? Self.defaultDelay)
    }
}

/// The mark under a running app's icon: `dot` is Apple's pellet,
/// `card` is a small rounded tile (DockDoor Pro's "card"), `none`
/// keeps the row clean.
public enum DockRunningIndicator: String, Codable, CaseIterable, Sendable {
    case dot
    case card
    case none
}

/// The magnification setting plus the wave itself. `scale` is the icon
/// multiplier under the pointer; `reach` is how many points from the
/// pointer the wave still lifts an icon.
public struct DockMagnification: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var scale: Double
    public var reach: Double

    public static let scaleRange: ClosedRange<Double> = 1...2.5
    public static let reachRange: ClosedRange<Double> = 40...400
    public static let defaultScale: Double = 1.6
    public static let defaultReach: Double = 140

    public init(enabled: Bool = false, scale: Double = DockMagnification.defaultScale,
                reach: Double = DockMagnification.defaultReach) {
        self.enabled = enabled
        self.scale = Self.clampedScale(scale)
        self.reach = Self.clampedReach(reach)
    }

    static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultScale }
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
    }

    static func clampedReach(_ value: Double) -> Double {
        guard value.isFinite else { return defaultReach }
        return min(reachRange.upperBound, max(reachRange.lowerBound, value))
    }

    /// The wave shape: a cosine ease that is `scale` under the pointer
    /// and decays to 1 at `reach`. Pure — the display-link driver calls
    /// this per icon per frame; the tests pin the curve.
    ///
    /// - `distance`: points from the pointer to the icon's centre along
    ///   the dock axis.
    /// - `scale`: the peak multiplier (1 is a flat bar whatever the
    ///   distance).
    /// - `reach`: the falloff in points; at or past it the factor is 1.
    public static func magnificationFactor(distance: Double, scale: Double, reach: Double) -> Double {
        guard scale > 1, reach > 0, distance.isFinite else { return 1 }
        let d = abs(distance)
        guard d < reach else { return 1 }
        return 1 + (scale - 1) * cos((d / reach) * .pi / 2)
    }

    private enum CodingKeys: String, CodingKey { case enabled, scale, reach }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        scale = Self.clampedScale(
            (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? Self.defaultScale)
        reach = Self.clampedReach(
            (try? c.decodeIfPresent(Double.self, forKey: .reach)) ?? Self.defaultReach)
    }
}
