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
        }
    }

    /// Stateful toggles show on/off; momentary verbs just fire.
    public var isMomentary: Bool {
        switch self {
        case .screenSaver, .lock: return true
        default: return false
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
        case .keepAwake, .mute:
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
