import JRBarCore
import SwiftUI

/// Hands its content the stage of a wait that started at `since`
/// (`WaitPolicy`). One `TimelineView` on an explicit schedule — the
/// wait's start and its two thresholds (`WaitPolicy.schedule`) — so a
/// live wait costs two updates and no frame clock, and no wait costs
/// nothing; the same view either way, so the content keeps its identity
/// as a wait starts and ends. A render proof's `WaitStill` reads its
/// own clock instead.
struct WaitStageReader<Content: View>: View {
    let since: Date?
    @ViewBuilder let content: (WaitStage) -> Content
    @Environment(\.waitStill) private var still

    var body: some View {
        if let still {
            content(WaitPolicy.stage(since: since, now: still.now))
        } else {
            TimelineView(.explicit(WaitPolicy.schedule(since: since))) { context in
                staged(WaitPolicy.stage(since: since, now: context.date))
            }
        }
    }

    /// A timeline's update carries no animation, so a stage's change
    /// brings its own: whatever the content fades in or out as the stage
    /// moves — an orb, a note, a mark giving way — fades rather than
    /// cuts.
    private func staged(_ stage: WaitStage) -> some View {
        content(stage).animation(WaitPolicy.stageChange, value: stage)
    }
}

/// A wait drawn by the rule: nothing for its first two seconds, its slot
/// held so nothing moves when it shows, then the system spinner — or,
/// for an agent's work or a search, a `ThinkingOrb` of it. The orb says
/// an agent is busy, never that something is loading, so an ordinary
/// load keeps the spinner and only loses the flash. `since` nil times
/// the wait from when this view appeared, which is when its `if busy`
/// put it on screen.
///
/// `quiet` is what shows before then: nothing (the default), or the
/// control's own label, so a button that starts a quick job keeps its
/// face instead of blinking a spinner. The label stays in the layout
/// under the spinner, so the button never narrows.
struct DelayedWait<Quiet: View>: View {
    var since: Date?
    /// What the agent or search is doing; nil — any other load — draws
    /// the system spinner.
    var activity: AgentActivity?
    /// An orb's ink: the secondary label colour, as light as the system
    /// spinner it stands in for.
    var tint: Color = .secondary
    var size: CGFloat = 14
    let quiet: Quiet
    /// When this wait appeared — the start of a wait that names none.
    @ViewState private var appeared = Date()

    init(since: Date? = nil, activity: AgentActivity? = nil, tint: Color = .secondary,
         size: CGFloat = 14, @ViewBuilder quiet: () -> Quiet) {
        self.since = since
        self.activity = activity
        self.tint = tint
        self.size = size
        self.quiet = quiet()
    }

    var body: some View {
        WaitStageReader(since: since ?? appeared) { stage in
            if Quiet.self == EmptyView.self {
                indicator(shown: stage.showsOrb)
            } else {
                quiet
                    .opacity(stage.showsOrb ? 0 : 1)
                    .overlay { indicator(shown: stage.showsOrb) }
            }
        }
    }

    private func indicator(shown: Bool) -> some View {
        WaitIndicator(activity: activity, tint: tint, size: size, shown: shown)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
    }
}

extension DelayedWait where Quiet == EmptyView {
    init(since: Date? = nil, activity: AgentActivity? = nil, tint: Color = .secondary, size: CGFloat = 14) {
        self.init(since: since, activity: activity, tint: tint, size: size) { EmptyView() }
    }
}

/// What a `DelayedWait` draws once it shows: the system spinner at the
/// control size nearest `size`, or an orb that runs only while shown and
/// only while its window is on screen — a window kept alive but ordered
/// out (the Dock's preview, the Data Hoarder after its close) runs no
/// clock for it.
struct WaitIndicator: View {
    let activity: AgentActivity?
    let tint: Color
    let size: CGFloat
    let shown: Bool
    @ViewState private var onScreen = true
    @Environment(\.waitStill) private var still

    /// The spinner's size: mini for the 12 pt slots, small otherwise —
    /// the sizes the call sites used before the rule.
    static func controlSize(for size: CGFloat) -> ControlSize { size < 14 ? .mini : .small }

    var body: some View {
        if let activity {
            ThinkingOrb(activity: activity, tint: tint, size: size, animating: shown && onScreen)
                .background {
                    if still == nil { WindowVisibilityReader { onScreen = $0 } }
                }
        } else {
            ProgressView().controlSize(Self.controlSize(for: size))
        }
    }
}

extension View {
    /// Keeps a view off screen for a wait's first two seconds: the rule
    /// for a spinner that is a big empty state's only content — kept as
    /// it is, only no longer flashed by a quick load.
    func delayedReveal() -> some View {
        modifier(DelayedRevealModifier())
    }

    /// The wait rule's beam: from three seconds into a wait that started
    /// at `since`, a border beam on this element; nothing before, and
    /// nothing with no wait. The element itself stays outside the wait's
    /// clock.
    func waitBeam(since: Date?, track: BeamTrack, tint: Color) -> some View {
        overlay {
            WaitStageReader(since: since) { stage in
                Color.clear.borderBeam(active: stage.showsBeam, track: track, tint: tint)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct DelayedRevealModifier: ViewModifier {
    @ViewState private var appeared = Date()

    func body(content: Content) -> some View {
        WaitStageReader(since: appeared) { stage in
            content.opacity(stage.showsOrb ? 1 : 0)
        }
    }
}

// MARK: - Placements

/// The session row's mark, in a slot every row shares: a working row
/// shows a `ThinkingOrb` of what its agent is doing, tinted with its
/// provider; everything else keeps its `ActivityMark` (an ask's amber,
/// done's check, failed's cross, idle's still dot). The slot's size
/// never depends on which, so the trailing column never moves.
struct SessionRowMark: View {
    let activity: SessionActivity
    let agentActivity: AgentActivity?
    let accent: Color
    let reduced: Bool
    /// The panel is open: only then does anything move.
    let active: Bool
    /// A working row gone quiet: the orb holds still rather than claim
    /// work the feed has not reported.
    var quiet = false

    /// The slot's side, the orb's size: a line of the row's 11 pt type.
    static let slot: CGFloat = 14

    /// What the slot draws for a row.
    enum Kind: Equatable {
        case orb(AgentActivity)
        case mark(SessionActivity)
    }

    static func kind(activity: SessionActivity, agentActivity: AgentActivity?) -> Kind {
        if activity == .working, let agentActivity { return .orb(agentActivity) }
        return .mark(activity)
    }

    /// The slot's size for any row — the same for every kind.
    static func slotSize(for kind: Kind) -> CGSize { CGSize(width: slot, height: slot) }

    var body: some View {
        let kind = Self.kind(activity: activity, agentActivity: agentActivity)
        let size = Self.slotSize(for: kind)
        Group {
            switch kind {
            case .orb(let doing):
                ThinkingOrb(activity: doing, tint: accent, size: Self.slot,
                            animating: active && !quiet, reduced: reduced)
            case .mark(let state):
                ActivityMark(activity: state, accent: accent, reduced: reduced, active: active)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// An ask card's mark while its answer is on the wire (`AskAnswerDesk`'s
/// pending set, which every surface shares): its usual amber pulse under
/// two seconds; from two, an amber orb in its place, which moves until
/// the card's own beam arrives at three and then holds still, so the
/// beam is the one thing moving. Display only — nothing here sends,
/// retries or answers.
struct AskWaitMark: View {
    let since: Date?
    let accent: Color
    let reduced: Bool
    let active: Bool
    /// The orb's size; it draws centred on the 8 pt mark, spilling past
    /// it rather than moving the elapsed time under it.
    static let orbSize: CGFloat = 12

    var body: some View {
        WaitStageReader(since: since) { stage in
            ActivityMark(activity: .waiting, accent: accent, reduced: reduced,
                         active: active && stage == .quiet)
                .opacity(stage.showsOrb ? 0 : 1)
                .overlay {
                    if stage.showsOrb {
                        ThinkingOrb(activity: .thinking, tint: SessionActivity.waiting.tint,
                                    size: Self.orbSize, animating: active && stage == .orb, reduced: reduced)
                            .frame(width: Self.orbSize, height: Self.orbSize)
                            .transition(.opacity)
                    }
                }
        }
        .help(since == nil ? "" : "Your answer is on its way")
    }
}

/// The palette's footer status while its slower sources — the front
/// app's menus, History, the archive — are still reading: nothing for
/// two seconds, then an orb and a word, in the footer's own greys.
struct PaletteWaitNote: View {
    let since: Date?

    var body: some View {
        WaitStageReader(since: since) { stage in
            if stage.showsOrb {
                HStack(spacing: 5) {
                    ThinkingOrb(activity: .searching, tint: .secondary, size: 14)
                        .accessibilityHidden(true)
                    Text("Searching…")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
