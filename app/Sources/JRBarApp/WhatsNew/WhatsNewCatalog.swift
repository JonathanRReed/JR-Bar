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
    static let releaseID = "0.9.17"

    /// The header's one line.
    static let headline = "Steady provider turns, clearer quotas, and controls within reach."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "provider-turns", symbol: "arrow.triangle.2.circlepath",
            title: "Providers take steady turns",
            detail: "Working providers take three-second turns; one stays still, and waiting asks keep priority."),
        WhatsNewEntry(
            id: "quota-evidence", symbol: "chart.bar",
            title: "Inspect each quota window",
            detail: "Inspect a ring's reading, reset and forecast, then compare recent pace with its budget.",
            tryIt: .window(.usage), opens: "Opens Usage, where the provider cards are"),
        WhatsNewEntry(
            id: "hook-health", symbol: "checkmark.circle",
            title: "Recheck hook health",
            detail: "Recheck the receiver and provider configuration, with failures and old reports clearly labeled.",
            tryIt: .settings(page: "agents"), opens: "Opens Settings › Agents"),
        WhatsNewEntry(
            id: "notch-controls", symbol: "timer",
            title: "Keep notch controls nearby",
            detail: "Now keeps unanswered requests actionable and shows a timer; Clear Shelf offers Undo."),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "Aquarium Live or Still",
            detail: "Pause visual motion and inspect fish from a menu while sessions and rewards keep updating.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(
            id: "dot", symbol: "light.strip.2",
            title: "Device reports stay honest",
            detail: "Disconnected devices label their last report, and calibration keeps refusals visible.",
            tryIt: .settings(page: "devices"), opens: "Opens Settings › Devices, where Pro & Dot is"),
        WhatsNewEntry(
            id: "utility-controls", symbol: "moon.zzz",
            title: "More useful utility controls",
            detail: "Use one-time Awake sessions, Dock exclusions, and clearer menu-bar hiding status."),
        WhatsNewEntry(
            id: "reply-feedback", symbol: "text.bubble",
            title: "Reply feedback stays nearby",
            detail: "Refused or unconfirmed replies retain the draft and explain the outcome in the sheet.",
            tryIt: .window(.overview), opens: "Opens Agent Overview"),
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
