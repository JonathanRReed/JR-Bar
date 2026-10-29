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
    static let headline = "Permissions and sign-ins that work."

    /// The window has room for this many rows and no more: the lead and
    /// four cards. The view draws exactly this many.
    static let maximumRows = 5

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(id: "permissions", symbol: "lock.open", title: "Allow Access works",
            detail: "Calendar, Reminders, the camera and system audio can ask for access, and every Allow button now does something.",
            tryIt: .settings(page: "privacy"), opens: "Opens Privacy"),
        WhatsNewEntry(id: "connect-devin", symbol: "person.badge.key", title: "Connect Devin",
            detail: "Choose the browser profile where you signed in to Devin, allow access, and import.",
            tryIt: .settings(page: "providers"), opens: "Opens Providers"),
        WhatsNewEntry(id: "fix-actions", symbol: "arrow.triangle.2.circlepath", title: "The button that fixes it",
            detail: "A provider that needs you offers Sign in, Reconnect or Allow usage instead of Retry.",
            tryIt: .window(.usage), opens: "Opens Usage Center"),
        WhatsNewEntry(id: "plain-words", symbol: "text.bubble", title: "Plain words",
            detail: "Internal codes are gone, and History's events run in time order in your own clock.",
            tryIt: .window(.history), opens: "Opens History"),
        WhatsNewEntry(id: "tidy-tank", symbol: "fish", title: "A tidier tank",
            detail: "Fish names never pile up, and asking or working fish keep theirs first."),
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
