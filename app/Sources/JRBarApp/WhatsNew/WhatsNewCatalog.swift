import Foundation

/// One new thing, as the What's New window shows it: a mark, a short
/// title, one sentence, and — where a click can show it — a Try it that
/// opens the surface.
struct WhatsNewEntry: Identifiable, Equatable, Sendable {
    /// Stable across releases; the tests key off it.
    let id: String
    /// An SF Symbol.
    let symbol: String
    /// Five words at most.
    let title: String
    /// One sentence.
    let detail: String
    /// What Try it runs through `AppCommandRouter`, on a click and only
    /// then; nil where there is nothing to open.
    var tryIt: AppCommand? = nil
    /// What Try it opens, in a few words: its tooltip and its VoiceOver
    /// hint.
    var opens: String? = nil
    /// A key chord shown as a chip: beside the title when the row also
    /// has Try it, on the right when it doesn't.
    var keys: String? = nil
}

/// What this release brings, in the order the window lists it.
///
/// The words are written last, from what actually merged: an entry whose
/// work didn't land comes out, and a row whose behaviour is still on the
/// morning's hand-check list says what it aims for rather than promising
/// it. No entry answers an agent or sends anything off the Mac; every
/// Try it is a command a link could run.
enum WhatsNewCatalog {
    /// `setup.json`'s `whatsNewSeen` is compared with this. A new
    /// release gets a new id, and the window comes back once.
    static let releaseID = "2026-09-25"

    /// The header's one line.
    static let headline = "Every agent's real mark, a faster Settings, and a notch card that keeps up."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "dock", symbol: "dock.rectangle",
            title: "Tighter Dock previews",
            detail: "Previews sit just off the icon, and Tight, Standard or Roomy spacing is on the Dock card.",
            tryIt: .settings(page: "utilities"), opens: "Opens Settings › Utilities, where the Dock card is"),
        WhatsNewEntry(
            id: "fold", symbol: "laptopcomputer",
            title: "The Fold, like the Duo",
            detail: "The desktop holds still while the screen folds through it, darkening away from the hinge.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where the Fold card is"),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "Fish that really turn",
            detail: "Every fish swims round through a real head-on turn, and an Arcade tank joins the shop.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(
            id: "drag", symbol: "menubar.rectangle",
            title: "⌘-drag to hide",
            detail: "Hold ⌘ and drag a menu bar item across the JR-Bar icon to hide it, or back to show it.",
            keys: "⌘ drag"),
        WhatsNewEntry(
            id: "dot", symbol: "light.strip.2",
            title: "Pro and Dot, one strip",
            detail: "Light flows off the SidePulse into the Dot, kept in step with the Dot's slower clock.",
            tryIt: .settings(page: "devices"), opens: "Opens Settings › Devices, where Pro & Dot is"),
        WhatsNewEntry(
            id: "motions", symbol: "waveform.path",
            title: "New light motions",
            detail: "Ripple, Pendulum and a Land finish join the strip, and every Effect Studio knob works.",
            tryIt: .window(.effects), opens: "Opens Effect Studio"),
        WhatsNewEntry(
            id: "orbs", symbol: "sparkles",
            title: "See what agents do",
            detail: "A working session's orb shows whether it is thinking, searching, writing or running.",
            tryIt: .panel(toggle: false), opens: "Opens the panel, where your sessions are"),
        WhatsNewEntry(
            id: "marks", symbol: "star",
            title: "Every agent's real mark",
            detail: "Claude, Codex, ChatGPT, Gemini, Pi, Grok, Devin and the rest draw their own logos wherever a provider appears.",
            tryIt: .panel(toggle: false), opens: "Opens the panel, where the marks sit beside each session"),
    ]
}

/// When the window comes up on its own: once per release, after Setup
/// has run to its end and never in the launch that shows Setup, at the
/// first moment the monitor is live, the session is unlocked and nothing
/// is full screen in front. Opening it by hand is never gated.
enum WhatsNewGate {
    /// Whether this launch owes the window.
    static func isArmed(setupFinished: Bool, setupShownThisLaunch: Bool, seen: String?,
                        release: String = WhatsNewCatalog.releaseID) -> Bool {
        setupFinished && !setupShownThisLaunch && seen != release
    }

    /// The facts a moment is judged by.
    struct Moment: Equatable, Sendable {
        var coreLive: Bool
        var locked: Bool
        var fullScreenInFront: Bool
    }

    /// Whether now is a moment the window may take: the monitor has
    /// something to show, someone is at the Mac, and no film or
    /// full-screen work is in front.
    static func isRight(_ moment: Moment) -> Bool {
        moment.coreLive && !moment.locked && !moment.fullScreenInFront
    }
}
