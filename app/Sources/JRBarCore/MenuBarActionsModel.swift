import Foundation

/// The Menu Bar utility's persisted automation model — the Codable
/// halves of the app's trigger engine and hotkey registry
/// (app/Sources/JRBarApp/Utilities/MenuBar/). The types live in Core
/// so `MenuBarSettings` can carry them; the engines that evaluate
/// them stay app-side with the windows they drive.
///
/// The vocabulary is deliberately small and honest: a trigger is
/// something the system actually tells us (a distributed notification,
/// a workspace activation, a power-source sample, the clock); an
/// action is something the utility already knows how to do. Arrange is
/// *not* an action — it physically drags the cursor and must never
/// fire from a background path.
public enum MenuBarTrigger: Equatable, Codable, Sendable {
    /// `com.apple.screenIsLocked` — the distributed notification.
    case screenLocked
    case screenUnlocked
    /// `NSWorkspace.didActivateApplicationNotification` for this
    /// bundle id (case-insensitive).
    case appActivated(bundleID: String)
    /// A wall-clock minute, 24-hour. Fires once per day at that
    /// minute — the engine dedupes, the source only needs to tick.
    case timeOfDay(hour: Int, minute: Int)
    /// The internal battery's power source became AC (charger in).
    /// The first sample after the source starts is a baseline — it
    /// never fires a rule the machine was already inside.
    case chargerConnected
    /// AC → battery.
    case chargerDisconnected
    /// The internal battery's charge crossed `percent` downward —
    /// the sample landed at or under it while the previous read was
    /// above. The first sample is a baseline: a rule never fires for
    /// a level the machine was already inside.
    case batteryBelow(percent: Int)
    /// The same crossing upward — the "charged enough" rule.
    case batteryAbove(percent: Int)
    /// Joined a Wi-Fi network — empty `ssid` means any change, a name
    /// means that network specifically. Named matching needs Location
    /// Services (CoreWLAN reads no name without it); the unnamed
    /// flavour rides the system's change notification either way.
    case wifiJoined(ssid: String)
    /// Left Wi-Fi — the readable name went away. Needs the same
    /// Location read `wifiJoined` does; an unreadable SSID can never
    /// prove a leave.
    case wifiLeft
    /// The default input started running — a mic went live anywhere.
    case microphoneInUse
    /// Every consumer let the default input go.
    case microphoneIdle
    /// A Focus mode switched on (INFocusStatusCenter — needs the Focus
    /// Status grant; the card asks when the rule is added).
    case focusEnabled
    /// The last Focus mode switched off.
    case focusDisabled
    /// The agents went to work — the combined state became working
    /// from anything else. JR-Bar's own feed; no standalone menu-bar
    /// manager can see it.
    case agentsStartedWorking
    /// An agent is waiting on you — the combined state became "needs
    /// you".
    case agentNeedsYou
    /// The work stopped — working became done or idle.
    case agentsFinished
    /// The tightest measured usage window's remaining share fell to
    /// `percent` or under — the same crossing rule as `batteryBelow`.
    case quotaBelow(percent: Int)
    /// A SidePulse strip or Dot came up on the daemon's device list.
    case sidePulseConnected
    case sidePulseDisconnected
    /// The lid shut with the Mac still awake — clamshell on an external
    /// display.
    case lidClosed
    case lidOpened
    /// An app with this bundle id launched (case-insensitive).
    case appLaunched(bundleID: String)
    /// An app with this bundle id quit.
    case appQuit(bundleID: String)
    /// A display joined the desk.
    case displayConnected
    /// A display left it.
    case displayDisconnected
}

public enum MenuBarTriggerAction: Equatable, Codable, Sendable {
    /// Apply a `MenuBarSettings.Profile` by name — resolved against
    /// `MenuBarSettings.profiles` (or the built-in "None").
    case applyProfile(name: String)
    /// The quiet bar laid over your curation — or, over a standing
    /// "show everything", your curated bar back (`MenuBarOverlay`). The
    /// map itself is never written.
    case hideAll
    /// Show everything over your curation — or, over a standing quiet
    /// bar, your curated bar back.
    case showAll
    /// Drop the covers for `seconds` — the reveal gesture with an
    /// explicit clock.
    case reveal(seconds: Double)
    /// Bartender's script trigger: a shell command run detached
    /// (`/bin/sh -c …`) — "shortcuts run X", an AppleScript file, a
    /// one-liner. The rule's own text, fired as configured.
    case runScript(command: String)
    /// Keep the Mac awake — Amphetamine's trigger: for `seconds`, or
    /// until released when nil. The same hold the Keep Awake card and
    /// `jrbar://awake` take, so a rule and a click never disagree.
    case holdAwake(seconds: Int?)
    /// Let the Mac sleep again — whatever hold is standing ends.
    case releaseAwake

    /// The longest hold a rule may ask for: a day. A rule that needs
    /// longer holds until released.
    public static let holdAwakeRange: ClosedRange<Int> = 60...86_400

    /// A hold's seconds kept inside `holdAwakeRange`; nil stays nil,
    /// the hold until released.
    public static func clampedAwake(_ seconds: Int?) -> Int? {
        seconds.map { min(max($0, holdAwakeRange.lowerBound), holdAwakeRange.upperBound) }
    }
}

/// One rule. `id` is a stable string (UUIDs are fine) — the engine's
/// per-day dedupe keys on it, so renaming a rule must keep the id.
public struct MenuBarTriggerRule: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var trigger: MenuBarTrigger
    public var action: MenuBarTriggerAction

    public init(id: String = UUID().uuidString, enabled: Bool = true,
                trigger: MenuBarTrigger, action: MenuBarTriggerAction) {
        self.id = id
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
    }

    /// The rule as the card would read it — one line, no formatting
    /// layer needed.
    public var summary: String {
        let t: String
        switch trigger {
        case .screenLocked: t = "when the screen locks"
        case .screenUnlocked: t = "when the screen unlocks"
        case .appActivated(let bundleID): t = "when \(bundleID) activates"
        case .timeOfDay(let h, let m): t = String(format: "at %02d:%02d", h, m)
        case .chargerConnected: t = "when the charger connects"
        case .chargerDisconnected: t = "when the charger disconnects"
        case .batteryBelow(let p): t = "when the battery falls to \(p)%"
        case .batteryAbove(let p): t = "when the battery rises past \(p)%"
        case .wifiJoined(let ssid): t = ssid.isEmpty ? "when Wi-Fi changes" : "when Wi-Fi joins “\(ssid)”"
        case .wifiLeft: t = "when Wi-Fi drops"
        case .microphoneInUse: t = "when the microphone goes live"
        case .microphoneIdle: t = "when the microphone goes quiet"
        case .focusEnabled: t = "when a Focus turns on"
        case .focusDisabled: t = "when the Focus turns off"
        case .agentsStartedWorking: t = "when agents start working"
        case .agentNeedsYou: t = "when an agent needs you"
        case .agentsFinished: t = "when the agents finish"
        case .quotaBelow(let p): t = "when usage headroom falls to \(p)%"
        case .sidePulseConnected: t = "when a SidePulse device connects"
        case .sidePulseDisconnected: t = "when the SidePulse device disconnects"
        case .lidClosed: t = "when the lid closes"
        case .lidOpened: t = "when the lid opens"
        case .appLaunched(let bundleID): t = "when \(bundleID) launches"
        case .appQuit(let bundleID): t = "when \(bundleID) quits"
        case .displayConnected: t = "when a display connects"
        case .displayDisconnected: t = "when a display disconnects"
        }
        let a: String
        switch action {
        case .applyProfile(let name): a = "apply profile “\(name)”"
        case .hideAll: a = "hide all items"
        case .showAll: a = "show all items"
        case .reveal(let s): a = "reveal for \(Int(s))s"
        case .runScript(let command): a = "run “\(command)”"
        case .holdAwake(let seconds): a = Self.awakeSummary(seconds)
        case .releaseAwake: a = "let the Mac sleep again"
        }
        return "\(t) → \(a)"
    }

    /// "keep the Mac awake for 2 h", "… for 45 min", or until released.
    static func awakeSummary(_ seconds: Int?) -> String {
        guard let seconds = MenuBarTriggerAction.clampedAwake(seconds) else {
            return "keep the Mac awake until released"
        }
        if seconds % 3600 == 0 { return "keep the Mac awake for \(seconds / 3600) h" }
        return "keep the Mac awake for \(max(1, seconds / 60)) min"
    }
}

/// What a menu-bar hotkey fires. The app routes these through
/// `MenuBarActions` — the binding model itself is a value: which key,
/// which modifiers, which action.
public enum MenuBarHotkeyAction: String, Codable, CaseIterable, Sendable {
    /// The chevron's own toggle, from anywhere.
    case toggleReveal
    /// The deeper run's own gesture: a temporary reveal of the
    /// always-hidden section — the Item Bar is its only other way out.
    case revealAlwaysHidden
    /// The quiet bar over your curation (`MenuBarOverlay.afterHideAll`).
    case hideAll
    /// Show everything over your curation, or restore it over the quiet
    /// bar (`MenuBarOverlay.afterShowAll`).
    case showAll
    /// The ⌘⇧K palette.
    case commandBar
    /// Step through the saved profiles, wrapping.
    case nextProfile
    case previousProfile
}

/// One binding: Carbon key code + Carbon modifier bits → an action.
/// Carbon's `RegisterEventHotKey` is the one system service that
/// delivers a key to an accessory app that is usually not even active,
/// so the model stores Carbon's own constants; the NSEvent conversions
/// and the ⌃⌥⇧⌘ rendering are app-side extensions in
/// `MenuBarHotkeys.swift`.
public struct MenuBarHotkeyBinding: Equatable, Codable, Sendable {
    public var action: MenuBarHotkeyAction
    /// Carbon virtual key code (`kVK_ANSI_*`).
    public var keyCode: UInt32
    /// Carbon modifier bits (`cmdKey`, `optionKey`, `controlKey`,
    /// `shiftKey`).
    public var modifiers: UInt32
    public var enabled: Bool

    public init(action: MenuBarHotkeyAction, keyCode: UInt32,
                modifiers: UInt32, enabled: Bool) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

// MARK: - The layers over the curated map

/// A bar-wide override laid over the curated map without rewriting it —
/// Bartender 7's transient Focus Mode. "Hide all" and "Show all" used to
/// write every app into `concealedApps`, so one Show all (a button, a
/// hotkey, a rule pair) erased which apps you had chosen to hide. The
/// overlay is the whole answer instead: the map stays yours, and
/// restoring is dropping the overlay.
public struct MenuBarOverlay: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Every app with an item tucked away — the quiet bar. Apps the
        /// map already keeps always hidden stay in that deeper run.
        case hideEverything
        /// Nothing hidden — the bar as macOS would draw it.
        case showEverything
    }

    public var kind: Kind
    /// When the overlay went up, seconds since 1970 — whichever of a
    /// manual overlay and a rule's came last wins.
    public var sinceEpoch: Double
    /// When it lapses on its own; nil holds until the next toggle.
    public var untilEpoch: Double?

    public init(kind: Kind, sinceEpoch: Double = Date().timeIntervalSince1970,
                untilEpoch: Double? = nil) {
        self.kind = kind
        self.sinceEpoch = sinceEpoch
        self.untilEpoch = untilEpoch
    }

    /// Whether the overlay still stands at `now`.
    public func isLive(at now: Date = Date()) -> Bool {
        untilEpoch.map { now.timeIntervalSince1970 < $0 } ?? true
    }

    private enum CodingKeys: String, CodingKey { case kind, sinceEpoch, untilEpoch }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        sinceEpoch = (try? c.decodeIfPresent(Double.self, forKey: .sinceEpoch)) ?? 0
        untilEpoch = (try? c.decodeIfPresent(Double.self, forKey: .untilEpoch)) ?? nil
    }

    /// "Hide all" from wherever it came — the card, a hotkey, the
    /// palette, a rule: set the quiet bar, or, over a "show everything",
    /// drop it and give the curated bar back. Never a toggle, so a rule
    /// that fires twice cannot undo itself.
    public static func afterHideAll(_ current: MenuBarOverlay?, now: Date = Date(),
                                    until: Date? = nil) -> MenuBarOverlay? {
        if current?.kind == .showEverything, current?.isLive(at: now) == true { return nil }
        return MenuBarOverlay(kind: .hideEverything, sinceEpoch: now.timeIntervalSince1970,
                              untilEpoch: until?.timeIntervalSince1970)
    }

    /// "Show all": the mirror — over a quiet bar it restores the curated
    /// bar, so the classic lock → hide / unlock → show pair ends where it
    /// started instead of showing every app you tucked away.
    public static func afterShowAll(_ current: MenuBarOverlay?, now: Date = Date(),
                                    until: Date? = nil) -> MenuBarOverlay? {
        if current?.kind == .hideEverything, current?.isLive(at: now) == true { return nil }
        return MenuBarOverlay(kind: .showEverything, sinceEpoch: now.timeIntervalSince1970,
                              untilEpoch: until?.timeIntervalSince1970)
    }
}

/// Everything layered over the curated maps — the runtime overlay and
/// the additions that ride with it — kept in one Codable value on
/// `MenuBarSettings` so the file's shape changes in one place. Decoded
/// tolerantly like the settings around it: a missing key reads as its
/// default, an unknown one is ignored.
public struct MenuBarCuration: Equatable, Codable, Sendable {
    /// "Hide all" / "Show all" as they stand right now; nil is the
    /// curated bar.
    public var overlay: MenuBarOverlay?
    /// The profile laid over the base map right now — nil is the base
    /// map alone (the built-in "None").
    public var activeProfileID: String?
    /// How a profile's maps are read. 0: a snapshot that replaced the
    /// live maps wholesale on apply — an app hidden after the profile
    /// was saved came back on every switch. 1: a delta over the base
    /// map — only what the profile says differently. Snapshots are
    /// migrated once, to the deltas that reproduce them exactly.
    public var profileModel: Int
    /// The "while" rules — levels that hold a layer, a scene or the
    /// agents' quiet for exactly as long as they last.
    public var stateRules: [MenuBarStateRule]
    /// The LED scene a rule's scene replaced, kept on disk until the rule
    /// ends — so a relaunch mid-rule still restores what you had, and
    /// never mistakes the rule's own scene for yours.
    public var sceneBeforeRule: String?
    /// Keep the spacer engine even where macOS's concealer resolves — a
    /// diagnostic, so the fallback can be proven on a Mac that never
    /// needs it.
    public var forceSpacerEngine: Bool
    /// The desks the Mac has sat at — each set of displays attached at
    /// once — and the profile the bar takes when that set arrives.
    public var deskProfiles: [MenuBarDeskProfile]
    /// The desk the bar last saw, so a set of displays that changed while
    /// JR-Bar was not running still counts as an arrival.
    public var lastDeskKey: String?
    /// The items "show for updates" watches, by owner (the bundle id, or
    /// the item's id for a helper without one). Empty watches every
    /// hidden item; once one is marked, only the marked ones interrupt —
    /// a VPN can, a clock can't.
    public var updateWatch: [String]
    /// A ⌘-drag across the JR-Bar icon picks the dragged app's section:
    /// dropped left of the icon hides it, right of it shows it — the
    /// Bartender, Ice and Hidden Bar habit. Only the person's own
    /// press-and-release writes; a reflow never does.
    public var dragToHide: Bool
    /// Apple's standalone extras (Weather, Passwords, Time Machine) hide
    /// through macOS like any app instead of taking a cover where they
    /// sit. Off until a live probe shows the agent conceals them by
    /// omission; the system's own items never join.
    public var concealAppleExtras: Bool
    /// Where the icon stands under the concealer: flush left of the
    /// first drawn item (`gap`), or exactly on JR-Bar's own macOS slot,
    /// sized to the icon (`slot`) — then "left of the icon" is the
    /// agent's own order.
    public var mirrorSeat: MenuBarMirrorSeat
    /// Ice's "show hidden items while ⌘-dragging": a ⌘-press on the bar
    /// brings the hidden run in beside the icon for the drag, so a
    /// hidden item can be dragged back out.
    public var revealWhileDragging: Bool
    /// The security-scoped bookmark for macOS's menu-bar layout table
    /// (`com.apple.MenuBar.plist`), granted once through an open panel.
    /// Read-only: JR-Bar never writes the table. nil is no grant.
    public var layoutTableBookmark: Data?
    /// Where the Item Bar hangs: under the icon's ‹, or under the
    /// pointer (Bartender Golden Gate's default).
    public var itemBarAt: MenuBarItemBarAnchor
    /// Where an app new to the menu bar goes: where macOS puts it (and
    /// the ear asks), straight to Shown, or straight to Hidden.
    public var newItems: MenuBarNewItemsPlacement
    /// Let a ⌘-drag hide the clock and Control Center through macOS's
    /// own system-item list. Off until a live probe shows they conceal
    /// and come back cleanly; Wi-Fi, battery and sound never join.
    public var concealSystemItems: Bool

    /// The profile model this build writes.
    public static let currentProfileModel = 1
    /// A layout-table bookmark past this size is not one — dropped on
    /// decode rather than carried.
    public static let bookmarkLimit = 64 * 1024

    public init(overlay: MenuBarOverlay? = nil, activeProfileID: String? = nil,
                profileModel: Int = MenuBarCuration.currentProfileModel,
                stateRules: [MenuBarStateRule] = [], sceneBeforeRule: String? = nil,
                forceSpacerEngine: Bool = false, deskProfiles: [MenuBarDeskProfile] = [],
                lastDeskKey: String? = nil, updateWatch: [String] = [],
                dragToHide: Bool = true, concealAppleExtras: Bool = false,
                mirrorSeat: MenuBarMirrorSeat = .gap, revealWhileDragging: Bool = false,
                layoutTableBookmark: Data? = nil, itemBarAt: MenuBarItemBarAnchor = .icon,
                newItems: MenuBarNewItemsPlacement = .asPlaced, concealSystemItems: Bool = false) {
        self.overlay = overlay
        self.activeProfileID = activeProfileID
        self.profileModel = profileModel
        self.stateRules = stateRules
        self.sceneBeforeRule = sceneBeforeRule
        self.forceSpacerEngine = forceSpacerEngine
        self.deskProfiles = deskProfiles
        self.lastDeskKey = lastDeskKey
        self.updateWatch = updateWatch
        self.dragToHide = dragToHide
        self.concealAppleExtras = concealAppleExtras
        self.mirrorSeat = mirrorSeat
        self.revealWhileDragging = revealWhileDragging
        self.layoutTableBookmark = Self.clampedBookmark(layoutTableBookmark)
        self.itemBarAt = itemBarAt
        self.newItems = newItems
        self.concealSystemItems = concealSystemItems
    }

    /// A bookmark inside `bookmarkLimit`, else nil.
    public static func clampedBookmark(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= bookmarkLimit else { return nil }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case overlay, activeProfileID, profileModel, stateRules, sceneBeforeRule, forceSpacerEngine
        case deskProfiles, lastDeskKey, updateWatch
        case dragToHide, concealAppleExtras, mirrorSeat, revealWhileDragging, layoutTableBookmark
        case itemBarAt, newItems, concealSystemItems
    }

    /// One element that swallows its own decode failure — a rule written
    /// by a newer build drops itself, not the list.
    private struct Lossy<Element: Decodable>: Decodable {
        let value: Element?
        init(from decoder: any Decoder) throws { value = try? Element(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlay = (try? c.decodeIfPresent(MenuBarOverlay.self, forKey: .overlay)) ?? nil
        activeProfileID = (try? c.decodeIfPresent(String.self, forKey: .activeProfileID)) ?? nil
        // Absent means a build that stored snapshots — migrate.
        profileModel = (try? c.decodeIfPresent(Int.self, forKey: .profileModel)) ?? 0
        stateRules = ((try? c.decodeIfPresent([Lossy<MenuBarStateRule>].self,
                                              forKey: .stateRules)) ?? []).compactMap(\.value)
        sceneBeforeRule = (try? c.decodeIfPresent(String.self, forKey: .sceneBeforeRule)) ?? nil
        forceSpacerEngine = (try? c.decodeIfPresent(Bool.self, forKey: .forceSpacerEngine)) ?? false
        deskProfiles = ((try? c.decodeIfPresent([Lossy<MenuBarDeskProfile>].self,
                                                forKey: .deskProfiles)) ?? []).compactMap(\.value)
        lastDeskKey = (try? c.decodeIfPresent(String.self, forKey: .lastDeskKey)) ?? nil
        updateWatch = (try? c.decodeIfPresent([String].self, forKey: .updateWatch)) ?? []
        dragToHide = (try? c.decodeIfPresent(Bool.self, forKey: .dragToHide)) ?? true
        concealAppleExtras = (try? c.decodeIfPresent(Bool.self, forKey: .concealAppleExtras)) ?? false
        mirrorSeat = (try? c.decodeIfPresent(MenuBarMirrorSeat.self, forKey: .mirrorSeat)) ?? .gap
        revealWhileDragging = (try? c.decodeIfPresent(Bool.self, forKey: .revealWhileDragging)) ?? false
        layoutTableBookmark = Self.clampedBookmark(
            (try? c.decodeIfPresent(Data.self, forKey: .layoutTableBookmark)) ?? nil)
        itemBarAt = (try? c.decodeIfPresent(MenuBarItemBarAnchor.self, forKey: .itemBarAt)) ?? .icon
        newItems = (try? c.decodeIfPresent(MenuBarNewItemsPlacement.self, forKey: .newItems)) ?? .asPlaced
        concealSystemItems = (try? c.decodeIfPresent(Bool.self, forKey: .concealSystemItems)) ?? false
    }
}

/// Where the icon stands under the concealer — see
/// `MenuBarCuration.mirrorSeat`.
public enum MenuBarMirrorSeat: String, Codable, CaseIterable, Sendable {
    /// Flush left of the first drawn item whose gap fits the icon.
    case gap
    /// On JR-Bar's own macOS slot, which is sized to the icon.
    case slot
}

/// Where the Item Bar hangs.
public enum MenuBarItemBarAnchor: String, Codable, CaseIterable, Sendable {
    case icon
    case pointer
}

/// Where a newcomer to the menu bar goes.
public enum MenuBarNewItemsPlacement: String, Codable, CaseIterable, Sendable {
    /// Where macOS puts it; the ear offers the three sections.
    case asPlaced
    case shown
    case hidden
}

/// A desk: one set of displays attached at once — the laptop alone, the
/// laptop on the studio display, the lid shut on two externals — and the
/// profile the bar takes each time that set arrives. Keyed by the
/// displays' own identities, not the pointer or a display number, so
/// docking picks the layout once and nothing is rewritten as the pointer
/// crosses a seam.
public struct MenuBarDeskProfile: Equatable, Codable, Sendable {
    /// The display set's identity (`MenuBarDesk.key`).
    public var key: String
    /// What the card calls the desk while it is not attached.
    public var name: String
    /// The profile to take on arrival — a saved profile's id, or the
    /// built-in None's.
    public var profileID: String

    public init(key: String, name: String, profileID: String) {
        self.key = key
        self.name = name
        self.profileID = profileID
    }
}

// MARK: - "While" rules

/// A level the Mac is in — what a "while" rule holds for. Where the
/// one-shot triggers fire on an edge, these are read as a state: the
/// rule's effects stand while the level holds and revert on their own
/// when it stops, so one rule replaces a fragile pair.
public enum MenuBarCondition: Equatable, Codable, Sendable {
    case microphoneLive
    case focusOn
    case screenLocked
    /// Off the charger.
    case onBattery
    case batteryAtOrBelow(percent: Int)
    /// On this Wi-Fi network (needs the Location read the join trigger
    /// does).
    case wifiIs(ssid: String)
    case appFrontmost(bundleID: String)
    case appRunning(bundleID: String)
    /// JR-Bar's own feed: an agent is working.
    case agentsWorking
    /// An agent is waiting on you.
    case agentNeedsYou
    /// Nothing is working and nothing is asking.
    case agentsIdle
    /// The tightest measured usage window has this share or less left.
    case quotaAtOrBelow(percent: Int)
    /// A SidePulse strip or Dot is attached.
    case sidePulseConnected
    /// The lid is shut with the Mac awake on an external display.
    case lidClosed
    /// More than one display is attached.
    case externalDisplay
    /// Between two wall-clock minutes of the day (0…1439); a start after
    /// the end spans midnight.
    case timeBetween(startMinute: Int, endMinute: Int)

    /// The condition as a rule line reads it.
    public var label: String {
        switch self {
        case .microphoneLive: return "the microphone is live"
        case .focusOn: return "a Focus is on"
        case .screenLocked: return "the screen is locked"
        case .onBattery: return "on battery"
        case .batteryAtOrBelow(let p): return "the battery is at \(p)% or less"
        case .wifiIs(let ssid): return "on Wi-Fi “\(ssid)”"
        case .appFrontmost(let id): return "\(id) is in front"
        case .appRunning(let id): return "\(id) is running"
        case .agentsWorking: return "agents are working"
        case .agentNeedsYou: return "an agent needs you"
        case .agentsIdle: return "the agents are idle"
        case .quotaAtOrBelow(let p): return "usage headroom is \(p)% or less"
        case .sidePulseConnected: return "SidePulse is connected"
        case .lidClosed: return "the lid is closed"
        case .externalDisplay: return "an external display is attached"
        case .timeBetween(let start, let end):
            return String(format: "between %02d:%02d and %02d:%02d",
                          start / 60, start % 60, end / 60, end % 60)
        }
    }
}

/// What a "while" rule holds — reaching past the menu bar to the strip,
/// the Dot and the daemon, because one rule should set up the whole
/// room: "while the mic is live, the Meeting profile, the on-air scene,
/// and quiet agents".
public enum MenuBarRuleEffect: Equatable, Codable, Sendable {
    /// Every app tucked away — the quiet bar, as an overlay.
    case quietBar
    /// Nothing hidden, as an overlay.
    case showEverything
    /// A saved profile laid over your bar (by name, like the triggers).
    case useProfile(name: String)
    /// The LED scene (an `EffectScene` raw value), your own restored
    /// after.
    case ledScene(scene: String)
    /// The daemon's quiet hours — the agents' sounds and lights hold
    /// their breath, renewed while the rule lasts, ended after.
    case quietAgents

    public var label: String {
        switch self {
        case .quietBar: return "tuck everything away"
        case .showEverything: return "show everything"
        case .useProfile(let name): return "use “\(name)”"
        case .ledScene(let scene): return "the \(scene) scene"
        case .quietAgents: return "quiet the agents"
        }
    }
}

/// One "while" rule. `id` is stable (UUIDs are fine) so the card and
/// the engine can tell rules apart across edits.
public struct MenuBarStateRule: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var condition: MenuBarCondition
    /// "While not" — the rule holds while the condition does not, e.g.
    /// "while not on the office Wi-Fi".
    public var negated: Bool
    public var effects: [MenuBarRuleEffect]

    public init(id: String = UUID().uuidString, enabled: Bool = true,
                condition: MenuBarCondition, negated: Bool = false,
                effects: [MenuBarRuleEffect]) {
        self.id = id
        self.enabled = enabled
        self.condition = condition
        self.negated = negated
        self.effects = effects
    }

    /// The rule as the card reads it — one line.
    public var summary: String {
        let when = (negated ? "while not: " : "while ") + condition.label
        let what = effects.isEmpty ? "nothing" : effects.map(\.label).joined(separator: " + ")
        return "\(when) → \(what)"
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, condition, negated, effects }

    private struct LossyEffect: Decodable {
        let value: MenuBarRuleEffect?
        init(from decoder: any Decoder) throws { value = try? MenuBarRuleEffect(from: decoder) }
    }

    /// The condition must decode — a rule with no condition this build
    /// knows is dropped by the list; an effect it does not know is
    /// dropped alone.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        condition = try c.decode(MenuBarCondition.self, forKey: .condition)
        negated = (try? c.decodeIfPresent(Bool.self, forKey: .negated)) ?? false
        effects = ((try? c.decodeIfPresent([LossyEffect].self, forKey: .effects)) ?? [])
            .compactMap(\.value)
    }
}
