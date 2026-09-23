import Foundation

/// Corners follow the presented height so interrupted resizes keep one outline.
public enum NotchSilhouetteGeometry {
    /// The grown island and the higher Screen Bar backing share this
    /// corner. Card content keeps clear of the same bound.
    public static let maximumExpandedRadius: CGFloat = 28

    public static func radius(size: CGSize, notchDepth: CGFloat, restingRadius: CGFloat) -> CGFloat {
        let limit = max(0, min(size.width / 2, size.height / 2))
        guard notchDepth > 0 else { return min(maximumExpandedRadius, limit) }
        let rest = max(0, restingRadius)
        let progress = min(1, max(0, (size.height - notchDepth - 4) / 80))
        let eased = progress * progress * (3 - 2 * progress)
        return min(limit, rest + (max(maximumExpandedRadius, rest) - rest) * eased)
    }
}

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
    /// The open ask a waiting row carries — the card's inline Approve /
    /// Deny read it (`NotchAskVerbs`); nil on every other row.
    public var ask: CoreAsk?

    public init(id: String, label: String, provider: String, activity: SessionActivity,
                ask: CoreAsk? = nil) {
        self.id = id
        self.label = label
        self.provider = provider
        self.activity = activity
        self.ask = ask
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
    /// The window's `resets_at` — the countdown the ring drains toward.
    public var resetsAt: Double?
    /// The lane's own length (5h → 18000 s) — a reset countdown needs a
    /// denominator; nil for a lane whose span is not one of the known
    /// horizons, and the ring simply carries no drain arc.
    public var windowSpan: TimeInterval?
    /// The provider's status feed names a live incident — the ear
    /// flips to the attention tone and the card row says so.
    public var incident: Bool

    public init(id: String, provider: String, window: String, percent: Double?,
                resetsAt: Double? = nil, windowSpan: TimeInterval? = nil, incident: Bool = false) {
        self.id = id
        self.provider = provider
        self.window = window
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowSpan = windowSpan
        self.incident = incident
    }

    /// `42%`, or `—` when the provider stated no number.
    public var percentText: String { UsageWindowLabel.percent(percent) }

    /// The fraction of the window still to run (1 → fresh, 0 → resetting
    /// now) — the drain arc the ear's ring carries under the fill.
    public func resetFraction(now: Date) -> Double? {
        guard let resetsAt, let windowSpan, windowSpan > 0 else { return nil }
        return min(1, max(0, (resetsAt - now.timeIntervalSince1970) / windowSpan))
    }
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
    /// The session that has waited longest on an answer — the amber
    /// count's click goes straight there. Ordered by the ask's own
    /// `opened_at`, then the session's `since`; nil when nobody waits.
    public var oldestWaiting: String?

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
    /// keeps its pieces from disagreeing. `asks` is `state.asks`: a
    /// waiting row carries the pinned ask over the one embedded in its
    /// session, the same precedence the panel's rows take (`liveAsk`).
    public static func summarize(_ sessions: [CoreSession], asks: [CoreAsk] = []) -> NotchIslandSummary {
        var s = NotchIslandSummary()
        var tally: [String: Int] = [:]
        var oldest: (id: String, at: Double)?
        for session in sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                s.working += 1
                tally[session.provider, default: 0] += 1
            case .waiting:
                s.waiting += 1
                // Unknown times sort last, so a stamped ask always wins
                // the jump over one the daemon could not date.
                let at = session.ask?.openedAt ?? session.since ?? .greatestFiniteMagnitude
                if oldest == nil || at < oldest!.at
                    || (at == oldest!.at && session.id < oldest!.id) {
                    oldest = (session.id, at)
                }
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
                    activity: activity,
                    ask: activity == .waiting ? liveAsk(for: session, asks: asks) : nil))
            case .done, .ended, .idle: break
            }
        }
        s.oldestWaiting = oldest?.id
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

    /// Each provider's headline window as a meter — the most-constrained
    /// lane, the same pick the menu bar and the Usage Center lead with
    /// (`CoreProviderUsage.headlineWindow`) — skipping providers that
    /// carry no windows at all. Ordered as the daemon sent them, capped
    /// at `meterLimit`.
    public static func meters(_ usage: CoreUsage?) -> [NotchIslandMeter] {
        (usage?.providers ?? []).compactMap { provider in
            guard let window = provider.headlineWindow else { return nil }
            return NotchIslandMeter(id: provider.identity, provider: provider.id,
                                    window: window.shortName, percent: window.usedPct,
                                    resetsAt: window.resetsAt,
                                    windowSpan: UsageWindowLabel.windowSpan(id: window.id, name: window.name),
                                    incident: provider.incident?.isEmpty == false)
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

/// What the resting island draws in each shoulder beside the notch.
/// Nothing ever sits under the hardware: the slot is the notch, and a
/// dot centred there is a dot nobody sees. The left shoulder is the
/// agent HUD — a dot per working provider and the live count; the
/// right shoulder is attention — the open-ask count in amber, a
/// failure count in red — or, when neither is up, the Now Playing
/// strip. While the Screen Bar draws its own ears over the same
/// shoulders the island stays a bare housing, so the two never stack.
public struct NotchIdleLayout: Equatable, Sendable {
    /// Points of content in the left shoulder; 0 draws nothing there.
    public var leftWidth: CGFloat = 0
    /// Points of content in the right shoulder; 0 draws nothing there.
    public var rightWidth: CGFloat = 0
    /// What the right shoulder carries.
    public var right: Right = .nothing
    /// The privacy dots — mic live, camera live — sharing the right
    /// shoulder, hugging the notch like the hardware LED they mirror.
    /// Quiet is the default and draws nothing.
    public var sensors: NotchSensorState = NotchSensorState()
    /// The idle face is a bare housing — the ears carry the HUD.
    public var bare: Bool = false

    public enum Right: Equatable, Sendable {
        case nothing
        /// Open asks — amber.
        case attention(count: Int)
        /// Failures — red.
        case failed(count: Int)
        case media
    }

    public init() {}

    /// The wider shoulder's content.
    public var contentWidth: CGFloat { max(leftWidth, rightWidth) }

    /// Each shoulder's own content width: nothing at all while bare —
    /// the housing is then exactly the notch, so no black reaches past
    /// the hardware and no menu-bar click lands on it — else the
    /// resting shoulder, or the content plus its air.
    public var leftShoulder: CGFloat {
        bare ? 0 : NotchIslandLayout.shoulderWidth(contentWidth: leftWidth)
    }
    public var rightShoulder: CGFloat {
        bare ? 0 : NotchIslandLayout.shoulderWidth(contentWidth: rightWidth)
    }
    /// The window's shoulder — the wider side, on both sides, so the
    /// window stays centred on the notch and every face (idle, notice,
    /// card) shares one centre: a morph between faces then swells in
    /// place instead of sliding sideways. Content hugs the notch inside
    /// it (`NotchIslandView.shoulders`), so the narrower side's spare
    /// room is at its outer end.
    public var windowShoulder: CGFloat { max(leftShoulder, rightShoulder) }
}

extension NotchIsland {
    /// Room a count takes beside its dot.
    static func countWidth(_ n: Int) -> CGFloat { n < 100 ? 14 : 22 }

    /// The resting island's shoulders for a summary. `earsDrawn` is the
    /// Screen Bar's own wings over the same shoulders: then the island
    /// is bare, whatever the summary says.
    public static func idleLayout(_ summary: NotchIslandSummary, media: AlcoveMedia?,
                                  earsDrawn: Bool,
                                  sensors: NotchSensorState = NotchSensorState()) -> NotchIdleLayout {
        var layout = NotchIdleLayout()
        if earsDrawn {
            layout.bare = true
            return layout
        }
        let dots = min(summary.workingProviders.count, dotLimit)
        if dots > 0 {
            layout.leftWidth = CGFloat(dots) * 5 + CGFloat(dots - 1) * 4 + 4 + countWidth(summary.working)
        }
        if summary.waiting > 0 {
            layout.right = .attention(count: summary.waiting)
            layout.rightWidth = 5 + 3 + countWidth(summary.waiting)
        } else if summary.failed > 0 {
            layout.right = .failed(count: summary.failed)
            layout.rightWidth = 5 + 3 + countWidth(summary.failed)
        } else if media != nil {
            layout.right = .media
            layout.rightWidth = mediaContentWidth
        }
        // The privacy dots share the right shoulder rather than
        // competing for it: they sit nearest the notch — the hardware
        // LED's own spot — and attention or media move over, never
        // hide them.
        if sensors.anyInUse {
            layout.sensors = sensors
            layout.rightWidth += sensorDotsWidth(sensors)
                + (layout.rightWidth > 0 ? sensorSeparatorWidth : 0)
        }
        return layout
    }
}

/// The island's frame math. The panel is exactly the drawn shape — a
/// capsule pinned to the screen's top edge, centred on the notch slot —
/// so a transparent window never swallows a menu-bar click.
public enum NotchIslandLayout {
    /// Points the idle capsule reaches past each shoulder of the notch.
    public static let shoulder: CGFloat = 10
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

    /// Points the expanded card reaches past each side of the notch
    /// slot — modest symmetric wings, so the grown card reads as the
    /// notch itself swelling (Alcove-style), never a detached wide
    /// panel parked over it.
    public static let expandedShoulder: CGFloat = 30
    /// The card's rows are designed at 320 points (`NotchCardView`);
    /// narrower clipped the tray row.
    public static let expandedMinWidth: CGFloat = 320
    public static let expandedMaxWidth: CGFloat = 380
    /// Clearance the expanded card's content keeps under the notch.
    public static let expandedNotchInset: CGFloat = 4

    /// The grown card's width: the slot plus its shoulders, bounded —
    /// wider than the notice, never the whole menu bar.
    public static func expandedWidth(slotWidth: CGFloat) -> CGFloat {
        min(expandedMaxWidth, max(expandedMinWidth, slotWidth + 2 * expandedShoulder))
    }

    /// How far below the window's top the expanded card's content
    /// starts — past the notch's own depth and its inset. A live Screen
    /// Bar owes nothing more: its strip seats at the card's bottom edge
    /// and its tray ends at the bezel. Notch-less floats get just the
    /// inset.
    public static func expandedTopInset(notchDepth: CGFloat) -> CGFloat {
        notchDepth > 0 ? notchDepth + expandedNotchInset : expandedNotchInset
    }

    /// Air around a shoulder's content.
    public static let shoulderPad: CGFloat = 5

    /// The collapsed capsule: the notch plus each shoulder's own width
    /// (`NotchIdleLayout.leftShoulder`/`rightShoulder` — zero while
    /// bare, so the housing is exactly the hardware) and exactly the
    /// notch's depth, so at rest nothing but the Screen Bar's band
    /// draws below the hardware. The island reads as the notch grown,
    /// not a pill parked beside it. Notch-less screens get a floating
    /// pill sized to the content.
    public static func idleSize(slotWidth: CGFloat, notchDepth: CGFloat,
                                leftShoulder: CGFloat, rightShoulder: CGFloat) -> CGSize {
        CGSize(width: slotWidth + leftShoulder + rightShoulder, height: notchDepth)
    }

    /// The notch-less floating pill, sized to its content.
    public static func floatingSize(contentWidth: CGFloat) -> CGSize {
        CGSize(width: max(idleMinWidth, contentWidth + 24), height: 24)
    }

    /// Where the island's centre sits: always the slot's — every face
    /// shares it, so a morph never travels sideways.
    public static func idleCenterX(slotCenterX: CGFloat, leftShoulder: CGFloat,
                                   rightShoulder: CGFloat) -> CGFloat {
        slotCenterX
    }

    /// One shoulder's width for its content — the bare shoulder, or the
    /// content plus its air.
    public static func shoulderWidth(contentWidth: CGFloat) -> CGFloat {
        contentWidth > 0 ? max(shoulder, contentWidth + 2 * shoulderPad) : shoulder
    }

    /// The hover wink — the breath `NotchMotion.hoverDelay` arms: a
    /// resting island under a resting pointer widens and deepens a few
    /// points, proof of life while the intent debounce decides whether
    /// the hover meant the card. A pointer passing through earns
    /// nothing, never the grow.
    /// The wink applied to an idle size. A drawn face swells its width
    /// symmetrically — the island reads as the notch grown sideways and
    /// a touch deeper. The bare housing is exactly the notch: sideways
    /// paint would reach past the hardware and sit under menu-bar
    /// clicks, so its tell grows straight down instead — the island's
    /// own direction.
    public static func peekAdjusted(_ size: CGSize, bare: Bool) -> CGSize {
        bare ? CGSize(width: size.width,
                      height: size.height + NotchMotion.hoverGrowHeight)
             : CGSize(width: size.width + NotchMotion.hoverGrowWidth,
                      height: size.height + NotchMotion.hoverGrowHeight)
    }

    /// The window's frame: centred on `centerX`, its top edge `topInset`
    /// below the screen's top edge, clamped inside the screen with
    /// `edgeMargin` to spare.
    public static func frame(screenFrame: CGRect, centerX: CGFloat, size: CGSize, topInset: CGFloat = 0) -> CGRect {
        let width = min(size.width, max(0, screenFrame.width - 2 * edgeMargin))
        let inset = max(0, topInset)
        let height = min(max(0, size.height), max(0, screenFrame.height - inset - edgeMargin))
        let x = min(screenFrame.maxX - edgeMargin - width,
                    max(screenFrame.minX + edgeMargin, centerX - width / 2))
        return CGRect(x: x, y: screenFrame.maxY - inset - height,
                      width: width, height: height)
    }
}

extension AlcoveNoticeKind {
    /// The kinds whose capsule carries buttons — the ask's verbs, a
    /// meeting's Join — and so wears the taller verb face.
    public var hasVerbs: Bool { self == .ask || self == .meeting }

    /// Which capsule deserves the queue's one waiting slot: an ask
    /// outranks a failure, and both outrun the ambient kinds. Lower
    /// wins. `AlcoveCapsuleQueue` itself stays newest-wins; the
    /// island's toy reads this at the door so a late power blip never
    /// displaces a waiting ask.
    public var queueRank: Int {
        switch self {
        case .ask: return 0
        case .failed: return 1
        // A meeting about to start and a timer the person set outrank
        // an agent's news about itself.
        case .meeting, .timer: return 2
        case .completed: return 3
        case .quotaReset: return 4
        case .device: return 5
        case .focus: return 6
        case .display: return 7
        case .charging: return 8
        // Feedback never waits in the line (`isFeedback` overlays), so
        // these ranks only order it should it ever be offered there.
        case .capsLock: return 9
        case .level: return 10
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

/// The island's feel in one place — every number that makes the notch
/// move like Alcove's. The frame spring's grow/fold pairs land on
/// `NotchFrameSpring`'s named motions; the hover breath, the notice
/// capsule's slide-and-fade and the expanded card's content-follow
/// timings are read straight from here. Reduce Motion swaps every
/// morph for the quiet crossfade — `faceTransition` is the single
/// branch the tests pin.
public enum NotchMotion {
    /// The grow: the island opening into the card, or any swell —
    /// slow enough to read, loose enough to overshoot ~2%.
    public static let expand = NotchFrameSpring.Motion(response: 0.42, dampingFraction: 0.78)
    /// The fold: collapse runs a beat faster than the grow and lands
    /// damped — a dismissal never bounces.
    public static let collapse = NotchFrameSpring.Motion(response: 0.32, dampingFraction: 0.9)
    /// Content-driven nudges — a dot arriving, a row refilling.
    public static let morph = NotchFrameSpring.Motion(response: 0.30, dampingFraction: 0.9)

    /// The hover breath: a pointer resting on the compact island this
    /// long earns the tell — a few points of grow and a subtle swell
    /// of the marks inside.
    public static let hoverDelay: TimeInterval = 0.12
    /// The breath's frame half: the island widens and deepens by a
    /// few points, symmetric on a drawn face, straight down on the
    /// bare housing.
    public static let hoverGrowWidth: CGFloat = 4
    public static let hoverGrowHeight: CGFloat = 2
    /// The breath's content half — a whisper of a swell, not a pop.
    public static let hoverContentScale: CGFloat = 1.02

    /// The notice capsule's entrance: the face slides down a few
    /// points while it fades in.
    public static let noticeSlide: CGFloat = 6
    public static let noticeFadeIn: TimeInterval = 0.18
    /// Dismissal reverses the move, a touch quicker than the entrance.
    public static let noticeFadeOut: TimeInterval = 0.14

    /// The expanded card's content follows its frame: rows wait until
    /// the spring has carried the frame this far toward the target,
    /// then fade in staggered — frame leads, content follows.
    public static let contentRevealThreshold: CGFloat = 0.85
    public static let rowStagger: TimeInterval = 0.03
    /// One row's own fade once its stagger lands.
    public static let rowFade: TimeInterval = 0.18

    /// Reduce Motion's whole vocabulary: a quiet crossfade, no travel.
    public static let reduceMotionFade: TimeInterval = 0.15

    /// How a face change moves: the spring morph normally, the quiet
    /// crossfade under Reduce Motion.
    public enum FaceTransition: Equatable, Sendable {
        case morph, crossfade
    }

    /// The single Reduce Motion branch — the island's every motion
    /// decision funnels through here so the accessibility path is one
    /// testable fact, not a scatter of reads.
    public static func faceTransition(reduceMotion: Bool) -> FaceTransition {
        reduceMotion ? .crossfade : .morph
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
    public static let expandMotion = NotchMotion.expand
    /// The fold: collapse runs a beat faster than the grow.
    public static let collapseMotion = NotchMotion.collapse
    /// Content-driven nudges — a dot arriving, a row refilling.
    public static let morphMotion = NotchMotion.morph

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

/// The island's pinch, read off trackpad magnify events: spreading two
/// fingers grows the resting island into the card, squeezing folds the
/// card back into the notch (or puts a capsule away). One verdict per
/// gesture, at the threshold — the way the swipe fires once.
public struct NotchPinch: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable { case grow, fold }

    /// Accumulated magnification that commits — a deliberate spread,
    /// not a wobble while two fingers rest on the trackpad.
    public static let threshold: CGFloat = 0.18

    public private(set) var total: CGFloat = 0
    public private(set) var fired = false

    public init() {}

    /// One magnify delta; the verdict once it crosses, nil otherwise
    /// (and nil for the rest of the gesture after it fired).
    public mutating func add(_ delta: CGFloat) -> Verdict? {
        guard !fired else { return nil }
        total += delta
        if total >= Self.threshold { fired = true; return .grow }
        if total <= -Self.threshold { fired = true; return .fold }
        return nil
    }
}

// MARK: - Asks at the notch

extension NotchIsland {
    /// The ask a session waits on: the one pinned in `state.asks` first
    /// (it carries the daemon's `answerable` verdict and the request
    /// pin), the session's embedded one otherwise — with `session`
    /// filled in, so the answer path always has an id to send.
    public static func liveAsk(for session: CoreSession, asks: [CoreAsk]) -> CoreAsk? {
        if let pinned = asks.first(where: { $0.session == session.id }) { return pinned }
        guard var ask = session.ask else { return nil }
        ask.session = session.id
        return ask
    }

    /// The same read by session id over a whole state — an orphaned
    /// pinned ask whose row is gone still answers.
    public static func liveAsk(session id: String, state: CoreState?) -> CoreAsk? {
        guard let state else { return nil }
        if let pinned = state.asks.first(where: { $0.session == id }) { return pinned }
        guard let session = state.session(withID: id) else { return nil }
        return liveAsk(for: session, asks: [])
    }

    /// Whether a latched ask capsule still holds: its ask is live and is
    /// still the episode the capsule pinned. An ask the capsule has
    /// never seen in the state gets `askGrace` to arrive — the event can
    /// land a beat before the document that carries it — and once seen,
    /// its disappearance is the resolution.
    public static func askStillOpen(_ notice: AlcoveNotice, live: CoreAsk?,
                                    seenLive: Bool, age: TimeInterval) -> Bool {
        guard notice.kind == .ask else { return false }
        guard let live else { return !seenLive && age < askGrace }
        guard let pinned = notice.ask?.request, let current = live.request else { return true }
        return pinned == current
    }

    /// Seconds an ask capsule waits for its ask to show up in the state.
    public static let askGrace: TimeInterval = 6
}

/// What a notch surface may offer for an ask — the capsule, the takeover
/// card, a waiting row in the card. Only an explicit click ever answers:
/// nothing here approves on its own, and the buttons exist only where
/// the daemon says the answer chain can deliver (`CoreAsk.canAnswer`).
public enum NotchAskVerbs: Equatable, Sendable {
    /// Approve and Deny through `answer_ask` with the request pin, and
    /// Open beside them.
    case answer
    /// Only Open. `reason` is the short why (a typed reply is wanted,
    /// the daemon can't type into that terminal); nil while the ask has
    /// not reached the state yet.
    case openOnly(reason: String?)
    /// A peer Mac's session: nothing here can answer it or raise it.
    case remote(machine: String?)
    /// Nothing to act on.
    case none

    public static func resolve(live: CoreAsk?, session: String?) -> NotchAskVerbs {
        guard let session, !session.isEmpty else { return .none }
        if CoreSession.isRemoteID(session) {
            return .remote(machine: CoreSession.remoteMachine(inID: session))
        }
        guard let live else { return .openOnly(reason: nil) }
        if live.wantsTextReply { return .openOnly(reason: "Wants a typed reply") }
        guard live.canAnswer else { return .openOnly(reason: "Answer it in its window") }
        return .answer
    }

    /// Approve / Deny may draw.
    public var answers: Bool { self == .answer }
    /// Open may draw.
    public var opens: Bool {
        switch self {
        case .answer, .openOnly: return true
        case .remote, .none: return false
        }
    }

    /// The line under an ask that cannot be answered here, if any.
    public var note: String? {
        switch self {
        case .openOnly(let reason): return reason
        case .remote(let machine): return "Runs on \(machine ?? "another Mac") — answer it there"
        case .answer, .none: return nil
        }
    }
}

/// A refused `answer_ask`, as one short line for the island: the same
/// cases the panel's toast names (`PanelStore.answerRefused`), trimmed
/// to fit under the notch. The ask stays open either way.
public enum NotchAskRefusal {
    public static func line(for error: CoreReplyError?) -> String {
        switch error?.code {
        case "stale_request": return "That request changed — nothing was sent"
        case "accessibility_required": return "Needs Accessibility for JR-Bar's helper"
        case "not_frontmost": return "Its terminal tab has to be in front"
        case "not_found": return "That session is gone"
        default:
            let message = error?.message ?? error?.code ?? "refused"
            return "Couldn't answer: \(message)"
        }
    }

    /// The socket never answered — the ask is still open.
    public static let unreachable = "No answer from the monitor — still open"
}

extension NotchIslandLayout {
    /// The ask face: hung from the notch like every notice, two lines of
    /// copy (who, and what they ask) over a row of verbs. The takeover
    /// grows it to the card's width and lets the summary run to
    /// `askTakeoverLines`.
    public static let askTitleLine: CGFloat = 16
    public static let askSummaryLine: CGFloat = 14
    public static let askVerbRow: CGFloat = 22
    public static let askPad: CGFloat = 8
    public static let askGap: CGFloat = 6
    public static let askMinWidth: CGFloat = 300
    public static let askTakeoverLines = 3
    /// The notch-less pill's ask needs no notch depth over its copy.
    public static let askFloatingTop: CGFloat = 4

    /// The ask face's width: the notice's own measure, floored so three
    /// verbs fit; the takeover is the grown card's width.
    public static func askWidth(slotWidth: CGFloat, takeover: Bool) -> CGFloat {
        takeover
            ? expandedWidth(slotWidth: slotWidth)
            : max(askMinWidth, slotWidth > 0 ? slotWidth + 2 * noticeShoulder : noticeMinWidth)
    }

    /// Lines the summary takes at `width` — a character estimate at the
    /// face's 11 pt, capped. The frame is the drawn shape, so this is
    /// decided before layout; the text's own `lineLimit` keeps any
    /// miscount inside the box.
    public static func askSummaryLines(_ summary: String, width: CGFloat, maxLines: Int) -> Int {
        let usable = max(40, width - 2 * 14)
        let perLine = max(10, Int(usable / 6.0))
        let needed = Int((Double(summary.count) / Double(perLine)).rounded(.up))
        return min(max(1, needed), max(1, maxLines))
    }

    /// The ask face's size. Under a live Screen Bar's housing the foot
    /// climbs over the island's bottom corners (`housingClimb`), so the
    /// content box stands on top of that climb — the same stepping the
    /// one-line notice takes.
    public static func askSize(slotWidth: CGFloat, notchDepth: CGFloat, summaryLines: Int,
                               takeover: Bool, underHousing restingRadius: CGFloat? = nil) -> CGSize {
        let width = askWidth(slotWidth: slotWidth, takeover: takeover)
        let content = askPad + askTitleLine + CGFloat(max(1, summaryLines)) * askSummaryLine
            + askGap + askVerbRow + askPad
        let top = notchDepth > 0 ? notchDepth : askFloatingTop
        let room = top + content
        guard notchDepth > 0, let restingRadius else {
            return CGSize(width: width, height: room.rounded(.up))
        }
        func climb(_ height: CGFloat) -> CGFloat {
            housingClimb(size: CGSize(width: width, height: height),
                         notchDepth: notchDepth, restingRadius: restingRadius)
        }
        var height = (room + climb(room)).rounded(.up)
        while height - climb(height) < room { height += 1 }
        return CGSize(width: width, height: height)
    }
}
