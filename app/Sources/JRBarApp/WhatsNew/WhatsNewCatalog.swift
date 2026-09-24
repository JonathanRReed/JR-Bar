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
    static let releaseID = "2026-09-24"

    /// The header's one line.
    static let headline = "A map of your agents, a new Aquarium, and ⌘⇧K works."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "palette", symbol: "command",
            title: "⌘⇧K runs all of JR-Bar",
            detail: "The command palette opens from any app, and its key keeps working after you run a verb.",
            tryIt: .menuBar(.commandBar), opens: "Opens the command palette"),
        WhatsNewEntry(
            id: "graph", symbol: "point.3.connected.trianglepath.dotted",
            title: "The Overview draws a map",
            detail: "Every agent, its workers and whatever waits on you, as a living graph you can pan and zoom.",
            tryIt: .window(.overview), opens: "Opens the Overview; the Graph is in its sidebar"),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "A brand-new Aquarium",
            detail: "Every fish, pet and piece of the tank is redrawn, lit from the surface with real depth.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where the Aquarium card is"),
        WhatsNewEntry(
            id: "open", symbol: "arrow.up.forward.app",
            title: "Open lands on the session",
            detail: "A click aims for the session's own conversation, and Claude in Ghostty raises its pane.",
            tryIt: .panel(toggle: false), opens: "Opens the panel, where your sessions are"),
        WhatsNewEntry(
            id: "approve", symbol: "checkmark.circle",
            title: "Approve never waits",
            detail: "Answers go ahead of long usage scans, and a held ask shows its 45-second window as a ring.",
            tryIt: .panel(toggle: false), opens: "Opens the panel, where asks wait for your click"),
        WhatsNewEntry(
            id: "usage", symbol: "chart.bar.xaxis",
            title: "Usage in a second",
            detail: "The Usage Center reads a warm index, so fresh numbers arrive in seconds instead of minutes.",
            tryIt: .window(.usage), opens: "Opens the Usage Center"),
        WhatsNewEntry(
            id: "quiet", symbol: "leaf",
            title: "Idles near zero",
            detail: "Closed windows stop drawing, and the monitor stays under about half a gigabyte."),
        WhatsNewEntry(
            id: "lyrics", symbol: "quote.bubble",
            title: "Lyrics are opt-in",
            detail: "Synced lyrics come from LRCLIB on the internet, so they wait for your click now.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where the Notch card's lyrics switch is"),
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
