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
    static let releaseID = "0.9.10"

    /// The header's one line.
    static let headline = "Fold starts from rest, reset confetti arrives, and utilities recover safely."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "dock", symbol: "dock.rectangle",
            title: "Keep Awake stays clear",
            detail: "Manual sessions have their own controls, and pending commands cannot run twice.",
            tryIt: .settings(page: "utilities"), opens: "Opens Settings › Utilities, where Keep Awake is"),
        WhatsNewEntry(
            id: "fold", symbol: "laptopcomputer",
            title: "Fold starts from rest",
            detail: "Switching to the resting angle uses the parked lid reading before your first close.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where the Fold card is"),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "Fish earn real work rewards",
            detail: "Work rewards stop while the core is disconnected, and resume when live readings return.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(
            id: "drag", symbol: "menubar.rectangle",
            title: "Safer menu placement",
            detail: "Cancelled drags and old display readings cannot restore a mirror over another control.",
            keys: "⌘ drag"),
        WhatsNewEntry(
            id: "dot", symbol: "light.strip.2",
            title: "Pro and Dot, one strip",
            detail: "Light flows off the SidePulse into the Dot, kept in step with the Dot's slower clock.",
            tryIt: .settings(page: "devices"), opens: "Opens Settings › Devices, where Pro & Dot is"),
        WhatsNewEntry(
            id: "resets", symbol: "party.popper",
            title: "Reset confetti arrives",
            detail: "Recent provider resets reach confetti after reconnecting, even when daemon event numbers restart.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where Confetti is"),
        WhatsNewEntry(
            id: "archive", symbol: "archivebox",
            title: "Read archives without capture",
            detail: "Saved searches, transcripts and details remain available while new capture is off.",
            tryIt: .settings(page: "utilities"), opens: "Opens Settings › Utilities, where Data Hoarder is"),
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
