import Foundation

/// Everything the notch island shows, reduced to plain data so the view
/// never walks `CoreSession`s and the panel never guesses its own size:
/// `summarize` makes the idle dots, the live rows and the status line in
/// one pass; `meters` picks each provider's headline usage window;
/// `NotchIslandLayout` owns the frame math that hangs the panel under
/// the notch. Pure, so `NotchIslandTests` pins it without a screen.
public struct NotchIslandRow: Equatable, Sendable, Identifiable {
    /// The session id.
    public var id: String
    /// `SessionLabel.display`: short, no UUID, no leading provider name.
    public var label: String
    /// The provider id — the app resolves its name and colour.
    public var provider: String
    public var activity: SessionActivity

    public init(id: String, label: String, provider: String, activity: SessionActivity) {
        self.id = id
        self.label = label
        self.provider = provider
        self.activity = activity
    }
}

/// One provider's headline meter in the card: its first usage window's
/// reading. `percent` nil is a stated unknown, never a zero — the same
/// contract `CoreUsageWindow.usedPct` carries.
public struct NotchIslandMeter: Equatable, Sendable, Identifiable {
    /// `CoreProviderUsage.identity` — stable across multi-account rows.
    public var id: String
    public var provider: String
    /// The window's short name (`5h`, `7d`, `Daily`).
    public var window: String
    public var percent: Double?

    public init(id: String, provider: String, window: String, percent: Double?) {
        self.id = id
        self.provider = provider
        self.window = window
        self.percent = percent
    }

    /// `42%`, or `—` when the provider stated no number.
    public var percentText: String { UsageWindowLabel.percent(percent) }
}

public struct NotchIslandSummary: Equatable, Sendable {
    public var working = 0
    public var waiting = 0
    public var failed = 0
    /// Providers with working sessions, busiest first, id tiebreak — the
    /// idle capsule's dots, in order.
    public var workingProviders: [String] = []
    /// The live sessions (working, waiting, failed) in the panel's
    /// precedence — the card's rows, uncapped; the caller truncates at
    /// `NotchIsland.rowLimit`.
    public var rows: [NotchIslandRow] = []
    /// "3 working · 1 waiting" — the header and the accessibility value.
    public var statusLine = "Nothing on the clock"

    public init() {}
}

/// The notch system's one card surface — the exactly-one-surface rule
/// as a single answer, so the island and the glass card can never be up
/// together and a switched-off utility draws nothing: the island while
/// ours is drawn, the detached glass card while the utility is on but
/// the island is not (the island hidden, an external renderer owning
/// the notch, or the island not yet on screen), and nothing while the
/// utility is off.
public enum NotchSurface: String, Equatable, Sendable {
    case island, glass, none
}

public enum NotchIsland {
    /// Which surface may present the notch card for a settings snapshot.
    /// `enabled = false` answers `.none` outright — the island is
    /// parked, no capsule may draw, and the glass fallback stays dark;
    /// `islandVisible` alone never revives it.
    public static func surface(_ settings: NotchSettings, islandVisible: Bool) -> NotchSurface {
        guard settings.enabled else { return .none }
        return settings.provider == .jrbar && settings.islandEnabled && islandVisible
            ? .island : .glass
    }

    /// Rows the card shows before a "+N more" line.
    public static let rowLimit = 5
    /// Usage meters the card shows.
    public static let meterLimit = 3
    /// Provider dots the idle capsule shows.
    public static let dotLimit = 6

    /// One pass over the session list: the counts, the working-provider
    /// dots, the live rows and the status line all fall out of the same
    /// `SessionActivity.reduce` calls, the way `NotchBuddyToy.summary`
    /// keeps its pieces from disagreeing.
    public static func summarize(_ sessions: [CoreSession]) -> NotchIslandSummary {
        var s = NotchIslandSummary()
        var tally: [String: Int] = [:]
        for session in sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                s.working += 1
                tally[session.provider, default: 0] += 1
            case .waiting: s.waiting += 1
            case .failed: s.failed += 1
            case .done, .ended, .idle: break
            }
            switch activity {
            case .working, .waiting, .failed:
                s.rows.append(NotchIslandRow(
                    id: session.id,
                    label: SessionLabel.display(label: session.label, shortId: session.shortId,
                                                id: session.id, provider: session.provider),
                    provider: session.provider,
                    activity: activity))
            case .done, .ended, .idle: break
            }
        }
        // Busiest first; the id tiebreak keeps a split house from
        // flickering between ticks, the same rule the buddy uses.
        s.workingProviders = tally.keys.sorted { a, b in
            tally[a]! != tally[b]! ? tally[a]! > tally[b]! : a < b
        }
        s.rows.sort { a, b in
            a.activity.sortRank != b.activity.sortRank
                ? a.activity.sortRank < b.activity.sortRank
                : a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if !parts.isEmpty { s.statusLine = parts.joined(separator: " · ") }
        return s
    }

    /// Each provider's first window as a meter — the headline reading —
    /// skipping providers that carry no windows at all. Ordered as the
    /// daemon sent them, capped at `meterLimit`.
    public static func meters(_ usage: CoreUsage?) -> [NotchIslandMeter] {
        (usage?.providers ?? []).compactMap { provider in
            guard let window = provider.windows.first else { return nil }
            return NotchIslandMeter(id: provider.identity, provider: provider.id,
                                    window: window.shortName, percent: window.usedPct)
        }.prefix(meterLimit).map { $0 }
    }

    /// The idle content's width: `dotLimit`-capped provider dots plus the
    /// waiting/failed dots, the live count, and the spacing between them —
    /// deterministic, so the panel sizes itself without asking the view
    /// and nothing invisible hangs over the menu bar.
    public static func idleContentWidth(_ summary: NotchIslandSummary) -> CGFloat {
        let dots = min(summary.workingProviders.count, dotLimit)
            + (summary.waiting > 0 ? 1 : 0) + (summary.failed > 0 ? 1 : 0)
        let live = summary.working + summary.waiting + summary.failed
        guard dots > 0 else { return 4 }   // the lone resting dot
        var width = CGFloat(dots) * 5 + CGFloat(dots - 1) * 4
        if live > 0 { width += 4 + (live < 100 ? 14 : 22) }
        return width
    }
}

/// The island's frame math. The panel is exactly the drawn shape — a
/// capsule pinned to the screen's top edge, centred on the notch slot —
/// so a transparent window never swallows a menu-bar click.
public enum NotchIslandLayout {
    /// Points the idle capsule reaches past each shoulder of the notch.
    public static let shoulder: CGFloat = 12
    public static let idleMinWidth: CGFloat = 96
    /// Room the frame leaves at the screen's side edges.
    public static let edgeMargin: CGFloat = 8
    /// On a notch-less screen the island floats this far under the top
    /// edge instead of hugging it.
    public static let floatingTopInset: CGFloat = 6

    /// The notch slot — centre and width — from the screen's menu-bar
    /// areas (`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), nil where
    /// there is no notch to measure.
    public static func slot(left: CGRect?, right: CGRect?) -> (centerX: CGFloat, width: CGFloat)? {
        guard let left, let right else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return ((left.maxX + right.minX) / 2, width)
    }

    /// Points of dead space the island keeps under the notch while the
    /// Screen Bar is live, on the faces that drop below it (the notice
    /// capsule and the expanded card): the LED band ends ~8 pt below
    /// the notch (6 pt of band plus the halo bleed) and the island's
    /// window sits one level under the bar, so content clears the
    /// strip. The idle face needs none — it tucks into the notch's own
    /// depth, ending flush with the hardware's bottom edge.
    public static let ledBandClearance: CGFloat = 12

    /// Points the expanded card reaches past each side of the notch
    /// slot — modest symmetric wings, so the grown card reads as the
    /// notch itself swelling (Alcove-style), never a detached wide
    /// panel parked over it.
    public static let expandedShoulder: CGFloat = 30
    public static let expandedMinWidth: CGFloat = 240
    public static let expandedMaxWidth: CGFloat = 380
    /// Clearance the expanded card's content keeps under the notch.
    public static let expandedNotchInset: CGFloat = 8

    /// The grown card's width: the slot plus its shoulders, bounded —
    /// wider than the notice, never the whole menu bar.
    public static func expandedWidth(slotWidth: CGFloat) -> CGFloat {
        min(expandedMaxWidth, max(expandedMinWidth, slotWidth + 2 * expandedShoulder))
    }

    /// How far below the window's top the expanded card's content
    /// starts — past the notch's own depth, its inset and a live band's
    /// clearance. Notch-less floats get just the inset.
    public static func expandedTopInset(notchDepth: CGFloat, ledClearance: CGFloat) -> CGFloat {
        notchDepth > 0 ? notchDepth + expandedNotchInset + ledClearance : expandedNotchInset
    }

    /// The collapsed capsule: at least as wide as the notch plus a small
    /// shoulder each side — the island reads as the notch grown, not a
    /// pill parked beside it — and exactly the notch's depth, so at rest
    /// nothing but the Screen Bar's band draws below the hardware.
    /// Notch-less screens get a floating pill sized to the content.
    public static func idleSize(slotWidth: CGFloat, notchDepth: CGFloat, contentWidth: CGFloat) -> CGSize {
        guard notchDepth > 0 else {
            return CGSize(width: max(idleMinWidth, contentWidth + 24), height: 24)
        }
        return CGSize(width: max(idleMinWidth, slotWidth + 2 * shoulder, contentWidth + 28),
                      height: notchDepth)
    }

    /// The hover wink: a resting island under the pointer swells this
    /// much — a whisper that it is alive — while the intent debounce
    /// decides whether the hover meant the card. A pointer passing
    /// through only ever earns this, never the grow.
    public static let peekGrow: CGFloat = 3

    /// The window's frame: centred on `centerX`, its top edge `topInset`
    /// below the screen's top edge, clamped inside the screen with
    /// `edgeMargin` to spare.
    public static func frame(screenFrame: CGRect, centerX: CGFloat, size: CGSize, topInset: CGFloat = 0) -> CGRect {
        let width = min(size.width, max(0, screenFrame.width - 2 * edgeMargin))
        let x = min(screenFrame.maxX - edgeMargin - width,
                    max(screenFrame.minX + edgeMargin, centerX - width / 2))
        return CGRect(x: x, y: screenFrame.maxY - max(0, topInset) - size.height,
                      width: width, height: size.height)
    }
}

extension AlcoveNoticeKind {
    /// Which capsule deserves the queue's one waiting slot: an ask
    /// outranks a failure, and both outrun the ambient kinds. Lower
    /// wins. `AlcoveCapsuleQueue` itself stays newest-wins; the
    /// island's toy reads this at the door so a late power blip never
    /// displaces a waiting ask.
    public var queueRank: Int {
        switch self {
        case .ask: return 0
        case .failed: return 1
        case .completed: return 2
        case .quotaReset: return 3
        case .charging: return 4
        }
    }
}

/// The island's press-and-pull, pure so the flick rules are testable
/// without a pointer: a pull on the resting island stretches it open
/// downward; a pull on the grown card slides it under the finger.
/// Release commits on honest travel OR on flick speed — a fast short
/// pull is still a swipe — and the pull's own visuals meet `tanh`
/// friction past their soft limits, never a wall. Translations and
/// velocities are screen-space: upward positive.
public struct NotchPullGesture: Equatable, Sendable {
    /// Which face the pull acts on.
    public enum Surface: String, Equatable, Sendable {
        /// The resting island — idle or a notice capsule. Only a pull
        /// downward engages, and it grows.
        case rest
        /// The grown card: any vertical pull slides it off the notch.
        case card
    }

    /// The release verdict.
    public enum Verdict: Equatable, Sendable {
        /// The pull committed — the surface's act: open, fold, dismiss.
        case commit
        /// Engaged but short and slow — the surface springs back.
        case retreat
        /// Never really a pull: it stays the click it was.
        case click
    }

    /// Travel that commits a slow pull.
    public static let commitTravel: CGFloat = 36
    /// Release speed (points/second) that commits at any travel — the
    /// flick.
    public static let flickVelocity: CGFloat = 700
    /// A pull this short was never a pull — it stays a click.
    public static let engageTravel: CGFloat = 4
    /// Seconds of finger-stillness that bleed a flick to nothing — a
    /// pull held then released gently is a cancel, not a swipe.
    public static let flickMemory: TimeInterval = 0.15
    /// The soft limits past which travel meets `tanh` friction: the
    /// resting island's downward stretch and the grown card's slide.
    public static let restStretchLimit: CGFloat = 64
    public static let cardSlideLimit: CGFloat = 56

    /// The finger's travel since the press, upward positive.
    public private(set) var translation: CGFloat = 0
    /// The furthest the pull ever reached — engagement is "it moved at
    /// all", so an out-and-back pull is a pull, not a click.
    public private(set) var maxTravel: CGFloat = 0
    private var velocity: CGFloat = 0
    /// The previous drag sample — the velocity's other half.
    private var last: Sample?

    private struct Sample: Equatable, Sendable {
        var translation: CGFloat
        var at: TimeInterval
    }

    public init() {}

    /// True once the pull has honestly engaged — short of this the
    /// gesture is still just a click pending.
    public var engaged: Bool { maxTravel >= Self.engageTravel }

    /// One drag sample: the finger's total translation at `now` (any
    /// monotonic clock — the caller's is `NSEvent.timestamp`).
    public mutating func move(translation new: CGFloat, at now: TimeInterval) {
        if let last {
            let dt = now - last.at
            // The floor only guards the divide — a high-rate input's
            // 2 ms ticks still feed the flick; the ceiling drops a
            // long-parked sample's meaningless slope.
            if dt > 0.0005, dt < 0.5 {
                let instant = (new - last.translation) / CGFloat(dt)
                // EMA — a mouse's event stream jitters; the flick reads
                // the smoothed speed, not the last tick's accident.
                velocity += (instant - velocity) * 0.4
            }
        }
        last = Sample(translation: new, at: now)
        translation = new
        maxTravel = max(maxTravel, abs(new))
    }

    /// The flick's speed at release: a finger that stopped moving
    /// `flickMemory` ago carries no speed.
    public func flickSpeed(at now: TimeInterval) -> CGFloat {
        guard let last else { return 0 }
        let age = now - last.at
        guard age < Self.flickMemory else { return 0 }
        return velocity * CGFloat(1.0 - age / Self.flickMemory)
    }

    /// What the surface draws for the current pull — damped travel, in
    /// the surface's own convention: positive stretch for `.rest`,
    /// signed slide for `.card` (upward positive, like the finger).
    public func offset(for surface: Surface) -> CGFloat {
        switch surface {
        case .rest:
            return Self.restStretchLimit * tanh(max(0, -translation) / Self.restStretchLimit)
        case .card:
            return Self.cardSlideLimit * tanh(translation / Self.cardSlideLimit)
        }
    }

    /// The release: `.commit` when the pull went far or fast enough in
    /// a direction the surface answers, `.retreat` when it engaged and
    /// let go short, `.click` when it never really was a pull.
    public func release(at now: TimeInterval, surface: Surface) -> Verdict {
        guard engaged else { return .click }
        let flick = flickSpeed(at: now)
        switch surface {
        case .rest:
            // Only a downward pull acts — an upward wander just lets go.
            guard translation < 0 else { return .retreat }
            return (-translation >= Self.commitTravel || -flick >= Self.flickVelocity)
                ? .commit : .retreat
        case .card:
            // Either way off the notch dismisses — down peels the card
            // away, up folds it back in.
            return (abs(translation) >= Self.commitTravel || abs(flick) >= Self.flickVelocity)
                ? .commit : .retreat
        }
    }
}

/// The island's interruptible frame motion: four scalar springs — one
/// per rect edge — integrated on a display link, so a retarget
/// mid-flight keeps the position and velocity the frame actually has
/// and bends toward the new target instead of restarting (or snapping,
/// the way a second `animator().setFrame` does). Pure — the window
/// drives it on ticks, the tests drive it by hand.
public struct NotchFrameSpring: Equatable, Sendable {
    /// One axis of the frame: position and velocity in screen points.
    public struct Axis: Equatable, Sendable {
        public var value: CGFloat
        public var velocity: CGFloat

        public init(value: CGFloat, velocity: CGFloat = 0) {
            self.value = value
            self.velocity = velocity
        }
    }

    /// How a retarget feels — roughly SwiftUI's `response` /
    /// `dampingFraction` pair. The grown card swells a touch slower
    /// than the fold-home — collapse is always the faster gesture, the
    /// way a dismissal should feel — and content-only nudges sit
    /// between. Damping stays ≥ 0.86: a swell, never a bounce.
    public struct Motion: Equatable, Sendable {
        public var response: CGFloat
        public var dampingFraction: CGFloat

        public init(response: CGFloat, dampingFraction: CGFloat) {
            self.response = response
            self.dampingFraction = dampingFraction
        }
    }

    /// The grow: the island opening into the card, or any swell.
    public static let expandMotion = Motion(response: 0.40, dampingFraction: 0.86)
    /// The fold: collapse runs a beat faster than the grow.
    public static let collapseMotion = Motion(response: 0.32, dampingFraction: 0.95)
    /// Content-driven nudges — a dot arriving, a row refilling.
    public static let morphMotion = Motion(response: 0.30, dampingFraction: 0.9)

    /// Which way a frame change reads: growing swells, shrinking folds.
    public static func motion(from current: CGRect, to target: CGRect) -> Motion {
        if target.height > current.height + 0.5 || target.width > current.width + 0.5 {
            return expandMotion
        }
        if target.height < current.height - 0.5 || target.width < current.width - 0.5 {
            return collapseMotion
        }
        return morphMotion
    }

    public private(set) var target: CGRect
    public var motion: Motion
    private var xAxis = Axis(value: 0)
    private var yAxis = Axis(value: 0)
    private var wAxis = Axis(value: 0)
    private var hAxis = Axis(value: 0)

    /// A spring sitting at `frame`, aimed at `target` (itself, when
    /// nil). `motion` is the feel the next retarget runs at.
    public init(at frame: CGRect, motion: Motion = NotchFrameSpring.morphMotion, target: CGRect? = nil) {
        self.motion = motion
        self.target = target ?? frame
        xAxis = Axis(value: frame.minX)
        yAxis = Axis(value: frame.minY)
        wAxis = Axis(value: frame.width)
        hAxis = Axis(value: frame.height)
    }

    /// The frame the spring currently draws.
    public var frame: CGRect {
        CGRect(x: xAxis.value, y: yAxis.value, width: wAxis.value, height: hAxis.value)
    }

    /// Aim at a new target: position and velocity carry over — that is
    /// the whole point, an interrupted morph continues from where it
    /// visibly was.
    public mutating func retarget(_ target: CGRect, motion: Motion) {
        self.target = target
        self.motion = motion
    }

    /// One display tick. Semi-implicit Euler at a fixed ~120 Hz
    /// sub-step — the spring stays stable however late a tick arrives
    /// (a clamped big `dt` explodes a stiff spring instead; sub-steps
    /// land it). `dt` itself is capped at half a second so a slept
    /// display link can't wind the frame up.
    /// Returns true while the frame is still moving.
    @discardableResult
    public mutating func integrate(dt: TimeInterval) -> Bool {
        var remaining = min(max(dt, 0), 0.5)
        let omega = 2 * CGFloat.pi / max(motion.response, 0.01)
        let zeta = motion.dampingFraction
        func chase(_ axis: inout Axis, toward destination: CGFloat, _ h: CGFloat) {
            let accel = omega * omega * (destination - axis.value)
                - 2 * zeta * omega * axis.velocity
            axis.velocity += accel * h
            axis.value += axis.velocity * h
        }
        while remaining > 0 {
            let h = CGFloat(min(remaining, 1.0 / 120))
            chase(&xAxis, toward: target.minX, h)
            chase(&yAxis, toward: target.minY, h)
            chase(&wAxis, toward: target.width, h)
            chase(&hAxis, toward: target.height, h)
            remaining -= TimeInterval(h)
        }
        return !settled
    }

    /// Still moving = any axis off its edge or still carrying speed.
    public var settled: Bool {
        func done(_ axis: Axis, _ destination: CGFloat) -> Bool {
            abs(axis.velocity) < 0.8 && abs(axis.value - destination) < 0.5
        }
        return done(xAxis, target.minX) && done(yAxis, target.minY)
            && done(wAxis, target.width) && done(hAxis, target.height)
    }

    /// Land exactly on the target — the last tick's write, so the
    /// frame can never rest a fraction of a point off.
    public mutating func snap() {
        xAxis = Axis(value: target.minX)
        yAxis = Axis(value: target.minY)
        wAxis = Axis(value: target.width)
        hAxis = Axis(value: target.height)
    }
}
