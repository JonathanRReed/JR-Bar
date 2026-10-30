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
    static let releaseID = "0.10.2"

    /// The header's one line.
    static let headline = "Every plan, every provider, and more of your Mac in the Dock."

    /// The window has room for this many rows and no more: the lead and
    /// four cards. The view draws exactly this many.
    static let maximumRows = 5

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(id: "plan-meters", symbol: "chart.bar", title: "Meters that fit your plan",
            detail: "One limit gets a full-width bar, two limits sit side by side, and credits and daily allowances finally show.",
            tryIt: .panel(toggle: false), opens: "Opens the panel"),
        WhatsNewEntry(id: "connect-factory", symbol: "person.badge.key", title: "Factory and Devin connect again",
            detail: "Choose the browser profile where you're signed in, allow it, and JR-Bar reads your subscription.",
            tryIt: .settings(page: "providers"), opens: "Opens Providers"),
        WhatsNewEntry(id: "dock-cards", symbol: "dock.rectangle", title: "New Dock previews",
            detail: "Hover Mail, Music, Reminders, Shortcuts, Messages or Calendar for a card of its own.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
        WhatsNewEntry(id: "t3-open", symbol: "arrow.up.forward.app", title: "Open lands in T3 Code",
            detail: "Open on an agent running in T3 Code goes straight to its thread."),
        WhatsNewEntry(id: "permissions", symbol: "lock.open", title: "Allow Access works",
            detail: "Calendar, Reminders, the camera and system audio can ask for access, and every Allow button now does something.",
            tryIt: .settings(page: "privacy"), opens: "Opens Privacy"),
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
