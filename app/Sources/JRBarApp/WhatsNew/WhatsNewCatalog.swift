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
    static let releaseID = "0.9.17.2"

    /// The header's one line.
    static let headline = "Lighting, provider connections and menu-bar fixes."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "sweep-background", symbol: "light.beacon.max",
            title: "Sweep background",
            detail: "Knight Rider, Scanner and Pendulum clear inherited light and offer a Background glow control.",
            tryIt: .window(.effects), opens: "Opens Effect Studio"),
        WhatsNewEntry(
            id: "working-motion", symbol: "waveform.path",
            title: "Working motion",
            detail: "Your selected motion stays intact when several sessions from one provider work at once.",
            tryIt: .window(.effects), opens: "Opens Effect Studio"),
        WhatsNewEntry(
            id: "studio-controls", symbol: "slider.horizontal.3",
            title: "Studio controls",
            detail: "Edited parameters follow the assignment, and current-output previews show what the monitor sends.",
            tryIt: .window(.effects), opens: "Opens Effect Studio"),
        WhatsNewEntry(
            id: "provider-order", symbol: "list.bullet",
            title: "Provider visibility and order",
            detail: "Choose which providers appear in the menu-bar icon and move them into your preferred order.",
            tryIt: .settings(page: "general"), opens: "Opens General settings"),
        WhatsNewEntry(
            id: "provider-recovery", symbol: "key",
            title: "Connection recovery",
            detail: "Claude distinguishes lost Keychain permission, and Factory can follow browser renewals with explicit permission.",
            tryIt: .settings(page: "usage"), opens: "Opens Agents & Usage"),
        WhatsNewEntry(
            id: "closed-lid-display", symbol: "laptopcomputer",
            title: "Closed-lid display sleep",
            detail: "Agent holds request display sleep when the lid is closed and no external display is active.",
            tryIt: .settings(page: "general"), opens: "Opens General settings"),
        WhatsNewEntry(
            id: "menu-recovery", symbol: "menubar.rectangle",
            title: "Hidden menu items",
            detail: "The hiding fallback covers the blank reservation while keeping the JR-Bar icon exposed.",
            tryIt: .settings(page: "utilities"), opens: "Opens Utilities & Toys"),
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
