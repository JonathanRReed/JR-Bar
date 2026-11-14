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
    static let releaseID = "0.10.3"

    /// The header's one line.
    static let headline = "A reef in the tank, a truer Fold, and a much lighter app."

    /// The window has room for this many rows and no more: the lead and
    /// four cards. The view draws exactly this many.
    static let maximumRows = 5

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(id: "reef", symbol: "leaf", title: "The Aquarium is a game",
            detail: "Fish wear their own colours, and a reef of four builders turns your agents' work into pearls you harvest with one tap.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(id: "fold-duo", symbol: "laptopcomputer", title: "Fold shades like the Duo",
            detail: "Close the lid partway and the hinge band stays lit while the glass darkens and blurs toward its top.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
        WhatsNewEntry(id: "dock-pictures", symbol: "dock.rectangle", title: "Dock previews open on pictures",
            detail: "Hover an icon you looked at in the last ten minutes and its windows' pictures are there at once.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
        WhatsNewEntry(id: "claude-background", symbol: "clock.arrow.2.circlepath", title: "Background jobs stay Working",
            detail: "A Claude Code turn that ends with a job still running stays Working, and compacting an idle session no longer does."),
        WhatsNewEntry(id: "lighter", symbol: "gauge.with.dots.needle.33percent", title: "Lighter on your Mac",
            detail: "While agents work the app uses about a quarter of the processor time it did and wakes far less often."),
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
