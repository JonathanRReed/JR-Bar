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
    static let releaseID = "0.9.13"

    /// The header's one line.
    static let headline = "Provider choices survive upgrades, and timeline and Screen Bar work is bounded."

    /// The window has room for this many rows and no more.
    static let maximumRows = 8

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            id: "hooks", symbol: "checklist",
            title: "Hooks stay your choice",
            detail: "Fresh setup connects chosen providers, and upgrades preserve disabled integrations and custom log destinations.",
            tryIt: .settings(page: "agents"), opens: "Opens Settings › Agents"),
        WhatsNewEntry(
            id: "fold", symbol: "laptopcomputer",
            title: "Fold returns to rest",
            detail: "Resting-angle mode relearns a still lid with any parking delay and eases back to the desktop.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where the Fold card is"),
        WhatsNewEntry(
            id: "aquarium", symbol: "fish",
            title: "Fish share frame work",
            detail: "Swimming and drawing reuse completion meals, including pellets eaten in the current frame.",
            tryIt: .aquarium, opens: "Opens the Aquarium"),
        WhatsNewEntry(
            id: "drag", symbol: "menubar.rectangle",
            title: "Menu clicks reach the icon",
            detail: "A click accepted by JR-Bar's icon still opens it if the panel moves before the action runs.",
            keys: "⌘ drag"),
        WhatsNewEntry(
            id: "dot", symbol: "light.strip.2",
            title: "Screen Bar plans off-main",
            detail: "One active plan and the latest pending program keep hidden bars from starting new planning work.",
            tryIt: .settings(page: "devices"), opens: "Opens Settings › Devices, where Pro & Dot is"),
        WhatsNewEntry(
            id: "resets", symbol: "party.popper",
            title: "Early weekly resets celebrate",
            detail: "Stable readings confirm early weekly refills without carrying reset comparisons between Claude accounts.",
            tryIt: .settings(page: "toys"), opens: "Opens Settings › Toys, where Confetti is"),
        WhatsNewEntry(
            id: "archive", symbol: "archivebox",
            title: "Timelines use less memory",
            detail: "Reconstruction streams transcript lines and indexes failure-story tools while preserving timeline order.",
            tryIt: .settings(page: "utilities"), opens: "Opens Settings › Utilities, where Data Hoarder is"),
        WhatsNewEntry(
            id: "dock", symbol: "dock.rectangle",
            title: "Dock previews fit their windows",
            detail: "Long names stay within the thumbnail width, and Tight previews center their controls below the name.",
            tryIt: .settings(page: "utilities"), opens: "Opens Settings › Utilities, where Dock is"),
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
