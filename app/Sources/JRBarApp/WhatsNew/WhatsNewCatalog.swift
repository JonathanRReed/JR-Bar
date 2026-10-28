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
    static let releaseID = "0.10.1"

    /// The header's one line.
    static let headline = "Quicker, clearer, and a little festive."

    /// The window has room for this many rows and no more: the lead and
    /// four cards. The view draws exactly this many.
    static let maximumRows = 5

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(id: "notch-quick", symbol: "bolt", title: "A quicker notch",
            detail: "The notch opens without the lag it had on hover."),
        WhatsNewEntry(id: "time-left", symbol: "hourglass", title: "Time left, not a clock",
            detail: "Usage forecasts say how long is left, or a clock time with its day if you prefer.",
            tryIt: .settings(page: "usage"), opens: "Opens Providers"),
        WhatsNewEntry(id: "awake-system", symbol: "cup.and.saucer", title: "Keep Awake, screen off",
            detail: "Keep Awake holds the Mac while the display sleeps, and jrbar awake -- <command> holds it until a command finishes.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
        WhatsNewEntry(id: "dock-previews", symbol: "dock.rectangle", title: "Calendar and media previews",
            detail: "Hover Calendar in the Dock for today's events, or a playing app for its controls.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
        WhatsNewEntry(id: "seasonal", symbol: "sparkles", title: "Seasonal touches",
            detail: "Turn them on and the notch, the tank and the buddy dress up for holidays and birthdays you choose.",
            tryIt: .settings(page: "toys"), opens: "Opens Utilities & Toys"),
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
        var asksWaiting = false
    }

    /// Whether now is a moment the window may take: the monitor has
    /// something to show, someone is at the Mac, and no film or
    /// full-screen work is in front.
    static func isRight(_ moment: Moment) -> Bool {
        moment.coreLive && !moment.locked && !moment.fullScreenInFront && !moment.asksWaiting
    }
}
