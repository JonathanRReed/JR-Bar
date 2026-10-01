import Foundation

/// The remembered state of everything on the Utilities page: the
/// serious half of JR-Bar — features that manage the Mac's own
/// surfaces rather than play on them (docs/UTILITIES.md). Lives inside
/// `AppState.utilities` — `app-state.json`, never `UserDefaults` — and
/// decodes tolerantly at every level the way `ToysState` does: a
/// missing or mistyped key falls back to its default and unknown keys
/// are ignored, so an older or newer build can share the file.
public struct UtilitiesState: Codable, Equatable, Sendable {
    /// The page's master switch. On by default so each card's own
    /// `enabled` is the only gate until a later phase puts a switch on
    /// the page itself.
    public var enabled: Bool
    /// The Menu Bar utility.
    public var menuBar: MenuBarSettings
    /// The Dock utility.
    public var dock: DockSettings
    /// The Agent Overview utility's card: per-provider alert rules and
    /// "quiet while you watch" (docs/UTILITIES.md).
    public var agents: AgentOverviewSettings
    public var dataHoarderEnabled: Bool
    /// The hoarder's capture dials — which sources stream in, whether full
    /// content is consented to, and the pause switch.
    public var dataHoarder: DataHoarderSettings
    /// What the ⌘⇧K palette has been used for — the frecency behind its
    /// Suggestions and its ranking. Per-Mac habit, so it rides the same
    /// file as the rest of the page's remembered state.
    public var commandUses: PaletteUsage = PaletteUsage()

    public init(enabled: Bool = true, menuBar: MenuBarSettings = MenuBarSettings(),
                dock: DockSettings = DockSettings(),
                agents: AgentOverviewSettings = AgentOverviewSettings(),
                dataHoarderEnabled: Bool = false,
                dataHoarder: DataHoarderSettings = DataHoarderSettings()) {
        self.enabled = enabled
        self.menuBar = menuBar
        self.dock = dock
        self.agents = agents
        self.dataHoarderEnabled = dataHoarderEnabled
        self.dataHoarder = dataHoarder
    }

    private enum CodingKeys: String, CodingKey { case enabled, menuBar, dock, agents, dataHoarderEnabled, dataHoarder
        case commandUses
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        menuBar = (try? c.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar)) ?? MenuBarSettings()
        dock = (try? c.decodeIfPresent(DockSettings.self, forKey: .dock)) ?? DockSettings()
        agents = (try? c.decodeIfPresent(AgentOverviewSettings.self, forKey: .agents)) ?? AgentOverviewSettings()
        dataHoarderEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dataHoarderEnabled)) ?? false
        dataHoarder = (try? c.decodeIfPresent(DataHoarderSettings.self, forKey: .dataHoarder)) ?? DataHoarderSettings()
        commandUses = (try? c.decodeIfPresent(PaletteUsage.self, forKey: .commandUses)) ?? PaletteUsage()
    }
}

/// The Data Hoarder's capture settings. `captureSources` maps source id →
/// "Capture new activity" — only listed ids run watchers, and nothing runs
/// while the utility is off or `paused` is set. `fullContent` is the
/// explicit prompt/response consent: off stores each segment's structural
/// redacted form instead.
public struct DataHoarderSettings: Codable, Equatable, Sendable {
    public var captureSources: [String: Bool]
    public var fullContent: Bool
    public var paused: Bool
    /// Days a trashed record is kept before the archive purges it. nil keeps
    /// trash forever — retention only ever deletes what the user deleted.
    public var trashRetentionDays: Int?
    /// Days of pre-existing files a source's first capture scan reads from
    /// their start; older files are only positioned, and everything after
    /// is followed live. nil reads nothing that predates the capture.
    public var backfillDays: Int?

    public init(captureSources: [String: Bool] = [:], fullContent: Bool = false,
                paused: Bool = false, trashRetentionDays: Int? = nil, backfillDays: Int? = nil) {
        self.captureSources = captureSources
        self.fullContent = fullContent
        self.paused = paused
        self.trashRetentionDays = trashRetentionDays
        self.backfillDays = backfillDays
    }

    public var enabledSources: [String] {
        captureSources.filter(\.value).map(\.key).sorted()
    }

    private enum CodingKeys: String, CodingKey { case captureSources, fullContent, paused, trashRetentionDays, backfillDays }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureSources = (try? c.decodeIfPresent([String: Bool].self, forKey: .captureSources)) ?? [:]
        fullContent = (try? c.decodeIfPresent(Bool.self, forKey: .fullContent)) ?? false
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        let days = (try? c.decodeIfPresent(Int.self, forKey: .trashRetentionDays)) ?? nil
        trashRetentionDays = (days ?? 0) > 0 ? days : nil
        let backfill = (try? c.decodeIfPresent(Int.self, forKey: .backfillDays)) ?? nil
        backfillDays = (backfill ?? 0) > 0 ? backfill : nil
    }
}

/// Which slice of the menu bar an item sits in (docs/UTILITIES.md):
/// `shown` stays up; `hidden` collapses behind the hidden-section
/// spacer until a reveal gesture; `alwaysHidden` is the deeper hide the
/// Item Bar panel alone reaches. Stored as the raw string so a newer
/// build's section names keep their data.
public enum MenuBarItemSection: String, Codable, CaseIterable, Sendable {
    case shown
    case hidden
    case alwaysHidden
}

/// The Menu Bar utility's persisted state: which item sits in which
/// section, how a hidden run is revealed, and how long it stays before
/// the spacer comes back.
/// Who renders the menu-bar utility (docs/TOY-PARITY.md): JR-Bar's own
/// engine, or an installed counterpart handed the surface — Bartender
/// (paid), Ice or Hidden Bar (free). An external pick parks our
/// machinery entirely while the choice stands.
public enum MenuBarProvider: String, Codable, CaseIterable, Sendable {
    case jrbar, bartender, ice, hiddenBar
}

public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Who draws the hiding. `.jrbar` is the native engine; anything
    /// else delegates to the named app and parks ours.
    public var provider: MenuBarProvider
    /// Item-identity string → section. An unlisted item is `shown`.
    /// Decoded tolerantly: an unknown section value (a newer build's, a
    /// hand edit) is dropped rather than carried or fatal.
    public var sections: [String: MenuBarItemSection]
    /// The pointer entering the menu bar row reveals the hidden run.
    public var revealOnHover: Bool
    /// A click on empty menu bar space — one that lands on no item
    /// frame — reveals it.
    public var revealOnClick: Bool
    /// A scroll or swipe over the menu bar reveals it.
    public var revealOnScroll: Bool
    /// Seconds a reveal lasts before the spacers stand back up —
    /// while `rehideMode` is `.timed`.
    public var rehideSeconds: Double
    /// How a reveal ends: on the `rehideSeconds` clock, or only when a
    /// click lands off the bar (Bartender's "show until clicked").
    public var rehideMode: RehideMode
    /// Where a reveal surfaces the hidden run — the Item Bar panel
    /// (Bartender) or inline on the row (Ice, Hidden Bar).
    public var revealStyle: RevealStyle
    /// Bartender Golden Gate's swap: while a reveal is out, the
    /// normally-shown items are covered too — the bar shows only the
    /// hidden run. Re-hide drops both and the stock split returns.
    public var hideShownWhileRevealing: Bool
    /// Which hiding model the section map was written under. Files
    /// from before `currentLayoutModel` carried a map that assigned
    /// every item hidden (the cover era); the position model reads
    /// the map as overrides only, so an older map is cleared once on
    /// first apply rather than turning every item into a hole.
    public var layoutModel: Int
    /// The shutter covers' visual-effect material — `.menu` is the look
    /// the utility shipped with (opaque over covered items, reads as
    /// ordinary empty menu bar).
    public var coverMaterial: CoverMaterial
    /// A "#RRGGBB" tint layered over the cover material; empty means
    /// the material alone.
    public var coverTint: String
    /// The tint's strength, 0…1. Ignored while `coverTint` is empty.
    public var coverTintOpacity: Double
    /// Corner radius on each cover run's ends — 0 is the plain bar.
    public var coverRoundness: Double
    /// A hairline drawn where a covered run meets visible menu bar.
    public var showCoverSeparator: Bool
    /// Named presets: a captured section map plus the cover appearance
    /// and control layout, applied wholesale through reconcile.
    public var profiles: [Profile]
    /// The global hotkeys. Empty means the shipping set
    /// (`MenuBarHotkeys.standard`) — the card materializes the list the
    /// first time a binding is toggled.
    public var hotkeyBindings: [MenuBarHotkeyBinding]
    /// The trigger rules — "when X, do Y" rows evaluated by the app's
    /// trigger engine.
    public var triggerRules: [MenuBarTriggerRule]
    /// The concealer's map (macOS 27): bundle identifier → hidden or
    /// always-hidden. An unlisted app is shown. Per application, not
    /// per item — the agent conceals by process, and it reorders the
    /// bar on its own, so a position can never be the setting.
    public var concealedApps: [String: MenuBarItemSection]
    /// Whether `concealedApps` was seeded once from the spacer model's
    /// plan — the apps left of the JR-Bar icon at the first run.
    public var concealSeeded: Bool
    /// Use the agent's concealment even from a build that is not
    /// notarized — where the agent hides JR-Bar's own icon along with
    /// the rest (measured: an allowlisted app stays only when it passes
    /// Gatekeeper). Off, an unnotarized build falls back to the spacer.
    public var concealUnnotarized: Bool
    /// The system-wide status-item gap — Bartender's "reduce spacing"
    /// verbatim (it writes NSStatusItemSpacing into the current-host
    /// global domain; items pick it up as they launch). 0 leaves the
    /// bar's own spacing alone.
    public var itemSpacing: Int
    /// Whether this build wrote the spacing keys — so choosing the
    /// system default again removes them instead of leaving a stale
    /// value behind.
    public var itemSpacingManaged: Bool
    /// Items drawn under the notch are unreachable — the plan hides
    /// them so the Item Bar lists them. Only acts when an item's frame
    /// actually intersects the notch band.
    public var hideUnderNotch: Bool
    /// Items the front app's menus overdraw are unreachable the same
    /// way: they plan hidden instead of sitting behind menu text.
    public var hideOnMenuOverlap: Bool
    /// Extra fixed-width status items carrying a text label — the
    /// spacer rows Bartender scatters through the bar. Each is born
    /// visible like the chevron; its click reveals the hidden run.
    public var spacers: [Spacer]
    /// A tint panel drawn under the whole menu bar row — the full-bar
    /// underlay, same material dials as the covers.
    public var barUnderlay: Bool
    /// A status item mirroring the agent feed's state dot; its click
    /// opens the Overview.
    public var agentStatusItem: Bool
    /// One status item standing in for the Control Center items it
    /// covers — battery, Wi-Fi, sound, Focus — whose system items are
    /// hidden through the Control Center defaults while this is on.
    public var combinedSystemItem: Bool
    /// Display number → profile name: the profile follows the screen
    /// the pointer is on.
    public var displayProfiles: [String: String]
    /// Bartender's signature: when a hidden item's title changes — a
    /// VPN's "Connected", a download's percent — the hidden run
    /// reveals for a beat so the update is seen, then re-hides.
    public var showForUpdates: Bool
    /// The layers over the curated maps — the runtime overlay, the
    /// active profile, the "while" rules — in one value
    /// (`MenuBarActionsModel.swift`).
    public var curation: MenuBarCuration = MenuBarCuration()

    /// The cover's visual-effect material, persisted as its raw name so
    /// a newer build's materials keep their data.
    public enum CoverMaterial: String, Codable, CaseIterable, Sendable {
        case blend
        case menu
        case hud
        case popover
        case sheet
    }

    /// Where a reveal puts the hidden run. `.bar` opens the Item Bar —
    /// Bartender's model: the menu bar itself never reflows, the
    /// concealment assertion holds, nothing flaps. `.inline` drops the
    /// covers so the run reflows onto the row — Ice and Hidden Bar's
    /// model.
    public enum RevealStyle: String, Codable, CaseIterable, Sendable {
        case bar
        case inline
    }

    /// What ends a reveal. `.timed` re-hides after `rehideSeconds`
    /// once the pointer leaves the surfaces; `.untilClick` keeps the
    /// run out until a click lands off the bar — Bartender's "show
    /// until clicked elsewhere".
    public enum RehideMode: String, Codable, CaseIterable, Sendable {
        case timed
        case untilClick
        /// Ice's "smart" rehide: the reveal folds when another app comes
        /// to the front, or a click lands off the bar.
        case focusChange
    }

    /// A named preset: the section map — and under the concealer the
    /// per-app concealment map — plus the cover's appearance, the
    /// reveal's style and clock, the item spacing and the spacer items,
    /// captured at save time. Triggers and hotkeys are deliberately
    /// not the profile's business — they are machine-local.
    public struct Profile: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var sections: [String: MenuBarItemSection]
        /// The concealer's map: bundle identifier → section. Profiles
        /// saved before the field existed decode to an empty map —
        /// applying one then leaves the concealed set alone no more
        /// than any other field it never carried.
        public var concealedApps: [String: MenuBarItemSection]
        public var coverMaterial: CoverMaterial
        public var coverTint: String
        public var coverTintOpacity: Double
        public var coverRoundness: Double
        public var showCoverSeparator: Bool
        /// Where a reveal surfaces the run — captured so a profile can
        /// carry "panel for work, inline for presentations".
        public var revealStyle: RevealStyle
        /// How a reveal ends and, for `.timed`, how long it lasts.
        public var rehideMode: RehideMode
        public var rehideSeconds: Double
        /// The system-wide status-item gap — 0 is the system default.
        public var itemSpacing: Int
        /// The labelled spacer items — they are layout, like the cover.
        public var spacers: [Spacer]

        public init(id: String, name: String,
                    sections: [String: MenuBarItemSection] = [:],
                    concealedApps: [String: MenuBarItemSection] = [:],
                    coverMaterial: MenuBarSettings.CoverMaterial = .blend,
                    coverTint: String = "",
                    coverTintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity,
                    coverRoundness: Double = 0,
                    showCoverSeparator: Bool = false,
                    revealStyle: RevealStyle = .bar,
                    rehideMode: RehideMode = .timed,
                    rehideSeconds: Double = MenuBarSettings.defaultRehideSeconds,
                    itemSpacing: Int = 0,
                    spacers: [Spacer] = []) {
            self.id = id
            self.name = name
            self.sections = sections
            self.concealedApps = concealedApps
            self.coverMaterial = coverMaterial
            self.coverTint = coverTint
            self.coverTintOpacity = MenuBarSettings.clampedOpacity(coverTintOpacity)
            self.coverRoundness = MenuBarSettings.clampedRoundness(coverRoundness)
            self.showCoverSeparator = showCoverSeparator
            self.revealStyle = revealStyle
            self.rehideMode = rehideMode
            self.rehideSeconds = MenuBarSettings.clampedRehide(rehideSeconds)
            self.itemSpacing = max(0, itemSpacing)
            self.spacers = spacers
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, sections, concealedApps, coverMaterial, coverTint
            case coverTintOpacity, coverRoundness, showCoverSeparator
            case revealStyle, rehideMode, rehideSeconds, itemSpacing, spacers
        }

        /// Tolerant like the settings themselves: a key a build never
        /// wrote reads as its default rather than dropping the profile,
        /// and keys an older build wrote that this one retired are
        /// ignored.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            let rawSections = (try? c.decodeIfPresent([String: String].self,
                                                      forKey: .sections)) ?? [:]
            sections = rawSections.compactMapValues { MenuBarItemSection(rawValue: $0) }
            let rawApps = (try? c.decodeIfPresent([String: String].self,
                                                  forKey: .concealedApps)) ?? [:]
            concealedApps = rawApps.compactMapValues { MenuBarItemSection(rawValue: $0) }
            coverMaterial = (try? c.decodeIfPresent(CoverMaterial.self,
                                                    forKey: .coverMaterial)) ?? .blend
            coverTint = (try? c.decodeIfPresent(String.self, forKey: .coverTint)) ?? ""
            coverTintOpacity = MenuBarSettings.clampedOpacity(
                (try? c.decodeIfPresent(Double.self, forKey: .coverTintOpacity))
                    ?? MenuBarSettings.defaultCoverTintOpacity)
            coverRoundness = MenuBarSettings.clampedRoundness(
                (try? c.decodeIfPresent(Double.self, forKey: .coverRoundness)) ?? 0)
            showCoverSeparator = (try? c.decodeIfPresent(Bool.self,
                                                         forKey: .showCoverSeparator)) ?? false
            revealStyle = (try? c.decodeIfPresent(RevealStyle.self,
                                                  forKey: .revealStyle)) ?? .bar
            rehideMode = (try? c.decodeIfPresent(RehideMode.self,
                                                 forKey: .rehideMode)) ?? .timed
            rehideSeconds = MenuBarSettings.clampedRehide(
                (try? c.decodeIfPresent(Double.self, forKey: .rehideSeconds))
                    ?? MenuBarSettings.defaultRehideSeconds)
            itemSpacing = max(0, (try? c.decodeIfPresent(Int.self, forKey: .itemSpacing)) ?? 0)
            spacers = (try? c.decodeIfPresent([Spacer].self, forKey: .spacers)) ?? []
        }
    }

    /// A spacer item: a fixed-width status item carrying a text label.
    /// `width` 0 hugs the label's own measure.
    public struct Spacer: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var width: Double

        public init(id: String = UUID().uuidString, label: String = "",
                    width: Double = 0) {
            self.id = id
            self.label = label
            self.width = max(0, width)
        }
    }

    /// The card's rehide dial.
    public static let rehideRange: ClosedRange<Double> = 1...15
    /// The card's custom-spacing dial — 0 is the system default, the
    /// presets live inside the range too.
    public static let itemSpacingRange: ClosedRange<Double> = 0...24
    /// The default reveal window.
    public static let defaultRehideSeconds: Double = 4
    /// The hiding model this build writes: 2 is positional sections
    /// with overrides; 0 (or absent with a map) is the cover era's
    /// all-covered map, cleared once on first apply.
    /// Model 3: the concealer's first-run seed hid whatever sat left of
    /// the boundary without asking — the map it wrote is cleared once,
    /// and nothing is concealed until the person picks or drags it.
    /// Model 4: the newcomer sweep is gone too — no bundle ever joins
    /// the map on its own. Cleared again so a seed-era map (and any
    /// auto-hid newcomers it gathered) resets to the stock bar.
    public static let currentLayoutModel = 4
    /// The card's cover-roundness dial — past half the row's depth the
    /// run ends are a pill anyway.
    public static let coverRoundnessRange: ClosedRange<Double> = 0...14
    /// The tint's default strength.
    public static let defaultCoverTintOpacity: Double = 0.35

    public init(enabled: Bool = true, provider: MenuBarProvider = .jrbar,
                sections: [String: MenuBarItemSection] = [:],
                revealOnHover: Bool = true, revealOnClick: Bool = true, revealOnScroll: Bool = true,
                rehideSeconds: Double = MenuBarSettings.defaultRehideSeconds,
                rehideMode: RehideMode = .timed,
                revealStyle: RevealStyle = .bar,
                hideShownWhileRevealing: Bool = false,
                layoutModel: Int = MenuBarSettings.currentLayoutModel,
                coverMaterial: CoverMaterial = .blend, coverTint: String = "",
                coverTintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity,
                coverRoundness: Double = 0, showCoverSeparator: Bool = false,
                profiles: [Profile] = [],
                hotkeyBindings: [MenuBarHotkeyBinding] = [],
                triggerRules: [MenuBarTriggerRule] = [],
                concealedApps: [String: MenuBarItemSection] = [:],
                concealSeeded: Bool = false,
                concealUnnotarized: Bool = false,
                itemSpacing: Int = 0,
                itemSpacingManaged: Bool = false,
                hideUnderNotch: Bool = true,
                hideOnMenuOverlap: Bool = true,
                spacers: [Spacer] = [],
                barUnderlay: Bool = false,
                agentStatusItem: Bool = false,
                combinedSystemItem: Bool = false,
                displayProfiles: [String: String] = [:],
                showForUpdates: Bool = false) {
        self.enabled = enabled
        self.provider = provider
        self.sections = sections
        self.revealOnHover = revealOnHover
        self.revealOnClick = revealOnClick
        self.revealOnScroll = revealOnScroll
        self.rehideSeconds = Self.clampedRehide(rehideSeconds)
        self.rehideMode = rehideMode
        self.revealStyle = revealStyle
        self.hideShownWhileRevealing = hideShownWhileRevealing
        self.layoutModel = layoutModel
        self.coverMaterial = coverMaterial
        self.coverTint = coverTint
        self.coverTintOpacity = Self.clampedOpacity(coverTintOpacity)
        self.coverRoundness = Self.clampedRoundness(coverRoundness)
        self.showCoverSeparator = showCoverSeparator
        self.profiles = profiles
        self.hotkeyBindings = hotkeyBindings
        self.triggerRules = triggerRules
        self.concealedApps = concealedApps
        self.concealSeeded = concealSeeded
        self.concealUnnotarized = concealUnnotarized
        self.itemSpacing = max(0, itemSpacing)
        self.itemSpacingManaged = itemSpacingManaged
        self.hideUnderNotch = hideUnderNotch
        self.hideOnMenuOverlap = hideOnMenuOverlap
        self.spacers = spacers
        self.barUnderlay = barUnderlay
        self.agentStatusItem = agentStatusItem
        self.combinedSystemItem = combinedSystemItem
        self.displayProfiles = displayProfiles
        self.showForUpdates = showForUpdates
    }

    static func clampedRehide(_ value: Double) -> Double {
        guard value.isFinite else { return defaultRehideSeconds }
        return min(rehideRange.upperBound, max(rehideRange.lowerBound, value))
    }

    /// The tint's strength pinned to 0…1.
    public static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultCoverTintOpacity }
        return min(1, max(0, value))
    }

    /// The cover's end rounding pinned to the dial.
    public static func clampedRoundness(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(coverRoundnessRange.upperBound, max(coverRoundnessRange.lowerBound, value))
    }

    /// The section an item sits in; unlisted is shown.
    public func section(for itemID: String) -> MenuBarItemSection {
        sections[itemID] ?? .shown
    }

    /// One array element that swallows its own decode failure — a rule
    /// written by a newer build with a case this one doesn't know drops
    /// itself, not the whole list it rode in with.
    private struct LossyElement<Element: Decodable>: Decodable {
        let value: Element?
        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, sections, revealOnHover, revealOnClick, revealOnScroll, rehideSeconds, rehideMode, revealStyle, hideShownWhileRevealing, layoutModel
        case coverMaterial, coverTint, coverTintOpacity, coverRoundness, showCoverSeparator
        case profiles, hotkeyBindings, triggerRules
        case concealedApps, concealSeeded, concealUnnotarized, itemSpacing, itemSpacingManaged
        case hideUnderNotch, hideOnMenuOverlap, spacers, barUnderlay
        case agentStatusItem, combinedSystemItem, displayProfiles, showForUpdates
        case curation
        // Retired keys — e.g. `combinedStatusItem`, replaced by
        // `combinedSystemItem`, and the old Arrange action's
        // `arrangeOrder` — are simply unlisted: decode ignores them,
        // encode never writes them.
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The utility is on by default — the icon is the boundary from
        // the first launch; an explicit `false` is still honoured.
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        provider = (try? c.decodeIfPresent(MenuBarProvider.self, forKey: .provider)) ?? .jrbar
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .sections)) ?? [:]
        sections = raw.compactMapValues { MenuBarItemSection(rawValue: $0) }
        revealOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnHover)) ?? true
        revealOnClick = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnClick)) ?? true
        revealOnScroll = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnScroll)) ?? true
        rehideSeconds = Self.clampedRehide(
            (try? c.decodeIfPresent(Double.self, forKey: .rehideSeconds)) ?? Self.defaultRehideSeconds)
        rehideMode = (try? c.decodeIfPresent(RehideMode.self, forKey: .rehideMode)) ?? .timed
        revealStyle = (try? c.decodeIfPresent(RevealStyle.self, forKey: .revealStyle)) ?? .bar
        hideShownWhileRevealing = (try? c.decodeIfPresent(Bool.self, forKey: .hideShownWhileRevealing)) ?? false
        // Absent with a map present means a file from the cover era —
        // the map is cleared on first apply. Absent with no map has
        // nothing to migrate and reads as current.
        layoutModel = (try? c.decodeIfPresent(Int.self, forKey: .layoutModel))
            ?? (sections.isEmpty ? Self.currentLayoutModel : 0)
        coverMaterial = (try? c.decodeIfPresent(CoverMaterial.self, forKey: .coverMaterial)) ?? .blend
        coverTint = (try? c.decodeIfPresent(String.self, forKey: .coverTint)) ?? ""
        coverTintOpacity = Self.clampedOpacity(
            (try? c.decodeIfPresent(Double.self, forKey: .coverTintOpacity)) ?? Self.defaultCoverTintOpacity)
        coverRoundness = Self.clampedRoundness(
            (try? c.decodeIfPresent(Double.self, forKey: .coverRoundness)) ?? 0)
        showCoverSeparator = (try? c.decodeIfPresent(Bool.self, forKey: .showCoverSeparator)) ?? false
        profiles = (try? c.decodeIfPresent([Profile].self, forKey: .profiles)) ?? []
        hotkeyBindings = (try? c.decodeIfPresent([MenuBarHotkeyBinding].self,
                                                 forKey: .hotkeyBindings)) ?? []
        // Per-element lossy decode: a rule written by a build that knows
        // an action this one doesn't drops *that rule*, not the list.
        triggerRules = ((try? c.decodeIfPresent([LossyElement<MenuBarTriggerRule>].self,
                                                forKey: .triggerRules)) ?? [])
            .compactMap(\.value)
        let rawApps = (try? c.decodeIfPresent([String: String].self, forKey: .concealedApps)) ?? [:]
        concealedApps = rawApps.compactMapValues { MenuBarItemSection(rawValue: $0) }
        concealSeeded = (try? c.decodeIfPresent(Bool.self, forKey: .concealSeeded)) ?? false
        concealUnnotarized = (try? c.decodeIfPresent(Bool.self, forKey: .concealUnnotarized)) ?? false
        let spacing = (try? c.decodeIfPresent(Int.self, forKey: .itemSpacing)) ?? 0
        itemSpacing = max(0, spacing)
        itemSpacingManaged = (try? c.decodeIfPresent(Bool.self, forKey: .itemSpacingManaged))
            ?? (spacing > 0)
        hideUnderNotch = (try? c.decodeIfPresent(Bool.self, forKey: .hideUnderNotch)) ?? true
        hideOnMenuOverlap = (try? c.decodeIfPresent(Bool.self, forKey: .hideOnMenuOverlap)) ?? true
        spacers = (try? c.decodeIfPresent([Spacer].self, forKey: .spacers)) ?? []
        barUnderlay = (try? c.decodeIfPresent(Bool.self, forKey: .barUnderlay)) ?? false
        agentStatusItem = (try? c.decodeIfPresent(Bool.self, forKey: .agentStatusItem)) ?? false
        combinedSystemItem = (try? c.decodeIfPresent(Bool.self, forKey: .combinedSystemItem)) ?? false
        displayProfiles = (try? c.decodeIfPresent([String: String].self,
                                                 forKey: .displayProfiles)) ?? [:]
        showForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .showForUpdates)) ?? false
        // A file from before the layers: its profiles are snapshots.
        curation = (try? c.decodeIfPresent(MenuBarCuration.self, forKey: .curation))
            ?? MenuBarCuration(profileModel: profiles.isEmpty ? MenuBarCuration.currentProfileModel : 0)
    }
}

// MARK: - Agent Overview

/// The Agent Overview utility's persisted state (docs/UTILITIES.md): the
/// card's own switches. The card keeps no roster — `CoreModel`'s
/// `state.sessions` is the list, shown in the panel and the Overview
/// window — so this holds only whether the card is on, whether an ask
/// stays quiet while its pane is in front, and how loud each provider's
/// agents may be.
///
/// `enabled` defaults on: the utility owns no surface of its own (it
/// draws inside the card only), so "off" parks the card — a display
/// toggle, not a feature gate.
///
/// A file from an older build may still carry the keys of a list
/// organizer this card once had (grouping, which rows to show, a row
/// cap). Nothing reads them: they are ignored on decode and gone on the
/// next save.
public struct AgentOverviewSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// When the ask's own terminal pane is already frontmost the
    /// escalation ladder stays quiet — no pulse, no chime, no sound
    /// burst — because the user is already looking at it. The banner
    /// still lands for the record.
    public var quietWhenPaneFrontmost: Bool
    /// Provider id → how loud its agents may be (`AgentAlertRule`); a
    /// provider with no entry follows the global notification settings.
    public var alertRules: [String: AgentAlertRule] = [:]

    public init(enabled: Bool = true, quietWhenPaneFrontmost: Bool = true) {
        self.enabled = enabled
        self.quietWhenPaneFrontmost = quietWhenPaneFrontmost
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, quietWhenPaneFrontmost, alertRules
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        quietWhenPaneFrontmost = (try? c.decodeIfPresent(Bool.self, forKey: .quietWhenPaneFrontmost)) ?? true
        alertRules = (try? c.decodeIfPresent([String: AgentAlertRule].self, forKey: .alertRules)) ?? [:]
    }
}

// MARK: - Palette frecency

/// The ⌘⇧K palette's memory of what it was used for, Raycast's
/// frecency: every run adds one to a command's score, and the score
/// halves every `halfLife`, so something used daily outranks something
/// used a lot last month without a separate "recent" list. Keys are
/// the palette's stable row ids (`menubar.app.com.1password.1password`,
/// `quiet.1h`) — never titles, so a renamed profile keeps its history.
///
/// Scores are stored already decayed to `lastUsed`; reading one decays
/// the rest of the way to `now`. The table is capped at `limit` keys —
/// the weakest go first — so a palette that saw a hundred ephemeral
/// sessions never grows the file without bound.
public struct PaletteUsage: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The decayed score as of `lastUsed`.
        public var score: Double
        /// Epoch seconds of the most recent run.
        public var lastUsed: Double
        /// Every run ever, undecayed — so a later tuning of `halfLife`
        /// has the raw count to work from.
        public var count: Int

        public init(score: Double, lastUsed: Double, count: Int) {
            self.score = score
            self.lastUsed = lastUsed
            self.count = count
        }
    }

    public var entries: [String: Entry]
    /// Rows pinned above everything but open asks — Raycast's
    /// Favorites, in the order they were added. Never trimmed by the
    /// frecency cap: a favorite is a choice, not a habit.
    public var favorites: [String]

    /// Four days: a command used every workday stays near the top
    /// through a weekend; one used once a week ago sits at about a
    /// third of a fresh run.
    public static let halfLife: TimeInterval = 4 * 24 * 3600
    /// The most keys the table keeps.
    public static let limit = 200

    public init(entries: [String: Entry] = [:], favorites: [String] = []) {
        self.entries = entries
        self.favorites = favorites
    }

    public func isFavorite(_ key: String) -> Bool { favorites.contains(key) }

    /// Pin a row, or unpin it; a new favorite goes to the end.
    public mutating func toggleFavorite(_ key: String) {
        guard !key.isEmpty else { return }
        if let index = favorites.firstIndex(of: key) {
            favorites.remove(at: index)
        } else {
            favorites.append(key)
        }
    }

    /// Raycast's Reset Ranking: the key's habit is dropped, so it leaves
    /// Suggestions and ranks on its words alone. A pin is a choice, not
    /// a habit, and stays.
    public mutating func forget(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// The key's score decayed to `now`; zero for a key never used.
    public func score(for key: String, at now: Date = Date()) -> Double {
        guard let entry = entries[key] else { return 0 }
        return Self.decayed(entry.score, from: entry.lastUsed, to: now.timeIntervalSince1970)
    }

    /// One run: decay what the key had to `now`, add one, and trim the
    /// table back to `limit` by current score.
    public mutating func record(_ key: String, at now: Date = Date()) {
        guard !key.isEmpty else { return }
        let t = now.timeIntervalSince1970
        let previous = entries[key]
        let carried = previous.map { Self.decayed($0.score, from: $0.lastUsed, to: t) } ?? 0
        entries[key] = Entry(score: carried + 1, lastUsed: t, count: (previous?.count ?? 0) + 1)
        guard entries.count > Self.limit else { return }
        let kept = Set(ranked(at: t).prefix(Self.limit).map(\.key))
        entries = entries.filter { kept.contains($0.key) }
    }

    /// The keys with the highest current score, best first — the
    /// palette's Suggestions. `minimum` keeps a single run from a month
    /// ago (≈ 0.005) off the list.
    public func top(_ count: Int, at now: Date = Date(), minimum: Double = 0.25) -> [String] {
        let strong = ranked(at: now.timeIntervalSince1970).filter { $0.score >= minimum }
        return strong.prefix(count).map(\.key)
    }

    /// Every key with its score decayed to `t`, strongest first; equal
    /// scores fall back to the key so the order never depends on the
    /// dictionary's.
    private func ranked(at t: Double) -> [(key: String, score: Double)] {
        var scored: [(key: String, score: Double)] = []
        scored.reserveCapacity(entries.count)
        for (key, entry) in entries {
            scored.append((key, Self.decayed(entry.score, from: entry.lastUsed, to: t)))
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.key < b.key }
        return scored
    }

    static func decayed(_ score: Double, from then: Double, to now: Double) -> Double {
        let age = max(0, now - then)
        return score * pow(0.5, age / halfLife)
    }

    private enum CodingKeys: String, CodingKey { case entries, favorites }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent([String: Entry].self, forKey: .entries)) ?? [:]
        favorites = (try? c.decodeIfPresent([String].self, forKey: .favorites)) ?? []
    }
}
