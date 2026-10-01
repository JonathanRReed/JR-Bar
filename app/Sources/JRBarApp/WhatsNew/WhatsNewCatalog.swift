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
    static let releaseID = "0.9.16"

    /// The header's one line.
    static let headline = "Sub-agent asks stay quiet, sign-in and updates are one click, and token totals cover the month."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "subagents", symbol: "person.2",
            title: "Sub-agent asks stay quiet",
            detail: "While Sub-agent asks is off, a worker's prompt stays quiet and its session says how many are waiting.",
            tryIt: .settings(page: "agents"), opens: "Opens Settings › Agents, where Sub-agent asks is"),
        WhatsNewEntry(
            id: "signin", symbol: "key",
            title: "Fix sign-in in one click",
            detail: "A stale or signed-out provider card has a Fix sign-in button for Claude's renewal or the CLI's login.",
            tryIt: .window(.usage), opens: "Opens Usage, where the provider cards are"),
        WhatsNewEntry(
            id: "updates", symbol: "arrow.down.circle",
            title: "Update agent CLIs",
            detail: "Settings › Agents shows each CLI's version with an Update button that runs its own updater.",
            tryIt: .settings(page: "agents"), opens: "Opens Settings › Agents"),
        WhatsNewEntry(
            id: "tokens", symbol: "chart.bar",
            title: "Token totals cover the month",
            detail: "The Claude and Codex cards add up all 30 days, however busy, and never show a partial total.",
            tryIt: .window(.usage), opens: "Opens Usage"),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "Toys rest on low power",
            detail: "The Aquarium, Notch Buddy and island halve or pause decorative motion in Low Power Mode or heat.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(
            id: "dot", symbol: "light.strip.2",
            title: "Screen Bar flash stays safe",
            detail: "A 5 Hz preview is slowed to the flash limit, and the Dot no longer holds a pulse's peak.",
            tryIt: .settings(page: "devices"), opens: "Opens Settings › Devices, where Pro & Dot is"),
        WhatsNewEntry(
            id: "esc", symbol: "escape",
            title: "Esc stays with its window",
            detail: "Esc folds the notch card only from its own window, so Settings text fields keep their Esc.",
            keys: "Esc"),
        WhatsNewEntry(
            id: "saved", symbol: "externaldrive",
            title: "Saved files survive damage",
            detail: "A file JR-Bar cannot read is set aside as corrupt, not overwritten, and good rows survive."),
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
