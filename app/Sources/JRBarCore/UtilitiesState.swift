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
    /// The Agent Overview utility — the organizer half of the agent
    /// roster's management seat (docs/UTILITIES.md).
    public var agents: AgentOrganizerSettings

    public init(enabled: Bool = true, menuBar: MenuBarSettings = MenuBarSettings(),
                dock: DockSettings = DockSettings(),
                agents: AgentOrganizerSettings = AgentOrganizerSettings()) {
        self.enabled = enabled
        self.menuBar = menuBar
        self.dock = dock
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey { case enabled, menuBar, dock, agents }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        menuBar = (try? c.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar)) ?? MenuBarSettings()
        dock = (try? c.decodeIfPresent(DockSettings.self, forKey: .dock)) ?? DockSettings()
        agents = (try? c.decodeIfPresent(AgentOrganizerSettings.self, forKey: .agents)) ?? AgentOrganizerSettings()
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
public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
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
    /// Seconds a reveal lasts before the spacers stand back up.
    public var rehideSeconds: Double
    /// The width a hiding spacer claims — enough to push every hideable
    /// item at or right of its boundary off the row. Persisted so a
    /// rescue build can shrink it; the card never shows it.
    public var spacerLength: Double
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
    /// One status item carrying both controls' jobs — the chevron's
    /// reveal and the always-hidden control's Item Bar — instead of
    /// two separate ones.
    public var combinedStatusItem: Bool
    /// Named presets: a captured section map plus the cover appearance
    /// and control layout, applied wholesale through reconcile.
    public var profiles: [Profile]
    /// The physical order the Arrange action drives the bar to — item
    /// ids left→right. Written by the card's order editor; read only by
    /// the explicit arrange button, never by reconcile.
    public var arrangeOrder: [String]
    /// The global hotkeys. Empty means the shipping set
    /// (`MenuBarHotkeys.standard`) — the card materializes the list the
    /// first time a binding is toggled.
    public var hotkeyBindings: [MenuBarHotkeyBinding]
    /// The trigger rules — "when X, do Y" rows evaluated by the app's
    /// trigger engine.
    public var triggerRules: [MenuBarTriggerRule]

    /// The cover's visual-effect material, persisted as its raw name so
    /// a newer build's materials keep their data.
    public enum CoverMaterial: String, Codable, CaseIterable, Sendable {
        case menu
        case hud
        case popover
        case sheet
    }

    /// A named preset: the section map plus the cover's appearance and
    /// the control layout, captured at save time.
    public struct Profile: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var sections: [String: MenuBarItemSection]
        public var coverMaterial: CoverMaterial
        public var coverTint: String
        public var coverTintOpacity: Double
        public var coverRoundness: Double
        public var showCoverSeparator: Bool
        public var combinedStatusItem: Bool

        public init(id: String, name: String,
                    sections: [String: MenuBarItemSection] = [:],
                    coverMaterial: MenuBarSettings.CoverMaterial = .menu,
                    coverTint: String = "",
                    coverTintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity,
                    coverRoundness: Double = 0,
                    showCoverSeparator: Bool = false,
                    combinedStatusItem: Bool = false) {
            self.id = id
            self.name = name
            self.sections = sections
            self.coverMaterial = coverMaterial
            self.coverTint = coverTint
            self.coverTintOpacity = MenuBarSettings.clampedOpacity(coverTintOpacity)
            self.coverRoundness = MenuBarSettings.clampedRoundness(coverRoundness)
            self.showCoverSeparator = showCoverSeparator
            self.combinedStatusItem = combinedStatusItem
        }
    }

    /// The card's rehide dial.
    public static let rehideRange: ClosedRange<Double> = 1...15
    /// The default reveal window.
    public static let defaultRehideSeconds: Double = 4
    /// The spacer's reach — far past the widest menu bar.
    public static let defaultSpacerLength: Double = 10_000
    /// The card's cover-roundness dial — past half the row's depth the
    /// run ends are a pill anyway.
    public static let coverRoundnessRange: ClosedRange<Double> = 0...14
    /// The tint's default strength.
    public static let defaultCoverTintOpacity: Double = 0.35

    public init(enabled: Bool = false, sections: [String: MenuBarItemSection] = [:],
                revealOnHover: Bool = true, revealOnClick: Bool = true, revealOnScroll: Bool = true,
                rehideSeconds: Double = MenuBarSettings.defaultRehideSeconds,
                spacerLength: Double = MenuBarSettings.defaultSpacerLength,
                coverMaterial: CoverMaterial = .menu, coverTint: String = "",
                coverTintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity,
                coverRoundness: Double = 0, showCoverSeparator: Bool = false,
                combinedStatusItem: Bool = false,
                profiles: [Profile] = [], arrangeOrder: [String] = [],
                hotkeyBindings: [MenuBarHotkeyBinding] = [],
                triggerRules: [MenuBarTriggerRule] = []) {
        self.enabled = enabled
        self.sections = sections
        self.revealOnHover = revealOnHover
        self.revealOnClick = revealOnClick
        self.revealOnScroll = revealOnScroll
        self.rehideSeconds = Self.clampedRehide(rehideSeconds)
        self.spacerLength = Self.clampedSpacerLength(spacerLength)
        self.coverMaterial = coverMaterial
        self.coverTint = coverTint
        self.coverTintOpacity = Self.clampedOpacity(coverTintOpacity)
        self.coverRoundness = Self.clampedRoundness(coverRoundness)
        self.showCoverSeparator = showCoverSeparator
        self.combinedStatusItem = combinedStatusItem
        self.profiles = profiles
        self.arrangeOrder = arrangeOrder
        self.hotkeyBindings = hotkeyBindings
        self.triggerRules = triggerRules
    }

    static func clampedRehide(_ value: Double) -> Double {
        guard value.isFinite else { return defaultRehideSeconds }
        return min(rehideRange.upperBound, max(rehideRange.lowerBound, value))
    }

    /// A spacer too small to push anything off is not a spacer.
    static func clampedSpacerLength(_ value: Double) -> Double {
        guard value.isFinite, value >= 1_000 else { return defaultSpacerLength }
        return value
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

    private enum CodingKeys: String, CodingKey {
        case enabled, sections, revealOnHover, revealOnClick, revealOnScroll, rehideSeconds, spacerLength
        case coverMaterial, coverTint, coverTintOpacity, coverRoundness, showCoverSeparator
        case combinedStatusItem, profiles, arrangeOrder, hotkeyBindings, triggerRules
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .sections)) ?? [:]
        sections = raw.compactMapValues { MenuBarItemSection(rawValue: $0) }
        revealOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnHover)) ?? true
        revealOnClick = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnClick)) ?? true
        revealOnScroll = (try? c.decodeIfPresent(Bool.self, forKey: .revealOnScroll)) ?? true
        rehideSeconds = Self.clampedRehide(
            (try? c.decodeIfPresent(Double.self, forKey: .rehideSeconds)) ?? Self.defaultRehideSeconds)
        spacerLength = Self.clampedSpacerLength(
            (try? c.decodeIfPresent(Double.self, forKey: .spacerLength)) ?? Self.defaultSpacerLength)
        coverMaterial = (try? c.decodeIfPresent(CoverMaterial.self, forKey: .coverMaterial)) ?? .menu
        coverTint = (try? c.decodeIfPresent(String.self, forKey: .coverTint)) ?? ""
        coverTintOpacity = Self.clampedOpacity(
            (try? c.decodeIfPresent(Double.self, forKey: .coverTintOpacity)) ?? Self.defaultCoverTintOpacity)
        coverRoundness = Self.clampedRoundness(
            (try? c.decodeIfPresent(Double.self, forKey: .coverRoundness)) ?? 0)
        showCoverSeparator = (try? c.decodeIfPresent(Bool.self, forKey: .showCoverSeparator)) ?? false
        combinedStatusItem = (try? c.decodeIfPresent(Bool.self, forKey: .combinedStatusItem)) ?? false
        profiles = (try? c.decodeIfPresent([Profile].self, forKey: .profiles)) ?? []
        arrangeOrder = (try? c.decodeIfPresent([String].self, forKey: .arrangeOrder)) ?? []
        hotkeyBindings = (try? c.decodeIfPresent([MenuBarHotkeyBinding].self,
                                                 forKey: .hotkeyBindings)) ?? []
        triggerRules = (try? c.decodeIfPresent([MenuBarTriggerRule].self,
                                               forKey: .triggerRules)) ?? []
    }
}

// MARK: - Agent Overview

/// How the Agent Overview card groups its session rows. Stored as the
/// raw string so a newer build's modes keep their data; an unknown
/// value decodes to the default.
public enum AgentGrouping: String, Codable, CaseIterable, Sendable {
    /// One section per state, in the panel's precedence order —
    /// waiting, failed, working, done, ended, idle.
    case state
    /// One section per provider; sections order by the best rank they
    /// contain, so a provider with a waiting row leads one that's done.
    case provider
    /// No sections — one list in precedence order.
    case flat
}

/// One section of the Agent Overview card's list: a grouping key (the
/// activity's raw value, the provider id, or `"all"` for the flat cut),
/// the title the section header shows, and the sessions inside —
/// already filtered and ordered.
public struct AgentSessionGroup: Equatable, Sendable {
    public var key: String
    public var title: String
    public var sessions: [CoreSession]

    public init(key: String, title: String, sessions: [CoreSession]) {
        self.key = key
        self.title = title
        self.sessions = sessions
    }
}

/// The Agent Overview utility's persisted state (docs/UTILITIES.md):
/// whether the card is on, how the roster is grouped, and which rows
/// it lists. The list itself is never persisted — `CoreModel`'s
/// `state.sessions` is the roster; this is the organizer half.
///
/// `enabled` defaults on: the utility owns no surface of its own (it
/// draws inside the card only), so "on" means the card lists the live
/// roster and "off" parks it — a display toggle, not a feature gate.
public struct AgentOrganizerSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var grouping: AgentGrouping
    /// Peer-mirrored sessions (`remote:` rows) — informational only;
    /// nothing local can open or answer them.
    public var showRemote: Bool
    /// Sessions that went away without a completion word.
    public var showEnded: Bool
    /// Sessions with nothing to report. Off by default — an idle row
    /// earns no space on a management list.
    public var showIdle: Bool
    /// The trailing "12m" column.
    public var showElapsed: Bool
    /// The most rows the card lists; the rest collapse into a "+N more"
    /// line. A card is not the roster — the Overview window is.
    public var rowLimit: Int

    public static let rowLimitRange: ClosedRange<Int> = 3...20
    public static let defaultRowLimit = 8

    public init(enabled: Bool = true, grouping: AgentGrouping = .state,
                showRemote: Bool = true, showEnded: Bool = true, showIdle: Bool = false,
                showElapsed: Bool = true, rowLimit: Int = AgentOrganizerSettings.defaultRowLimit) {
        self.enabled = enabled
        self.grouping = grouping
        self.showRemote = showRemote
        self.showEnded = showEnded
        self.showIdle = showIdle
        self.showElapsed = showElapsed
        self.rowLimit = Self.clampedRowLimit(rowLimit)
    }

    static func clampedRowLimit(_ value: Int) -> Int {
        min(rowLimitRange.upperBound, max(rowLimitRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, grouping, showRemote, showEnded, showIdle, showElapsed, rowLimit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        grouping = (try? c.decodeIfPresent(AgentGrouping.self, forKey: .grouping)) ?? .state
        showRemote = (try? c.decodeIfPresent(Bool.self, forKey: .showRemote)) ?? true
        showEnded = (try? c.decodeIfPresent(Bool.self, forKey: .showEnded)) ?? true
        showIdle = (try? c.decodeIfPresent(Bool.self, forKey: .showIdle)) ?? false
        showElapsed = (try? c.decodeIfPresent(Bool.self, forKey: .showElapsed)) ?? true
        rowLimit = Self.clampedRowLimit(
            (try? c.decodeIfPresent(Int.self, forKey: .rowLimit)) ?? Self.defaultRowLimit)
    }
}

extension AgentOrganizerSettings {
    /// `state.asks` pins a session the way its own `ask` field does —
    /// the dictionary the panel builds so a pinned row counts as
    /// waiting even when `session.ask` is empty.
    public static func pinnedAsks(_ asks: [CoreAsk]) -> [String: CoreAsk] {
        Dictionary(asks.compactMap { ask in ask.session.map { ($0, ask) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// A session's activity with the `state.asks` pin counted: a row
    /// the daemon still holds a question for is waiting on you even
    /// when the session document's own `ask` is empty.
    public static func activity(of session: CoreSession, pinnedAsk: CoreAsk?) -> SessionActivity {
        SessionActivity.reduce(lifecycle: session.lifecycle, mode: session.mode,
                               hasAsk: session.ask != nil || pinnedAsk != nil,
                               nextActor: session.nextActor)
    }

    /// The list's precedence — the panel's: an open ask ranks above
    /// everything, then the activity's sort rank.
    static func rank(of session: CoreSession, pinnedAsk: CoreAsk?) -> Int {
        (session.ask ?? pinnedAsk) != nil ? 0 : activity(of: session, pinnedAsk: pinnedAsk).sortRank
    }

    /// The "what's shown" toggles as one predicate.
    public func includes(_ session: CoreSession, pinnedAsk: CoreAsk? = nil) -> Bool {
        if session.isRemote && !showRemote { return false }
        switch Self.activity(of: session, pinnedAsk: pinnedAsk) {
        case .ended: return showEnded
        case .idle: return showIdle
        default: return true
        }
    }

    /// The filtered, ordered list — the exact sessions the card
    /// enumerates, in the panel's precedence: asks first (longest-
    /// unanswered leading), then waiting, failed, working, done, ended,
    /// idle; most recent inside a rank.
    public func filtered(_ sessions: [CoreSession], asks: [CoreAsk]) -> [CoreSession] {
        let pinned = Self.pinnedAsks(asks)
        let kept = sessions.filter { includes($0, pinnedAsk: pinned[$0.id]) }
        func askAge(_ session: CoreSession) -> Double {
            (session.ask ?? pinned[session.id])?.openedAt
                ?? session.since ?? .greatestFiniteMagnitude
        }
        return kept.sorted { a, b in
            let ra = Self.rank(of: a, pinnedAsk: pinned[a.id])
            let rb = Self.rank(of: b, pinnedAsk: pinned[b.id])
            if ra != rb { return ra < rb }
            if ra == 0 { return askAge(a) < askAge(b) }
            return (a.since ?? 0) > (b.since ?? 0)
        }
    }

    /// The filtered list cut into the sections `grouping` asks for.
    /// Group order follows the precedence of what's inside, so a
    /// provider whose top row is waiting leads one whose top row is
    /// done; inside a group the list order stands.
    public func grouped(_ sessions: [CoreSession], asks: [CoreAsk]) -> [AgentSessionGroup] {
        let pinned = Self.pinnedAsks(asks)
        let rows = filtered(sessions, asks: asks)
        guard !rows.isEmpty else { return [] }
        switch grouping {
        case .flat:
            return [AgentSessionGroup(key: "all", title: "", sessions: rows)]
        case .state:
            var byActivity: [SessionActivity: [CoreSession]] = [:]
            for session in rows {
                byActivity[Self.activity(of: session, pinnedAsk: pinned[session.id]), default: []]
                    .append(session)
            }
            return SessionActivity.allCases
                .sorted { $0.sortRank < $1.sortRank }
                .compactMap { activity in
                    guard let members = byActivity[activity], !members.isEmpty else { return nil }
                    return AgentSessionGroup(key: activity.rawValue, title: activity.word, sessions: members)
                }
        case .provider:
            var byProvider: [String: [CoreSession]] = [:]
            for session in rows {
                byProvider[session.provider.lowercased(), default: []].append(session)
            }
            return byProvider.map { provider, members in
                AgentSessionGroup(key: provider, title: SessionLabel.providerName(provider),
                                  sessions: members)
            }
            .sorted { a, b in
                let ra = a.sessions.map { Self.rank(of: $0, pinnedAsk: pinned[$0.id]) }.min() ?? .max
                let rb = b.sessions.map { Self.rank(of: $0, pinnedAsk: pinned[$0.id]) }.min() ?? .max
                if ra != rb { return ra < rb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Counts by state over the filtered set, in precedence order —
    /// the card's "1 waiting on you · 2 working" line and the list
    /// below it read the same rows, so the two can never disagree.
    public func counts(of sessions: [CoreSession], asks: [CoreAsk]) -> [(activity: SessionActivity, count: Int)] {
        let pinned = Self.pinnedAsks(asks)
        var tally: [SessionActivity: Int] = [:]
        for session in sessions where includes(session, pinnedAsk: pinned[session.id]) {
            tally[Self.activity(of: session, pinnedAsk: pinned[session.id]), default: 0] += 1
        }
        return SessionActivity.allCases
            .filter { (tally[$0] ?? 0) > 0 }
            .sorted { $0.sortRank < $1.sortRank }
            .map { ($0, tally[$0] ?? 0) }
    }
}
