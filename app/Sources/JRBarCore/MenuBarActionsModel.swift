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
        case .wifiJoined(let ssid): t = ssid.isEmpty ? "when Wi-Fi changes" : "when Wi-Fi joins “\(ssid)”"
        case .wifiLeft: t = "when Wi-Fi drops"
        case .microphoneInUse: t = "when the microphone goes live"
        case .microphoneIdle: t = "when the microphone goes quiet"
        case .focusEnabled: t = "when a Focus turns on"
        case .focusDisabled: t = "when the Focus turns off"
        }
        let a: String
        switch action {
        case .applyProfile(let name): a = "apply profile “\(name)”"
        case .hideAll: a = "hide all items"
        case .showAll: a = "show all items"
        case .reveal(let s): a = "reveal for \(Int(s))s"
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
