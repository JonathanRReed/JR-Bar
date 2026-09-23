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
    /// Every listed unprotected item → hidden.
    case hideAll
    /// Clear every assignment.
    case showAll
    /// Drop the covers for `seconds` — the reveal gesture with an
    /// explicit clock.
    case reveal(seconds: Double)
    /// Bartender's script trigger: a shell command run detached
    /// (`/bin/sh -c …`) — "shortcuts run X", an AppleScript file, a
    /// one-liner. The rule's own text, fired as configured.
    case runScript(command: String)
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
        }
        return "\(t) → \(a)"
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
    /// Every listed unprotected item behind the covers.
    case hideAll
    /// Clear every assignment.
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

    /// The profile model this build writes.
    public static let currentProfileModel = 1

    public init(overlay: MenuBarOverlay? = nil, activeProfileID: String? = nil,
                profileModel: Int = MenuBarCuration.currentProfileModel) {
        self.overlay = overlay
        self.activeProfileID = activeProfileID
        self.profileModel = profileModel
    }

    private enum CodingKeys: String, CodingKey { case overlay, activeProfileID, profileModel }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlay = (try? c.decodeIfPresent(MenuBarOverlay.self, forKey: .overlay)) ?? nil
        activeProfileID = (try? c.decodeIfPresent(String.self, forKey: .activeProfileID)) ?? nil
        // Absent means a build that stored snapshots — migrate.
        profileModel = (try? c.decodeIfPresent(Int.self, forKey: .profileModel)) ?? 0
    }
}
