import CoreGraphics
import Foundation

/// The room the toys play in (docs/TOYS.md): whether JR-Bar is being
/// quiet, a macOS Focus is on, or a call has the mic or camera — and
/// what a celebration does about it. One rule for every toy, read from
/// what the daemon already decides for the lights, so the toys and the
/// lights always agree about when to keep it down.
public enum ToysHush {
    /// Why the toys are keeping it down, most specific first.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// A call has the mic or camera.
        case call
        /// A macOS Focus the daemon reads.
        case focus
        /// JR-Bar's own quiet: the schedule, a manual quiet, a snooze.
        case quiet
        /// Every screen belongs to a fullscreen app.
        case fullscreen

        /// The card's words for it.
        public var text: String {
            switch self {
            case .call: return "on a call"
            case .focus: return "Focus is on"
            case .quiet: return "JR-Bar is quiet"
            case .fullscreen: return "a fullscreen app has the screen"
            }
        }
    }

    /// The daemon's quiet reading (`state.focus`, docs/CORE-PROTOCOL.md):
    /// `mode` is the active quiet mode, or the literal `off` — never
    /// null — while nothing quiet is in effect. Any mode but `off`
    /// counts while its `until` has not passed; a missing mode (no
    /// document yet) and an older build's `normal` read as clear too.
    /// `source == "focus"` is a macOS Focus; everything else is JR-Bar's
    /// own quiet.
    public static func quietReason(mode: String?, source: String?, until: Double?,
                                   now: Date) -> Reason? {
        let word = (mode ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, word != "off", word != "normal" else { return nil }
        if let until, until > 0, until <= now.timeIntervalSince1970 { return nil }
        return source?.lowercased() == "focus" ? .focus : .quiet
    }

    /// The room right now, fullscreen aside (that is per screen, see
    /// `ConfettiRoom`). A call outranks a Focus, a Focus outranks
    /// JR-Bar's own quiet — the reason names the most specific fact.
    public static func reason(mode: String?, source: String?, until: Double?,
                              onCall: Bool, now: Date) -> Reason? {
        if onCall { return .call }
        return quietReason(mode: mode, source: source, until: until, now: now)
    }
}

/// What a burst does while the room is hushed: wait and play a smaller
/// one when it lifts, or let it go.
public enum ConfettiHeldBurst: String, Codable, CaseIterable, Sendable {
    case later
    case drop
}

/// The confetti's manners (docs/TOYS.md): a burst never lands on a
/// fullscreen Keynote or a video call. Pure, so the rules can be pinned
/// without a window.
public enum ConfettiRoom {
    public enum Verdict: Equatable, Sendable {
        /// Fire now, on the screens that are free.
        case fire
        /// Keep it until the room clears.
        case hold
        /// Let it go.
        case drop
    }

    /// A held burst older than this is old news: dropped, not replayed.
    public static let holdLimit: TimeInterval = 30 * 60
    /// The replay once a hold lifts is a nod, not the full cannon.
    public static let replayDensity: Double = 0.5
    /// How often a held burst looks at the room again. The Focus edge
    /// also re-checks the moment a document lands; this catches the
    /// fullscreen app going away and a call ending.
    public static let recheckInterval: TimeInterval = 5
    /// Outside callers (a URL, a script) get one burst per this long —
    /// a loop in someone's hook should not turn into a strobe.
    public static let requestCooldown: TimeInterval = 3

    /// The decision for one burst: `hush` is the room's reason (nil is
    /// a clear room), `freeScreens` how many screens have no fullscreen
    /// app on them.
    public static func verdict(hush: ToysHush.Reason?, freeScreens: Int,
                               whenHeld: ConfettiHeldBurst) -> Verdict {
        if hush == nil, freeScreens > 0 { return .fire }
        return whenHeld == .later ? .hold : .drop
    }

    /// Whether a burst held since `heldAt` should still play.
    public static func stillWorthPlaying(heldAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(heldAt) <= holdLimit
    }

    /// Which screens a fullscreen app owns: a window that exactly covers
    /// a screen's whole frame — menu-bar strip included, which is what
    /// separates a fullscreen Space from a merely zoomed window. Frames
    /// are in one coordinate space (the window list's top-left global
    /// space; the caller converts the screens). Returns the indexes of
    /// the covered screens.
    public static func coveredScreens(windows: [CGRect], screens: [CGRect]) -> Set<Int> {
        var covered = Set<Int>()
        for (index, screen) in screens.enumerated() where screen.width > 0 && screen.height > 0 {
            if windows.contains(where: { covers($0, screen) }) { covered.insert(index) }
        }
        return covered
    }

    /// Within a point of the screen on every edge — window lists report
    /// whole points, screens can carry a fraction on a scaled display.
    static func covers(_ window: CGRect, _ screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 1 && abs(window.minY - screen.minY) <= 1
            && abs(window.width - screen.width) <= 1 && abs(window.height - screen.height) <= 1
    }
}
