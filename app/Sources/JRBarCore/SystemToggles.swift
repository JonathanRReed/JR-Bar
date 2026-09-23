import Foundation

/// One Switch's row, JR-Bar's honesty rules: a bounded set of system
/// toggles and momentary actions. Every case declares exactly what it
/// is — a reversible state flip or a fire-and-forget verb — and the
/// pure half (which command, which key, which read maps to on) lives
/// here where tests can pin it. The app side runs processes and reads
/// defaults; nothing here forks, reads, or touches the system.
///
/// Honesty rules:
/// * A toggle that cannot be read back still *shows* its last applied
///   intent rather than claiming system truth — but every case here
///   has a real read path, so the chip only ever reflects the system.
/// * `lock` and `screenSaver` are verbs, not states — they render as
///   buttons, never as stuck toggles.
/// * Destructive-adjacent flips (Finder/Dock restarts) are declared
///   in `restarts` so the UI can warn once.
public enum SystemToggle: String, CaseIterable, Codable, Sendable {
    case keepAwake
    case darkMode
    case desktopIcons
    case hiddenFiles
    case mute
    case screenSaver
    case lock
    case dockAutoHide
    /// The default input's mute — a meeting mute you can see.
    case micMute
    /// Every removable volume out, except the SidePulse strips.
    case eject
    /// The Mac to sleep now.
    case sleep

    /// The chip's label — short, verb-first, One Switch grammar.
    public var title: String {
        switch self {
        case .keepAwake: return "Awake"
        case .darkMode: return "Dark"
        case .desktopIcons: return "Desktop"
        case .hiddenFiles: return "Hidden"
        case .mute: return "Mute"
        case .screenSaver: return "Saver"
        case .lock: return "Lock"
        case .dockAutoHide: return "Dock"
        case .micMute: return "Mic"
        case .eject: return "Eject"
        case .sleep: return "Sleep"
        }
    }

    /// The name wherever the chip is listed rather than drawn — a
    /// Settings row, a shortcut, a Shortcuts action.
    public var longTitle: String {
        switch self {
        case .keepAwake: return "Keep the Mac awake"
        case .darkMode: return "Dark mode"
        case .desktopIcons: return "Desktop icons"
        case .hiddenFiles: return "Hidden files"
        case .mute: return "Mute output"
        case .screenSaver: return "Start the screen saver"
        case .lock: return "Lock the screen"
        case .dockAutoHide: return "Dock auto-hide"
        case .micMute: return "Mute the microphone"
        case .eject: return "Eject removable disks"
        case .sleep: return "Sleep the Mac"
        }
    }

    public var symbol: String {
        switch self {
        case .keepAwake: return "cup.and.saucer.fill"
        case .darkMode: return "moon.fill"
        case .desktopIcons: return "menubar.dock.rectangle"
        case .hiddenFiles: return "eye.slash"
        case .mute: return "speaker.slash.fill"
        case .screenSaver: return "sparkles"
        case .lock: return "lock.fill"
        case .dockAutoHide: return "dock.rectangle"
        case .micMute: return "mic.slash.fill"
        case .eject: return "eject.fill"
        case .sleep: return "powersleep"
        }
    }

    /// Stateful toggles show on/off; momentary verbs just fire.
    public var isMomentary: Bool {
        switch self {
        case .screenSaver, .lock, .eject, .sleep: return true
        default: return false
        }
    }

    /// Words a palette or a link might use for the chip beyond its title.
    public var keywords: [String] {
        switch self {
        case .keepAwake: return ["awake", "caffeinate", "amphetamine", "no sleep"]
        case .darkMode: return ["dark", "appearance", "light mode", "theme"]
        case .desktopIcons: return ["desktop", "icons", "clean desktop"]
        case .hiddenFiles: return ["hidden", "dotfiles", "show all files"]
        case .mute: return ["mute", "sound", "volume", "speaker"]
        case .screenSaver: return ["screen saver", "saver"]
        case .lock: return ["lock", "lock screen", "away"]
        case .dockAutoHide: return ["dock", "auto-hide", "autohide"]
        case .micMute: return ["mic", "microphone", "meeting", "call"]
        case .eject: return ["eject", "unmount", "usb", "disk"]
        case .sleep: return ["sleep", "suspend", "sleep now"]
        }
    }

    // MARK: - The lock chip's honesty

    /// How soon the Mac asks for a password after the display sleeps —
    /// what decides whether the Lock chip actually locks.
    public enum ScreenLockDelay: Equatable, Sendable {
        case immediate
        case after(seconds: Int)
        /// No password on wake at all: display sleep locks nothing.
        case off
    }

    /// `sysadminctl -screenLock status` (unprivileged on macOS 27) to a
    /// delay: "screenLock delay is immediate", "screenLock delay is 300
    /// seconds", "screenLock is off". nil when the output says none of
    /// them — the chip then keeps its plain word rather than guess.
    public static func screenLockDelay(fromSysadminctl output: String) -> ScreenLockDelay? {
        let text = output.lowercased()
        if text.contains("screenlock is off") { return .off }
        guard let range = text.range(of: "screenlock delay is ") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("immediate") { return .immediate }
        let digits = rest.prefix { $0.isNumber }
        guard let seconds = Int(digits) else { return nil }
        return seconds == 0 ? .immediate : .after(seconds: seconds)
    }

    /// The Lock chip's label for a delay: "Lock" only when it truly
    /// locks at once; otherwise it is a display sleep and says so.
    public static func lockTitle(delay: ScreenLockDelay?) -> String {
        switch delay {
        case .after, .off: return "Display"
        case .immediate, nil: return "Lock"
        }
    }

    /// The chip's tooltip — the verb, the honest restart or lock caveat,
    /// and the current truth for stateful toggles.
    public func help(on: Bool, lockDelay: ScreenLockDelay? = nil, awakeUntil: Date? = nil,
                     awakeKeepsDisplay: Bool = false, now: Date = Date()) -> String {
        switch self {
        case .keepAwake:
            guard on else {
                return awakeKeepsDisplay
                    ? "Keep the Mac and its display awake — the screen will not lock while held."
                    : "Keep the Mac awake (the display may still sleep and lock)."
            }
            if let awakeUntil, awakeUntil > now {
                let minutes = Int((awakeUntil.timeIntervalSince(now) / 60).rounded(.up))
                return "Keeping the Mac awake for \(Self.minutesPhrase(minutes)) more — click to allow sleep."
            }
            return "Keeping the Mac awake — click to allow sleep."
        case .darkMode:
            return on ? "Dark mode is on — click for light." : "Switch to dark mode."
        case .desktopIcons:
            return on ? "Desktop icons visible — click to hide (restarts Finder)."
                : "Show desktop icons (restarts Finder)."
        case .hiddenFiles:
            return on ? "Hidden files visible — click to conceal (restarts Finder)."
                : "Show hidden files (restarts Finder)."
        case .mute:
            return on ? "Output muted — click to unmute." : "Mute the default output."
        case .screenSaver:
            return "Start the screen saver."
        case .lock:
            switch lockDelay {
            case .immediate: return "Lock the screen now."
            case .after(let seconds):
                return "Sleep the display — the Mac asks for a password \(Self.minutesPhrase(max(1, seconds / 60))) later (Lock Screen settings)."
            case .off: return "Sleep the display — no password is set to be required, so this does not lock."
            case nil: return "Sleep the display — locks on wake wherever a password is required."
            }
        case .dockAutoHide:
            return on ? "Dock auto-hides — click to keep it shown." : "Auto-hide the Dock."
        case .micMute:
            return on ? "Microphone muted — click to unmute." : "Mute the default microphone."
        case .eject:
            return "Eject every removable disk — SidePulse strips stay mounted."
        case .sleep:
            return "Put the Mac to sleep now."
        }
    }

    private static func minutesPhrase(_ minutes: Int) -> String {
        if minutes >= 120, minutes % 60 == 0 { return "\(minutes / 60) h" }
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    // MARK: - The Eject chip's exception

    /// A SidePulse strip's volume by its name — the daemon's own rule
    /// (`device_inventory._jrbar_candidate`): letters and digits only,
    /// lowercased, starting "sidepulse" or the old Dot label "pulsedot".
    /// Eject never takes these: the strip is the light, not a disk.
    public static func isLEDVolume(name: String) -> Bool {
        let normalized = String(name.lowercased().filter { $0.isLetter || $0.isNumber })
        return normalized.hasPrefix("sidepulse") || normalized.hasPrefix("pulsedot")
    }

    /// What the Eject chip needs to know about one mounted volume.
    public struct VolumeFacts: Equatable, Sendable {
        public var name: String
        public var path: String
        public var ejectable: Bool
        public var removable: Bool
        public var isInternal: Bool
        public var local: Bool
        public var root: Bool

        public init(name: String, path: String, ejectable: Bool, removable: Bool,
                    isInternal: Bool, local: Bool, root: Bool) {
            self.name = name
            self.path = path
            self.ejectable = ejectable
            self.removable = removable
            self.isInternal = isInternal
            self.local = local
            self.root = root
        }
    }

    /// Would the Eject chip take this volume? Local, ejectable or
    /// removable, not the startup disk, not internal — and never a
    /// SidePulse strip, by name or because the daemon lists its mount
    /// among the connected devices (`protectedPaths`). Network shares
    /// are left alone: they are unmounted, not ejected.
    public static func shouldEject(_ volume: VolumeFacts, protectedPaths: Set<String>) -> Bool {
        guard volume.local, !volume.root, !volume.isInternal || volume.ejectable else { return false }
        guard volume.ejectable || volume.removable else { return false }
        if isLEDVolume(name: volume.name) { return false }
        let standardized = (volume.path as NSString).standardizingPath
        return !protectedPaths.contains { ($0 as NSString).standardizingPath == standardized }
    }

    /// The caption after an Eject: what went, what refused and why,
    /// and the strip that stayed.
    public static func ejectSummary(ejected: [String], refused: [(name: String, reason: String)],
                                    keptLED: [String]) -> String {
        var parts: [String] = []
        if !ejected.isEmpty { parts.append("Ejected \(listed(ejected)).") }
        for refusal in refused { parts.append("“\(refusal.name)” stayed: \(refusal.reason).") }
        if ejected.isEmpty, refused.isEmpty { parts.append("Nothing to eject.") }
        if !keptLED.isEmpty { parts.append("\(listed(keptLED)) stays mounted.") }
        return parts.joined(separator: " ")
    }

    private static func listed(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        switch quoted.count {
        case 0: return ""
        case 1: return quoted[0]
        case 2: return "\(quoted[0]) and \(quoted[1])"
        default: return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        }
    }

    /// What flips besides the setting — Finder relaunches for the
    /// desktop rows. A restart is visible to the user; the chip's copy
    /// says so instead of hiding it. The Dock is not on the list: it
    /// flips live (`CoreDock`, else System Events), and only the last
    /// resort `applyCommand` restarts it.
    public var restarts: String? {
        switch self {
        case .desktopIcons, .hiddenFiles: return "Finder"
        default: return nil
        }
    }

    // MARK: - The strip

    /// The chips a fresh strip shows, in order — the eight the card has
    /// always drawn.
    public static let defaultStrip: [SystemToggle] = [
        .keepAwake, .darkMode, .desktopIcons, .hiddenFiles,
        .mute, .screenSaver, .lock, .dockAutoHide,
    ]

    /// A stored strip back to chips: unknown names (a newer build's
    /// chip, a typo) are dropped, duplicates collapse, and the order is
    /// always the canonical one so the strip never shuffles. An empty
    /// stored list stays empty — hiding every chip is a choice.
    public static func strip(fromStored raw: [String]) -> [SystemToggle] {
        let chosen = Set(raw.compactMap(SystemToggle.init(rawValue:)))
        return allCases.filter(chosen.contains)
    }

    // MARK: - Reads (pure: the defaults key + the on-mapping)

    /// The `defaults read` probe for stateful toggles whose state
    /// lives in a plist. `keepAwake` reads our own assertion (the app
    /// tracks it), `mute` reads CoreAudio, `darkMode` reads the global
    /// domain — their probes are nil here and handled in the model.
    public var defaultsProbe: (domain: String, key: String, onWhenAbsent: Bool)? {
        switch self {
        case .desktopIcons:
            // Finder treats a missing key as show.
            return ("com.apple.finder", "CreateDesktop", true)
        case .hiddenFiles:
            return ("com.apple.finder", "AppleShowAllFiles", false)
        case .dockAutoHide:
            return ("com.apple.dock", "autohide", false)
        default:
            return nil
        }
    }

    /// What `defaults read` prints when the key is on. Booleans read
    /// "1"/"0" through `defaults`; absent maps to `onWhenAbsent`.
    public static func readMaps(_ output: String?, onWhenAbsent: Bool) -> Bool {
        guard let output else { return onWhenAbsent }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "1" || trimmed.lowercased() == "true" || trimmed.lowercased() == "yes"
    }

    // MARK: - Applies (pure: the command text)

    /// The `/bin/sh -c` payload for a state flip or a verb. nil for
    /// `keepAwake` (an IOPMAssertion, not a process) and `mute`
    /// (CoreAudio) — those apply in-process. `darkMode` goes through
    /// AppleScript because the private `SLSSetAppearance...` calls
    /// rivals reach for are exactly what we won't link.
    public func applyCommand(on: Bool) -> String? {
        switch self {
        case .darkMode:
            return "osascript -e 'tell application \"System Events\" "
                + "to tell appearance preferences to set dark mode to \(on)'"
        case .desktopIcons:
            return "defaults write com.apple.finder CreateDesktop -bool \(on) && killall Finder"
        case .hiddenFiles:
            return "defaults write com.apple.finder AppleShowAllFiles -bool \(on) && killall Finder"
        case .dockAutoHide:
            // The last resort: `liveApplyCommand` and the app's CoreDock
            // driver both flip the running Dock without a relaunch.
            return "defaults write com.apple.dock autohide -bool \(on) && killall Dock"
        case .screenSaver:
            // The engine's own launch — no API, but a stable bundle id
            // and the same path One Switch takes.
            return "open -b com.apple.ScreenSaver.Engine"
        case .lock:
            // CGSession is gone on macOS 27 — the honest public verb
            // is display sleep, which locks on wake wherever the
            // security settings ask for a password (the common case).
            // The private SACLockScreenImmediate rivals reach for is
            // exactly the kind of call we won't link.
            return "pmset displaysleepnow"
        case .sleep:
            return "pmset sleepnow"
        case .keepAwake, .mute, .micMute, .eject:
            // An assertion, CoreAudio and NSWorkspace — in-process.
            return nil
        }
    }

    /// The public flip that needs no relaunch, where one exists: System
    /// Events' `dock preferences` sets the running Dock's autohide in
    /// place (the same Automation grant the Dark chip uses). The app
    /// tries its CoreDock driver before this and `applyCommand` after.
    public func liveApplyCommand(on: Bool) -> String? {
        switch self {
        case .dockAutoHide:
            return "osascript -e 'tell application \"System Events\" "
                + "to tell dock preferences to set autohide to \(on)'"
        default:
            return applyCommand(on: on)
        }
    }
}
