import AppKit
import JRBarCore
import JRBarLEDS
import SwiftUI

/// The buddy itself: one of ten drawn characters (`BuddyCharacter`)
/// sharing a single skeleton. Pose and tint come from
/// `NotchBuddyToy.mood`; `TimelineView(.animation)` drives the walk, the
/// wave, the hop and the blink, and Reduce Motion swaps the moving poses
/// for still ones (the blink stays — a closed eye is a pose too). It
/// also reports what it sees: a count pill by its feet while the work
/// is plural, a "!" that wears the ask count, and a hover line naming
/// who's on the clock.
///
/// It is a pet, not a statue: the pill takes clicks (the panel only
/// ignores the mouse while a toast holds it) and a tap is a pet that
/// cycles a trick — hop, spin, wave, blush — plus hearts on a treat and
/// a "+1" crumb whenever it eats a completed session.
struct NotchBuddyView: View {
    let toy: NotchBuddyToy
    /// The floating panel's size multiplier — the docked slot leaves it
    /// at 1. Everything inside is vector (paths, shapes, text), so this
    /// rides the render tree as a transform, not a resample: strokes,
    /// eyes and the badge stay crisp at 3×.
    var scale: Double = 1
    /// The docked slot's presentation: always the status dot — compact
    /// beside the notch, no character body. Floating keeps whichever
    /// presentation the settings picked.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window a hop plays across; `NotchBuddyToy.hopUntil` sets it.
    private static let hopDuration: TimeInterval = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            // One reduce per tick: the pose, the badge, the tints, the
            // care mood and the hover line all read the same summary.
            let summary = toy.summary(at: context.date)
            let dress = dragDress(at: context.date)
            if compact || toy.miniMode {
                // The status dot extends the pulse strip: while the
                // daemon publishes a screen_bar program the dot is its
                // centre seam's extra LED, sampled on the anchor's own
                // clock — a free-running breath could only ever sit at
                // some arbitrary phase, which is why the unlinked dot
                // read as inverted and late. No program published: the
                // dot keeps its standalone breath.
                MiniFigure(
                    mood: summary.mood,
                    tint: tint(for: summary),
                    strip: toy.stripDot(at: context.date.timeIntervalSince1970,
                                        still: reduceMotion),
                    waiting: summary.waiting,
                    working: summary.working,
                    still: reduceMotion,
                    phase: context.date.timeIntervalSince1970
                )
                .help(summary.statusLine)
            } else {
            BuddyFigure(
                character: toy.buddyCharacter,
                mood: summary.mood,
                tint: tint(for: summary),
                phase: context.date.timeIntervalSince1970,
                hopProgress: hopProgress(at: context.date),
                waveAge: waveAge(at: context.date, mood: summary.mood),
                slumpAge: slumpAge(at: context.date, mood: summary.mood),
                leans: toy.waveOrdinal % 2 == 0,
                still: reduceMotion,
                askCount: summary.waiting,
                care: summary.care,
                trick: trick(at: context.date),
                treatAge: age(of: toy.treatBurstAt, at: context.date),
                crumbAge: age(of: toy.crumbAt, at: context.date)
            )
            .overlay(alignment: .bottomTrailing) { workingBadge(for: summary) }
            .scaleEffect(x: dress.squash.width, y: dress.squash.height, anchor: .bottom)
            .rotationEffect(.degrees(dress.tilt), anchor: .center)
            .offset(y: dress.lift)
            .help(summary.statusLine)
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(scale)
        // The layout claims the scaled footprint, so the breathing room
        // — and the hit target — grows with the pet.
        .frame(width: 18 * scale, height: 18 * scale)
        .padding(.horizontal, 9 * scale)
        .padding(.vertical, 6 * scale)
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { toy.tapped() }
        .accessibilityLabel("Notch Buddy, \(toy.buddyName)")
        .accessibilityHint("Tap for a trick, drag to park it anywhere, right-click for the menu. While an ask is open, a tap opens the session asking.")
        .accessibilityAddTraits(.isButton)
    }

    /// The carry's dress: held, the buddy leans toward the travel
    /// direction with its feet off the ground (the tilt settles on a
    /// short time constant while the cursor parks); put down, it lands
    /// with a small squash. Reduce Motion gets a plain reposition.
    private func dragDress(at now: Date) -> (tilt: Double, lift: Double, squash: CGSize) {
        guard !reduceMotion else { return (0, 0, CGSize(width: 1, height: 1)) }
        var tilt = 0.0
        var lift = 0.0
        var squash = CGSize(width: 1, height: 1)
        if toy.isDragged {
            let settle = BuddyPlacement.tiltDecay(age: now.timeIntervalSince(toy.dragMovedAt ?? now))
            tilt = toy.dragTilt * settle
            lift = -1.8
            let s = abs(tilt) / 14
            squash = CGSize(width: 1 - 0.05 * s, height: 1 + 0.06 * s)
        }
        if let landedAt = toy.landedAt {
            let age = now.timeIntervalSince(landedAt)
            if age >= 0, age < 0.34 {
                let s = sin(age / 0.34 * .pi)
                squash.width *= 1 + 0.11 * s
                squash.height *= 1 - 0.18 * s
                lift += 0.4 * s
            }
        }
        return (tilt, lift, squash)
    }

    /// The count pill by the buddy's feet while two or more sessions are
    /// working — one worker is already the tint, the badge answers "how
    /// many". It wears the busiest provider's colour and sits where the
    /// "!" can't reach it. Static, so Reduce Motion needs nothing.
    @ViewBuilder private func workingBadge(for summary: NotchBuddyToy.BuddySummary) -> some View {
        if summary.working >= 2 {
            Text("\(summary.working)")
                .font(.system(size: 5.4, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 2.4)
                .padding(.vertical, 0.8)
                .background(Capsule().fill(badgeTint(for: summary)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.4))
                .offset(x: 3, y: 6)
                .accessibilityHidden(true)
        }
    }

    private func badgeTint(for summary: NotchBuddyToy.BuddySummary) -> Color {
        guard let provider = summary.dominantProvider else { return .accentColor }
        return ProviderStyle.style(for: provider).accent
    }

    /// 0→1 across the hop; nil when no hop is playing.
    private func hopProgress(at now: Date) -> Double? {
        guard let hopUntil = toy.hopUntil else { return nil }
        let remaining = hopUntil.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return 1.0 - remaining / Self.hopDuration
    }

    /// Seconds into the wave; nil unless the mood is waving. The entrance
    /// jump and the "!" key off this so they play once per ask.
    private func waveAge(at now: Date, mood: NotchBuddyToy.Mood) -> TimeInterval? {
        guard mood == .waving, let since = toy.wavingSince else { return nil }
        return now.timeIntervalSince(since)
    }

    /// Seconds into the slump; nil unless the mood is slumped. The
    /// tumble-in plays once from here.
    private func slumpAge(at now: Date, mood: NotchBuddyToy.Mood) -> TimeInterval? {
        guard mood == .slumped, let since = toy.slumpedSince else { return nil }
        return now.timeIntervalSince(since)
    }

    /// The tap trick mid-flight, or nil. Reduce Motion gets no tricks —
    /// the pet still counts, the pose just stays put.
    private func trick(at now: Date) -> BuddyTrick? {
        guard !reduceMotion, let start = toy.trickStartedAt else { return nil }
        let age = now.timeIntervalSince(start)
        guard age >= 0, age < BuddyTrick.duration else { return nil }
        return BuddyTrick(kind: toy.trickKind, age: age)
    }

    /// Seconds since an optional clock last fired — the treat and crumb
    /// bursts both read through this.
    private func age(of date: Date?, at now: Date) -> TimeInterval? {
        date.map { now.timeIntervalSince($0) }
    }

    private func tint(for summary: NotchBuddyToy.BuddySummary) -> Color {
        switch summary.mood {
        case .asleep: return Color(nsColor: .tertiaryLabelColor)
        case .pacing, .gathering:
            // One provider working → the buddy wears its colour.
            if let provider = summary.workingProvider {
                return ProviderStyle.style(for: provider).accent
            }
            return .accentColor
        case .waving: return .orange
        case .slumped: return .red
        case .celebrating: return .green
        }
    }
}

/// The status-dot presentation: no character body, just a dot tinted by
/// the mood — dim when idle, provider-coloured while one session works,
/// and a number beside it once the work is plural. The "!" still wears
/// the open-ask count; tap, drag and menu behave exactly like the full
/// figure.
///
/// While the daemon publishes a Screen Bar program the dot is also the
/// strip's extension: `strip` carries the seam's sampled colour and its
/// `maxChannel` is the pulse's level, so the dot's glow rides the same
/// clock the band and the hardware run — bright when the strip is
/// bright, dark when it is dark — instead of a private sin() that sat
/// at an arbitrary phase against the band.
private struct MiniFigure: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    /// The strip link: the centre seam's colour right now, or nil when
    /// no program is published to extend.
    let strip: RGB?
    let waiting: Int
    let working: Int
    let still: Bool
    let phase: TimeInterval

    /// The sampled colour normalized to full strength, so the pulse's
    /// ramp lives in the overlay's opacity rather than greying the hue.
    /// nil when the sample is dark — the resting dot owns the trough.
    private var stripHue: Color? {
        guard let strip else { return nil }
        let level = strip.maxChannel
        guard level > 0.004 else { return nil }
        return Color(red: strip.r / level, green: strip.g / level, blue: strip.b / level)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ZStack {
                Circle()
                    // Linked, the resting tint dims and brightens with
                    // the strip — the extension's own duty cycle, so the
                    // pulse's trough is visible on the dot too.
                    .fill(tint.opacity(mood == .asleep ? 0.35
                                       : strip != nil ? 0.45 + 0.5 * (strip?.maxChannel ?? 0)
                                       : 0.95))
                if let hue = stripHue {
                    Circle()
                        .fill(hue)
                        .opacity(strip?.maxChannel ?? 0)
                }
            }
            // The swell rides the strip's level while linked — a phase
            // that is the strip's own cannot run inverted or late —
            // and keeps the slow standalone breath when it is not.
            // Asleep and Reduce Motion hold still either way.
            .scaleEffect(still || mood == .asleep ? 1.0
                         : strip != nil ? 1.0 + 0.15 * (strip?.maxChannel ?? 0)
                         : 1.0 + 0.1 * sin(phase * 2.2))
            .frame(width: 7, height: 7)
            if working > 1 {
                Text("\(working)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if waiting > 0 {
                Text(waiting > 1 ? "!\(waiting)" : "!")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.5).padding(.vertical, 0.5)
                    .background(Capsule().fill(Color.orange))
                    .offset(y: -8)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A tap trick: which one and how far in. Every trick is a `duration`-
/// long one-shot layered over the mood's pose — the mood keeps running
/// underneath, the trick borrows the body for a beat.
struct BuddyTrick: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case hop, spin, wave, blush }
    let kind: Kind
    /// Seconds since the tap.
    let age: TimeInterval
    /// The whole beat; the view ages a trick out past it.
    static let duration: TimeInterval = 0.65
}

/// The shared skeleton every character hangs on: the pose, the blink,
/// the one-off effects ("!", "z"s, the hop's sparkle and check, the
/// treat's hearts, the crumb's "+1") and the ground shadow. Each mood
/// is a pose with the craft in the motion — pacing steps and turns at
/// the ends, a gathering bounces in place, the wave and the hop crouch
/// first and land flat, a slump tumbles in on a roll, sleep drifts "z"s
/// under a nightcap, and every awake mood blinks on a jittered cadence.
/// `character` picks which body the pose wears; the renderers below and
/// in `NotchBuddyBodies` only draw, they never move.
///
/// On top of the mood sit two small layers: `care` (the Tamagotchi-lite
/// log — `fed` blushes and smiles, `missing` droops the eyes and sags
/// the body) and `trick` (the tap's ~0.65s one-shot).
struct BuddyFigure: View {
    let character: BuddyCharacter
    let mood: NotchBuddyToy.Mood
    let tint: Color
    /// Seconds, monotonic — the animation clock.
    let phase: TimeInterval
    /// 0→1 while a completion hop plays, else nil.
    let hopProgress: Double?
    /// Seconds since the wave began, else nil.
    let waveAge: TimeInterval?
    /// Seconds since the slump began, else nil.
    let slumpAge: TimeInterval?
    /// The quiet ask: every other ask the buddy leans in holding eye
    /// contact instead of waving with a "!".
    let leans: Bool
    /// Reduce Motion: poses stay, motion goes.
    let still: Bool
    /// Open asks — past one, the "!" wears the count.
    let askCount: Int
    /// The friendship: content, fresh off a treat, or missing you.
    let care: BuddyCare.Mood
    /// The tap trick playing now, if any.
    let trick: BuddyTrick?
    /// Seconds since the last treat; the hearts burst while it is fresh.
    let treatAge: TimeInterval?
    /// Seconds since the last crumb it ate; the "+1" floats while fresh.
    let crumbAge: TimeInterval?

    // MARK: Pose

    /// The mouth shapes: `flat` patrols and sags, `wobble` fails,
    /// `open` asks, `smile` bounces, `grin` celebrates.
    enum Mouth { case none, flat, wobble, open, smile, grin }

    /// Everything the frame needs, resolved once per tick. The
    /// character renderers read this; only the skeleton writes it.
    struct Pose {
        var offset = CGSize.zero
        var squash = CGSize(width: 1, height: 1)
        var lean = 0.0          // degrees
        var spin = 0.0          // trick pirouette, degrees
        var look = CGSize.zero  // pupil drift inside the eye
        var lid = 0.0           // resting lid, 0 open → 1 closed
        var air = 0.0           // 0 grounded → 1 apex; drives the shadow
        var pupil = 2.1
        var mouth = Mouth.none
        var eyesClosed = false  // asleep draws lid lines, not pupils
        var blush = 0.0         // 0 none → 1 fully pink cheeks
    }

    /// The pose, layered: the mood first, then the care feelings, then
    /// the tap's trick on top. Reduce Motion takes the still mood pose;
    /// care still applies (a droop is a pose), tricks do not.
    private var pose: Pose {
        var pose = still ? stillPose : movingPose
        applyCare(&pose)
        if let trick, !still { applyTrick(trick, &pose) }
        return pose
    }

    private var movingPose: Pose {
        switch mood {
        case .asleep: return asleepPose
        case .pacing: return pacingPose
        case .gathering: return gatheringPose
        case .waving: return wavingPose
        case .slumped: return slumpedPose
        case .celebrating: return celebratingPose
        }
    }

    /// The pet's feelings over the mood's pose. `fed` blushes and turns
    /// a flat mouth up; `missing` rides heavier — half-lidded, downcast,
    /// a little deflated. Busy moods keep their own face: an ask, a
    /// failure and a hop all outrank feelings.
    private func applyCare(_ pose: inout Pose) {
        switch care {
        case .content:
            break
        case .fed:
            guard mood == .pacing || mood == .gathering else { return }
            pose.blush = max(pose.blush, 0.8)
            if pose.mouth == .flat || pose.mouth == .none { pose.mouth = .smile }
        case .missing:
            guard mood == .asleep || mood == .pacing || mood == .gathering else { return }
            pose.lid = max(pose.lid, 0.30)
            pose.look.height += 0.4
            pose.offset.height += 0.7
            pose.squash.height *= 0.96
        }
    }

    /// One tap trick, eased over `BuddyTrick.duration`. They are small
    /// on purpose — the mood owns the silhouette, the trick just hops,
    /// spins, sways or colours the cheeks.
    private func applyTrick(_ trick: BuddyTrick, _ pose: inout Pose) {
        let t = min(1, trick.age / BuddyTrick.duration)
        switch trick.kind {
        case .hop:
            let h = sin(t * .pi)
            pose.offset.height -= 5.2 * h
            pose.air = max(pose.air, h)
            pose.squash.width *= 1 - 0.12 * h
            pose.squash.height *= 1 + 0.16 * h
            pose.eyesClosed = false   // a pat wakes it for the trick
            if pose.mouth == .flat || pose.mouth == .none { pose.mouth = .grin }
        case .spin:
            pose.spin += 360 * (1 - pow(1 - t, 3))
            let h = sin(t * .pi)
            pose.offset.height -= 1.6 * h
            pose.air = max(pose.air, 0.3 * h)
            pose.eyesClosed = false
        case .wave:
            let e = sin(t * .pi)
            pose.lean += sin(t * .pi * 3) * 13 * e
            if pose.mouth == .flat || pose.mouth == .none { pose.mouth = .smile }
        case .blush:
            let h = sin(t * .pi)
            pose.blush = max(pose.blush, h)
            pose.squash.width *= 1 + 0.06 * h
            if pose.mouth == .flat || pose.mouth == .none { pose.mouth = .smile }
        }
    }

    /// Reduce Motion: each mood keeps its silhouette and drops its motion.
    private var stillPose: Pose {
        var pose = Pose()
        switch mood {
        case .asleep:
            pose.eyesClosed = true
            pose.offset.height = 0.8
        case .pacing:
            pose.look = CGSize(width: 0.9, height: -0.2)
            pose.mouth = .flat
        case .gathering:
            pose.pupil = 2.3
            pose.offset.height = -0.8
            pose.look.height = -0.25
            pose.mouth = .smile
        case .waving:
            if leans {
                pose.squash = CGSize(width: 1.03, height: 1.07)
                pose.lean = 8
                pose.pupil = 2.6
                pose.look.height = -0.2
            } else {
                pose.lean = 10
                pose.pupil = 2.4
                pose.look.height = -0.5
            }
            pose.mouth = .open
        case .slumped:
            pose.offset.height = 2.2
            pose.squash = CGSize(width: 1.28, height: 0.68)
            pose.lid = 0.38
            pose.look.height = 0.6
            pose.mouth = .wobble
        case .celebrating:
            pose.pupil = 2.2
            pose.look.height = -0.3
            pose.mouth = .grin
        }
        return pose
    }

    /// A slow breath, eyes shut; the "z"s carry the rest.
    private var asleepPose: Pose {
        var pose = Pose()
        pose.eyesClosed = true
        let breath = sin(phase * 1.1)
        pose.squash = CGSize(width: 1 + 0.05 * breath, height: 1 - 0.06 * breath)
        pose.offset.height = 0.8 + 0.4 * breath
        return pose
    }

    /// An eased walk between two ends, with a pause that turns the eyes
    /// before the body follows — pacing, not a pendulum.
    private var pacingPose: Pose {
        var pose = Pose()
        let cycle = 3.4
        let c = (phase.truncatingRemainder(dividingBy: cycle) + cycle)
            .truncatingRemainder(dividingBy: cycle) / cycle
        let leg: (x: Double, dir: Double, walk: Double?, turn: Double)
        switch c {
        case ..<0.40: leg = (-3 + 6 * Self.smooth(c / 0.40), 1, c / 0.40, 0)
        case ..<0.50: leg = (3, 1, nil, Self.smooth((c - 0.40) / 0.10))
        case ..<0.90: leg = (3 - 6 * Self.smooth((c - 0.50) / 0.40), -1, (c - 0.50) / 0.40, 0)
        default:      leg = (-3, -1, nil, Self.smooth((c - 0.90) / 0.10))
        }
        pose.offset.width = leg.x
        if let walk = leg.walk {
            // A step bob, three per crossing, and a lean into the stride.
            pose.offset.height = -abs(sin(walk * .pi * 3)) * 0.6
            pose.lean = leg.dir * 5
            pose.look = CGSize(width: leg.dir * 0.9, height: -0.2)
        } else {
            // Paused at the end: settle, then the eyes lead the turn back.
            let settle = 1 - leg.turn
            pose.squash = CGSize(width: 1 + 0.07 * settle, height: 1 - 0.07 * settle)
            pose.lean = leg.dir * (5 - 7 * leg.turn)
            pose.look = CGSize(width: leg.dir * (0.9 - 1.8 * leg.turn), height: -0.2)
        }
        pose.mouth = .flat
        return pose
    }

    /// Three or more sessions working at once: busy is exciting — quick
    /// happy micro-hops in place instead of the patrol.
    private var gatheringPose: Pose {
        var pose = Pose()
        pose.pupil = 2.3
        pose.mouth = .smile
        let b = abs(sin(phase * 7.2))
        pose.offset.height = -2.0 * b
        pose.air = 0.35 * b
        pose.squash = CGSize(width: 1 + 0.10 * (1 - b) - 0.04 * b,
                             height: 1 - 0.09 * (1 - b) + 0.07 * b)
        pose.lean = sin(phase * 3.6) * 4
        pose.look = CGSize(width: sin(phase * 1.8) * 0.7, height: -0.25)
        return pose
    }

    /// The ask: a crouch, a jump, a landing — once — then either a fast
    /// wave or, every other ask (`leans`), a quiet lean-in that just
    /// holds your eye. The "!" only pops for the wave asks.
    private var wavingPose: Pose {
        var pose = Pose()
        pose.pupil = leans ? 2.6 : 2.4
        pose.mouth = .open
        let age = waveAge ?? .infinity
        if age < 0.14 {
            // Anticipation crouch.
            let t = age / 0.14
            pose.squash = CGSize(width: 1 + 0.16 * t, height: 1 - 0.2 * t)
            pose.offset.height = 1.4 * t
        } else if age < 0.55 {
            // The jump up, easing out — half-height on the quiet asks.
            let t = (age - 0.14) / 0.41
            let e = 1 - (1 - t) * (1 - t)
            let hop = leans ? 3.4 : 6.9
            pose.offset.height = 1.4 - hop * e
            pose.air = e * (leans ? 0.5 : 1)
            pose.squash = CGSize(width: 1 - 0.14 * e, height: 1 + 0.2 * e)
            pose.lean = 6 * e
        } else if age < 0.9 {
            // Falling, then a flat land-squash that releases.
            let t = (age - 0.55) / 0.35
            let depth = leans ? 2.0 : 5.5
            pose.offset.height = -depth * (1 - t * t)
            pose.air = (1 - t * t) * (leans ? 0.5 : 1)
            let impact = sin(min(t / 0.45, 1) * .pi)
            pose.squash = CGSize(width: 1 + 0.22 * impact, height: 1 - 0.24 * impact)
            pose.lean = 6 * (1 - t)
        } else if leans {
            // The quiet ask: leaning in, pupils wide, holding eye
            // contact. `settle` ramps the pose in so the landing hands
            // off without a snap.
            let settle = Self.smooth(min(1, (age - 0.9) / 0.3))
            pose.lean = (11 + sin(phase * 1.7) * 2) * settle
            pose.squash = CGSize(width: 1 + 0.03 * settle, height: 1 + 0.07 * settle)
            pose.offset.height = (-0.6 + sin(phase * 3.4) * 0.4) * settle
        } else {
            // The wave proper: quick lean with a little bounce and sway.
            pose.lean = sin(phase * 7) * 13
            pose.offset.height = -abs(sin(phase * 7)) * 0.9
            pose.offset.width = sin(phase * 3.5) * 0.7
        }
        // Eyes on the "!" while it is up, then on you — the lean-in never
        // looks away.
        pose.look.height = leans ? -0.2 : (age < 1.3 ? -0.5 : 0)
        return pose
    }

    /// The completion hop: crouch, stretch up, fall, land flat. The
    /// sparkles live in `effects`.
    private var celebratingPose: Pose {
        var pose = Pose()
        pose.pupil = 2.2
        pose.mouth = .grin
        switch hopProgress ?? 1 {
        case ..<0.15:
            let t = (hopProgress ?? 1) / 0.15
            pose.squash = CGSize(width: 1 + 0.2 * t, height: 1 - 0.24 * t)
            pose.offset.height = 1.4 * t
        case ..<0.55:
            let t = ((hopProgress ?? 1) - 0.15) / 0.40
            let e = 1 - (1 - t) * (1 - t)
            pose.offset.height = 1.4 - 7.9 * e
            pose.air = e
            pose.squash = CGSize(width: 1 - 0.16 * e, height: 1 + 0.24 * e)
            pose.look.height = -0.4
        case ..<0.80:
            let t = ((hopProgress ?? 1) - 0.55) / 0.25
            let e = t * t
            pose.offset.height = -6.5 * (1 - e)
            pose.air = 1 - e
            pose.squash = CGSize(width: 1 - 0.16 * (1 - e), height: 1 + 0.24 * (1 - e))
        default:
            let t = ((hopProgress ?? 1) - 0.80) / 0.20
            let s = max(1 - t, 0)
            pose.squash = CGSize(width: 1 + 0.3 * s * s, height: 1 - 0.3 * s * s)
            pose.offset.height = 0.4 * s
        }
        return pose
    }

    /// Down and sagging: half-lidded, downcast, still slowly deflating.
    /// The first half second is the tumble — the blob rolls back to its
    /// feet with a little overshoot, then the sag takes over.
    private var slumpedPose: Pose {
        var pose = Pose()
        let sag = sin(phase * 0.5) * 0.5 + 0.5
        pose.offset.height = 2.2 + 0.3 * sag
        pose.squash = CGSize(width: 1.28, height: 0.68 - 0.04 * sag)
        pose.lid = 0.38
        pose.look.height = 0.6
        pose.mouth = .wobble
        let age = slumpAge ?? .infinity
        if age < 0.6 {
            // Tipped on its side, rolling upright; `backOut` overshoots
            // so it catches its balance, and `k` hands off to the slump.
            let k = 1 - Self.backOut(min(1, age / 0.55))
            pose.lean = -95 * k
            pose.offset.width = -3 * k
            pose.offset.height += 1.2 * k
            pose.squash.width -= 0.23 * k
            pose.squash.height += 0.17 * k
        }
        return pose
    }

    /// 0→1 lid while a blink plays. One blink per 4.25s beat, jittered
    /// inside the beat so consecutive gaps land between ~2.5s and ~6s.
    /// Runs in Reduce Motion too — a shut-eye frame is still a pose.
    private var blink: Double {
        guard mood != .asleep else { return 0 }
        let beat = 4.25
        let k = (phase / beat).rounded(.down)
        let start = (k + 0.15 + Self.hash(k) * 0.4) * beat
        let d = phase - start
        guard d >= 0, d < 0.16 else { return 0 }
        return sin(d / 0.16 * .pi)
    }

    private var lid: Double { min(1, pose.lid + blink) }

    // MARK: One-off effects

    /// The "!" pops once per waving ask: springs in, holds a beat,
    /// fades. The lean-in asks keep it in their pocket.
    private var bang: (scale: Double, opacity: Double) {
        guard mood == .waving, let waveAge, !leans else { return (0, 0) }
        if still { return (1, 1) }
        if waveAge < 0.25 { return (Self.backOut(waveAge / 0.25), 1) }
        if waveAge < 1.0 { return (1, 1) }
        if waveAge < 1.35 { return (1, 1 - (waveAge - 1.0) / 0.35) }
        return (0, 0)
    }

    /// Up to two "z"s drift off the head while it sleeps, staggered so
    /// they never leave together.
    private func zee(_ i: Int) -> (x: Double, y: Double, opacity: Double, scale: Double)? {
        guard mood == .asleep else { return nil }
        if still { return i == 0 ? (4, -5.5, 0.55, 1) : nil }
        let p = (phase / 2.8 + Double(i) * 0.55).truncatingRemainder(dividingBy: 1)
        let fade = p < 0.15 ? p / 0.15 : (p > 0.75 ? (1 - p) / 0.25 : 1)
        return (x: 3.6 + sin(p * .pi) * 1.6, y: -3 - p * 6.5,
                opacity: fade * 0.85, scale: 0.7 + 0.5 * p)
    }

    /// One sparkle thrown near the hop's apex; the green check pops on
    /// the other side.
    private var sparkle: (x: Double, y: Double, opacity: Double, scale: Double)? {
        guard mood == .celebrating else { return nil }
        if still { return (-5.4, -4.5, 0.7, 1) }
        guard let hopProgress else { return nil }
        let t = (hopProgress - 0.32) / 0.45
        guard t > 0, t < 1 else { return nil }
        let a = sin(t * .pi)
        return (x: -5.4, y: -4.5, opacity: a, scale: 0.6 + 0.6 * a)
    }

    /// A small green check pops once beside the hop's apex and fades as
    /// the buddy lands — the done checkmark, borrowed for the burst.
    private var check: (x: Double, y: Double, opacity: Double, scale: Double)? {
        guard mood == .celebrating else { return nil }
        if still { return (5.8, -6.4, 0.85, 1) }
        guard let hopProgress else { return nil }
        let t = (hopProgress - 0.40) / 0.14
        guard t > 0 else { return nil }
        let fade = hopProgress < 0.85 ? 1 : max(0, 1 - (hopProgress - 0.85) / 0.15)
        guard fade > 0.01 else { return nil }
        return (x: 5.8, y: -6.4, opacity: fade, scale: Self.backOut(min(t, 1)))
    }

    // MARK: Easing

    /// Smoothstep, clamped.
    private static func smooth(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Ease-out with a small overshoot, for the "!".
    private static func backOut(_ t: Double) -> Double {
        let c = 1.70158 + 1
        let u = min(t, 1) - 1
        return 1 + c * u * u * u + (c - 1) * u * u
    }

    /// A deterministic wobble in [0,1) — the classic sin-hash.
    private static func hash(_ n: Double) -> Double {
        let h = sin(n * 12.9898) * 43758.5453
        return h - h.rounded(.down)
    }

    // MARK: Drawing

    var body: some View {
        ZStack {
            // The shadow stays planted while the body leaves it; the
            // ghost hovers, so it always reads a little airborne.
            Ellipse()
                .fill(.black.opacity(0.22 * (1 - air * 0.55)))
                .frame(width: 8 * (1 - air * 0.35), height: 1.5)
                .offset(y: 7)
            ZStack {
                characterBody
                if mood == .asleep { cap }
                if pose.blush > 0.01 { cheeks }
            }
            .scaleEffect(x: pose.squash.width, y: pose.squash.height)
            .rotationEffect(.degrees(pose.lean + pose.spin))
            .offset(x: pose.offset.width + hover.width,
                    y: pose.offset.height + hover.height)
            effects
        }
    }

    /// Shadow lift: the pose's `air`, plus the standing hover the ghost
    /// and the saucer never land from.
    private var air: Double {
        let standing: Double = character == .ghost ? 0.3 : (character == .ufo ? 0.35 : 0)
        return min(1, pose.air + standing)
    }

    /// The ghost and the saucer never touch the ground: a slow float on
    /// top of whatever the pose is asking for — the ghost drifts, the
    /// UFO bobs and wanders a little wider.
    private var hover: CGSize {
        switch character {
        case .ghost:
            return CGSize(width: still ? 0 : sin(phase * 1.2) * 0.4,
                          height: -1.5 + (still ? 0 : sin(phase * 1.9) * 0.6))
        case .ufo:
            return CGSize(width: still ? 0 : sin(phase * 0.9) * 0.8,
                          height: -2.0 + (still ? 0 : sin(phase * 1.5) * 0.7))
        default:
            return .zero
        }
    }

    /// Where the cheeks land for each body — faces sit differently:
    /// the UFO's pilot is up in the dome, the mushroom's face is low on
    /// the stalk, the crab's is on stalks over a wide shell.
    private var blushSpot: (x: Double, y: Double) {
        switch character {
        case .ufo: return (1.7, -1.2)
        case .mushroom: return (2.6, 1.9)
        case .crab: return (4.4, 0.8)
        case .axolotl: return (4.9, 0.7)
        default: return (4.3, 0.9)
        }
    }

    /// The blush: two soft pink cheeks inside the squash, so a landing
    /// squash squashes them too.
    private var cheeks: some View {
        let at = blushSpot
        return ZStack {
            Ellipse().fill(Color(red: 0.98, green: 0.42, blue: 0.52).opacity(0.5 * pose.blush))
                .frame(width: 2.3, height: 1.4)
                .offset(x: -at.x, y: at.y)
            Ellipse().fill(Color(red: 0.98, green: 0.42, blue: 0.52).opacity(0.5 * pose.blush))
                .frame(width: 2.3, height: 1.4)
                .offset(x: at.x, y: at.y)
        }
    }

    /// The pose and effects are shared; only the body differs.
    @ViewBuilder private var characterBody: some View {
        switch character {
        case .dot:
            DotBody(tint: tint, pose: pose, lid: lid)
        case .cat:
            CatBody(mood: mood, tint: tint, pose: pose, lid: lid,
                    phase: phase, still: still)
        case .ghost:
            GhostBody(tint: tint, pose: pose, lid: lid)
        case .robot:
            RobotBody(mood: mood, tint: tint, pose: pose, lid: lid,
                      phase: phase, still: still)
        case .owl:
            OwlBody(mood: mood, tint: tint, pose: pose, lid: lid,
                    phase: phase, still: still)
        case .slime:
            SlimeBody(mood: mood, tint: tint, pose: pose, lid: lid,
                      phase: phase, still: still)
        case .axolotl:
            AxolotlBody(mood: mood, tint: tint, pose: pose, lid: lid,
                        phase: phase, still: still)
        case .crab:
            CrabBody(mood: mood, tint: tint, pose: pose, lid: lid,
                     phase: phase, still: still)
        case .mushroom:
            MushroomBody(mood: mood, tint: tint, pose: pose, lid: lid,
                         phase: phase, still: still)
        case .ufo:
            UFOBody(mood: mood, tint: tint, pose: pose, lid: lid,
                    phase: phase, still: still)
        }
    }

    /// The nightcap: a soft cone flopped over the head with a folded
    /// brim and a pom, drooping a lag behind the breath so it reads as
    /// fabric. It's part of the asleep pose — Reduce Motion keeps it.
    /// Drawn in a 10×6 box whose base sits on the blob's crown.
    private var cap: some View {
        let droop = still ? 6.0 : 6 + 5 * sin(phase * 1.1 - 0.7)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 1.0, y: 5.2))
                p.addQuadCurve(to: CGPoint(x: 4.4, y: 0.8), control: CGPoint(x: 1.8, y: 1.6))
                p.addQuadCurve(to: CGPoint(x: 9.2, y: 3.8), control: CGPoint(x: 7.6, y: 0.4))
                p.addQuadCurve(to: CGPoint(x: 1.0, y: 5.2), control: CGPoint(x: 5.4, y: 4.6))
            }
            .fill(Color(red: 0.55, green: 0.62, blue: 0.90))
            .frame(width: 10, height: 6)
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 1.7, height: 1.7)
                .offset(x: 4.2, y: 0.8)          // the pom on the tip
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: 7.4, height: 1.2)
                .offset(x: -1.0, y: 2.0)         // the folded brim
        }
        .frame(width: 10, height: 6)
        .rotationEffect(.degrees(droop), anchor: UnitPoint(x: 0.15, y: 0.85))
        .offset(y: -6.7)
    }

    /// The loose glyphs: "z"s overhead, the ask's "!", the hop's
    /// sparkle and check, the treat's hearts, the crumb's "+1". Drawn
    /// outside the squash so they stay honest. The robot throws a
    /// little gear instead of the fairy sparkle.
    @ViewBuilder private var effects: some View {
        if let z = zee(0) { zView(z) }
        if let z = zee(1) { zView(z) }
        if bang.opacity > 0.01 {
            Text(askCount > 1 ? "!\(askCount)" : "!")
                .font(.system(size: askCount > 1 ? 5.2 : 7, weight: .black, design: .rounded))
                .foregroundStyle(.orange)
                .scaleEffect(max(bang.scale, 0.01))
                .offset(y: -8)
                .opacity(bang.opacity)
        }
        if let s = sparkle {
            if character == .robot { gearSparkleView(s) } else { sparkleView(s) }
        }
        if let c = check { checkView(c) }
        if let treatAge { heartsView(age: treatAge) }
        if let crumbAge { crumbView(age: crumbAge) }
    }

    /// Three hearts off the crown when a treat lands, staggered and
    /// rising. Reduce Motion holds them still — a heart that doesn't
    /// float is still a heart.
    @ViewBuilder private func heartsView(age: TimeInterval) -> some View {
        if age >= 0, age < 1.0 {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = still ? 0.45 : min(1, max(0, (age - Double(i) * 0.11) / 0.7))
                    Image(systemName: "heart.fill")
                        .font(.system(size: [4.4, 5.6, 4.0][i], weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.6))
                        .offset(x: [-4.4, 0.6, 4.2][i] + (still ? 0 : sin(age * 5 + Double(i)) * 0.5),
                                y: -6 - p * 6.5)
                        .opacity(still ? 0.85 : (p <= 0 ? 0 : (p > 0.62 ? (1 - p) / 0.38 : 0.95)))
                        .scaleEffect(0.55 + 0.55 * p)
                }
            }
        }
    }

    /// Eating a completed session: the morsel drops into the mouth,
    /// then "+1" floats off the side. Reduce Motion shows the "+1"
    /// without the drop.
    @ViewBuilder private func crumbView(age: TimeInterval) -> some View {
        if age >= 0, age < 1.1 {
            if !still, age < 0.32 {
                let t = age / 0.32
                Circle()
                    .fill(Color(red: 0.85, green: 0.62, blue: 0.32))
                    .frame(width: 1.7, height: 1.7)
                    .offset(x: -6.5 * (1 - t), y: -8.5 + 11 * t * t)
            }
            let p = still ? 0 : min(1, max(0, (age - 0.2) / 0.75))
            Text("+1")
                .font(.system(size: 4.6, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .offset(x: 4.8, y: -7 - p * 5)
                .opacity(still ? 0.8 : (p > 0.6 ? (1 - p) / 0.4 : 0.9))
        }
    }

    private func zView(_ z: (x: Double, y: Double, opacity: Double, scale: Double)) -> some View {
        Text("z")
            .font(.system(size: 4.5, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .scaleEffect(z.scale)
            .offset(x: z.x, y: z.y)
            .opacity(z.opacity)
    }

    private func sparkleView(_ s: (x: Double, y: Double, opacity: Double, scale: Double)) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: 5, weight: .bold))
            .foregroundStyle(.white)
            .scaleEffect(s.scale)
            .offset(x: s.x, y: s.y)
            .opacity(s.opacity)
    }

    /// The robot's idea of a celebration: a little thrown gear that
    /// spins instead of twinkling.
    private func gearSparkleView(_ s: (x: Double, y: Double, opacity: Double, scale: Double)) -> some View {
        Image(systemName: "gear")
            .font(.system(size: 5.5, weight: .bold))
            .foregroundStyle(Color(white: 0.8))
            .rotationEffect(.degrees(still ? 20 : phase * 160))
            .scaleEffect(s.scale)
            .offset(x: s.x, y: s.y)
            .opacity(s.opacity)
    }

    private func checkView(_ c: (x: Double, y: Double, opacity: Double, scale: Double)) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0.3, y: 1.6))
            p.addLine(to: CGPoint(x: 1.5, y: 2.8))
            p.addLine(to: CGPoint(x: 3.9, y: 0.2))
        }
        .stroke(Color(red: 0.35, green: 0.9, blue: 0.45),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        .frame(width: 4.2, height: 3)
        .scaleEffect(c.scale)
        .offset(x: c.x, y: c.y)
        .opacity(c.opacity)
    }
}

// MARK: - Faces

/// The colour a feature takes when it reads as a hole punched through
/// the body to the capsule behind it — Dot's and Cat's pupils and
/// mouths. Translucent bodies use a dark fill instead. Shared with the
/// extra bodies in `NotchBuddyBodies`.
let buddyHole = Color(nsColor: .windowBackgroundColor)

/// The pair of eyes most bodies wear: a pupil that drifts with
/// `pose.look`, a catchlight glued to its top-left, and a lid in the
/// body's own colour that slides down over it — closing reads as the
/// body growing over the eye. `pose.eyesClosed` (asleep) draws a shut
/// line instead. The owl draws its own, bigger.
struct BuddyEyes: View {
    let pose: BuddyFigure.Pose
    let lid: Double
    /// The open pupil's colour.
    let pupilColor: Color
    /// The lid's colour — the body's own.
    let lidColor: Color
    /// Pupil diameter multiplier; translucent bodies run a touch smaller.
    var pupilScale: Double = 1.0
    /// How far the pupils travel with `pose.look`.
    var lookScale: Double = 1.0

    var body: some View {
        HStack(spacing: 1.8) {
            eye
            eye
        }
    }

    private var eye: some View {
        ZStack {
            if pose.eyesClosed {
                Capsule().fill(pupilColor).frame(width: 2.3, height: 0.8)
            } else {
                let p = pose.pupil * pupilScale
                Circle().fill(pupilColor)
                    .frame(width: p, height: p)
                    .offset(x: pose.look.width * lookScale, y: pose.look.height * lookScale)
                // The catchlight stays inside the pupil and lags the look
                // a little, the way a reflection does.
                Circle().fill(.white.opacity(0.85))
                    .frame(width: p * 0.34, height: p * 0.34)
                    .offset(x: pose.look.width * lookScale * 0.8 - p * 0.2,
                            y: pose.look.height * lookScale * 0.8 - p * 0.22)
                if lid > 0.01 {
                    let lidHeight = 0.5 + 4.0 * lid
                    Capsule().fill(lidColor)
                        .frame(width: 4.6, height: lidHeight)
                        .offset(y: -2.0 + lidHeight / 2)
                }
            }
        }
        .frame(width: 2.6, height: 4.4)
    }
}

/// The shared mouth set — `pose.mouth` picks the shape: `flat` patrols,
/// `wobble` fails, `open` asks, `smile` bounces, `grin` celebrates.
/// Cat draws its own ω and Owl a beak; everyone else shares these.
struct BuddyMouth: View {
    let mouth: BuddyFigure.Mouth
    let color: Color
    var y: Double = 2.4

    var body: some View {
        switch mouth {
        case .none:
            EmptyView()
        case .flat:
            Capsule().fill(color).frame(width: 2.0, height: 0.7).offset(y: y)
        case .wobble:
            // The worried squiggle — a failure, not a frown.
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.9))
                p.addQuadCurve(to: CGPoint(x: 1.1, y: 0.2), control: CGPoint(x: 0.55, y: -0.3))
                p.addQuadCurve(to: CGPoint(x: 2.2, y: 0.9), control: CGPoint(x: 1.65, y: 1.6))
                p.addQuadCurve(to: CGPoint(x: 3.3, y: 0.2), control: CGPoint(x: 2.75, y: -0.3))
                p.addQuadCurve(to: CGPoint(x: 4.4, y: 0.9), control: CGPoint(x: 3.85, y: 1.6))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
            .frame(width: 4.4, height: 1.5)
            .offset(y: y)
        case .open:
            Capsule().fill(color).frame(width: 1.7, height: 1.5).offset(y: y)
        case .smile:
            Path { p in
                p.addArc(center: CGPoint(x: 2.5, y: 1.6), radius: 1.6,
                         startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            .frame(width: 5, height: 4)
            .offset(y: y - 0.8)
        case .grin:
            // The open grin: a half-moon, flat side up.
            Path { p in
                p.addArc(center: CGPoint(x: 2.4, y: 0.4), radius: 2.0,
                         startAngle: .degrees(18), endAngle: .degrees(162), clockwise: false)
                p.closeSubpath()
            }
            .fill(color)
            .frame(width: 4.8, height: 2.6)
            .offset(y: y - 0.3)
        }
    }
}

// MARK: - Dot

/// Dot — the original: a soft rounded square lit from the top-left,
/// eyes and mouth as holes to the capsule, every mouth in the set.
private struct DotBody: View {
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double

    var body: some View {
        ZStack {
            blob
            BuddyEyes(pose: pose, lid: lid, pupilColor: buddyHole, lidColor: tint)
                .offset(y: -1.0)
            BuddyMouth(mouth: pose.mouth, color: buddyHole)
        }
        .offset(y: 0.5)
    }

    /// Not a circle: a soft rounded square, bright at the top-left and
    /// darkening toward the bottom-right with a sheen on the crown.
    private var blob: some View {
        let shape = RoundedRectangle(cornerRadius: 5.2, style: .continuous)
        return ZStack {
            shape.fill(tint)
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().fill(.white.opacity(0.24))
                .frame(width: 5.0, height: 2.4)
                .rotationEffect(.degrees(-22))
                .offset(x: -2.4, y: -3.0)
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
        }
        .frame(width: 12.5, height: 11)
        .clipShape(shape)
    }
}

// MARK: - Cat

/// Cat — Dot's blob a touch shorter, plus the parts with opinions:
/// ears that prick for asks and flatten for the slump, whiskers, a tail
/// that wags on the good moods and flops out along the ground on the
/// bad ones, and a proper ω mouth that drops its tongue on the hop.
private struct CatBody: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// 1 is pricked, -0.5 is flattened; each mood's ear posture.
    private var earPerk: Double {
        switch mood {
        case .waving, .celebrating: return 1.0
        case .gathering: return 0.7
        case .pacing: return 0.3
        case .slumped, .asleep: return -0.5
        }
    }

    var body: some View {
        ZStack {
            tail
            ear(left: true)
            ear(left: false)
            blob
            BuddyEyes(pose: pose, lid: lid, pupilColor: buddyHole, lidColor: tint)
                .offset(y: -1.0)
            whiskers
            mouth
        }
        .offset(y: 0.5)
    }

    private var blob: some View {
        let shape = RoundedRectangle(cornerRadius: 4.8, style: .continuous)
        return ZStack {
            shape.fill(tint)
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().fill(.white.opacity(0.22))
                .frame(width: 4.6, height: 2.2)
                .rotationEffect(.degrees(-22))
                .offset(x: -2.2, y: -2.6)
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
        }
        .frame(width: 11.6, height: 9.6)
        .clipShape(shape)
        .offset(y: 1.0)
    }

    /// A triangle with an inner ear, hinged at its base: pricked it
    /// stands near-upright, flattened it splays outward and sinks.
    private func ear(left: Bool) -> some View {
        let side: Double = left ? -1 : 1
        let angle = side * (8 + (1 - earPerk) * 30)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0.1, y: 3.6))
                p.addLine(to: CGPoint(x: 1.9, y: 0))
                p.addLine(to: CGPoint(x: 3.7, y: 3.6))
                p.addQuadCurve(to: CGPoint(x: 0.1, y: 3.6), control: CGPoint(x: 1.9, y: 2.9))
            }
            .fill(tint)
            Path { p in
                p.move(to: CGPoint(x: 1.2, y: 3.1))
                p.addLine(to: CGPoint(x: 1.9, y: 1.4))
                p.addLine(to: CGPoint(x: 2.7, y: 3.1))
                p.closeSubpath()
            }
            .fill(.white.opacity(0.4))
        }
        .frame(width: 3.8, height: 3.6)
        .rotationEffect(.degrees(angle), anchor: .bottom)
        .offset(x: side * 3.1, y: -3.9 + (1 - earPerk) * 1.1)
    }

    /// Two whiskers a side, drawn faint so they read as whiskers, not
    /// scratches.
    private var whiskers: some View {
        ZStack {
            whisker.rotationEffect(.degrees(-9)).offset(x: -6.1, y: 0.7)
            whisker.rotationEffect(.degrees(7)).offset(x: -6.0, y: 1.7)
            whisker.rotationEffect(.degrees(9)).offset(x: 6.1, y: 0.7)
            whisker.rotationEffect(.degrees(-7)).offset(x: 6.0, y: 1.7)
        }
    }

    private var whisker: some View {
        Capsule().fill(.white.opacity(0.5)).frame(width: 2.6, height: 0.35)
    }

    /// A curve off the right hip, hinged at the base: up and curling on
    /// the good moods, out along the ground for the slump, tucked when
    /// asleep. The wag rides on top of the resting angle.
    private var tail: some View {
        let rest: Double
        let wag: Double
        switch mood {
        case .celebrating: rest = -20; wag = still ? 0 : sin(phase * 9) * 9
        case .waving:      rest = -12; wag = still ? 0 : sin(phase * 7) * 7
        case .gathering:   rest = -16; wag = still ? 0 : sin(phase * 8) * 8
        case .pacing:      rest = -4;  wag = still ? 0 : sin(phase * 2.4) * 7
        case .asleep:      rest = 32;  wag = still ? 0 : sin(phase * 1.1) * 2
        case .slumped:     rest = 68;  wag = 0
        }
        return Path { p in
            // Frame space, 7.5×6: base at the bottom-left, tip curling
            // up-right. The rotation pins the base.
            p.move(to: CGPoint(x: 0.6, y: 5.2))
            p.addQuadCurve(to: CGPoint(x: 6.9, y: 1.0), control: CGPoint(x: 5.6, y: 5.6))
        }
        .stroke(tint, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
        .frame(width: 7.5, height: 6)
        .rotationEffect(.degrees(rest + wag), anchor: UnitPoint(x: 0.08, y: 0.87))
        .offset(x: 6.6, y: 1.3)
    }

    /// The cat mouth: a ω for the good moods, an "o" for the ask, the
    /// shared squiggle for a failure, and a tiny tongue on the hop.
    @ViewBuilder private var mouth: some View {
        switch pose.mouth {
        case .none:
            EmptyView()
        case .flat:
            Capsule().fill(buddyHole).frame(width: 1.7, height: 0.6).offset(y: 2.7)
        case .wobble:
            BuddyMouth(mouth: .wobble, color: buddyHole, y: 2.8)
        case .open:
            Capsule().fill(buddyHole).frame(width: 1.5, height: 1.4).offset(y: 2.7)
        case .smile, .grin:
            Path { p in
                p.addArc(center: CGPoint(x: 1.0, y: 0.5), radius: 0.9,
                         startAngle: .degrees(15), endAngle: .degrees(165), clockwise: false)
                p.move(to: CGPoint(x: 3.87, y: 0.73))
                p.addArc(center: CGPoint(x: 3.0, y: 0.5), radius: 0.9,
                         startAngle: .degrees(15), endAngle: .degrees(165), clockwise: false)
            }
            .stroke(buddyHole, style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            .frame(width: 4, height: 1.9)
            .offset(y: 2.55)
            if pose.mouth == .grin {
                Capsule().fill(Color(red: 0.96, green: 0.55, blue: 0.6))
                    .frame(width: 1.3, height: 0.9)
                    .offset(y: 3.5)
            }
        }
    }
}

// MARK: - Ghost

/// Ghost — a translucent sheet with a wavy hem that hovers over its own
/// shadow (the skeleton owns the float; this only draws the cloth).
/// Eyes and mouth are dark reads in the sheet, not holes — there's
/// nothing behind them but air.
private struct GhostBody: View {
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double

    /// Ghost features are dark, not cut out — the sheet is see-through.
    private var feature: Color { Color(white: 0.10).opacity(0.8) }

    var body: some View {
        ZStack {
            sheet
            BuddyEyes(pose: pose, lid: lid, pupilColor: feature,
                      lidColor: tint.opacity(0.85), pupilScale: 0.85)
                .offset(y: -1.7)
            BuddyMouth(mouth: pose.mouth, color: feature.opacity(0.9), y: 1.4)
        }
    }

    /// The sheet: a dome with three soft scallops for a hem, lit at the
    /// crown and rimmed so it reads as cloth over air.
    private var sheet: some View {
        let path = Path { p in
            p.move(to: CGPoint(x: 0.7, y: 8.4))
            p.addLine(to: CGPoint(x: 0.7, y: 4.6))
            // 180°→0° counterclockwise sweeps over the top — the dome.
            p.addArc(center: CGPoint(x: 6.0, y: 4.6), radius: 5.3,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 11.3, y: 8.4))
            p.addQuadCurve(to: CGPoint(x: 7.6, y: 8.4), control: CGPoint(x: 9.4, y: 10.6))
            p.addQuadCurve(to: CGPoint(x: 4.1, y: 8.4), control: CGPoint(x: 5.8, y: 10.6))
            p.addQuadCurve(to: CGPoint(x: 0.7, y: 8.4), control: CGPoint(x: 2.3, y: 10.6))
        }
        return ZStack {
            path.fill(tint.opacity(0.7))
            path.fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                     startPoint: .top, endPoint: .center))
            path.stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.55))
        }
        .frame(width: 12, height: 11)
        .offset(y: -0.6)
    }
}

// MARK: - Robot

/// Robot — a brushed-metal rounded square with a glass visor: the eyes
/// are LED pixels behind it that drift, blink and slit shut, the mouth
/// is the same shape set in LED glow, and a side antenna ends in a
/// lamp that pulses while an ask is up. Its celebration sparkle is a
/// thrown gear.
private struct RobotBody: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// The LED colour: the mood's tint — provider accent on the clock,
    /// amber on the ask, red on the fail, green on the hop, dim asleep.
    private var led: Color { tint }

    var body: some View {
        ZStack {
            antenna
            shell
            visor
            BuddyMouth(mouth: pose.mouth, color: led, y: 3.4)
        }
        .offset(y: 0.4)
    }

    /// Off the left shoulder so it never collides with the "!": a stem
    /// and a lamp that breathes while an ask is open.
    private var antenna: some View {
        let pulse = mood == .waving && !still ? 0.55 + 0.45 * sin(phase * 9) : 1.0
        return ZStack {
            Capsule().fill(Color(white: 0.5)).frame(width: 0.9, height: 2.6)
                .offset(y: 0.9)
            Circle().fill(led).frame(width: 2.1, height: 2.1)
                .shadow(color: led.opacity(0.8), radius: 0.9)
                .offset(y: -0.9)
            Circle().fill(.white.opacity(0.75)).frame(width: 0.7, height: 0.7)
                .offset(x: -0.35, y: -1.25)
        }
        .frame(width: 3, height: 4.2)
        .opacity(pulse)
        .offset(x: -3.6, y: -5.6)
    }

    /// The chassis: a metal gradient washed toward the mood tint, a
    /// sheen across the top edge and a bolt at each hip.
    private var shell: some View {
        let shape = RoundedRectangle(cornerRadius: 3.2, style: .continuous)
        return ZStack {
            ZStack {
                shape.fill(LinearGradient(colors: [Color(white: 0.80), Color(white: 0.55)],
                                          startPoint: .top, endPoint: .bottom))
                shape.fill(tint.opacity(0.35))
                Ellipse().fill(.white.opacity(0.3))
                    .frame(width: 4.4, height: 1.6)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -2.8, y: -4.0)
                shape.strokeBorder(.black.opacity(0.22), lineWidth: 0.5)
            }
            .clipShape(shape)
            Circle().fill(Color(white: 0.42)).frame(width: 1.4, height: 1.4)
                .offset(x: -6.2, y: 1.4)
            Circle().fill(Color(white: 0.42)).frame(width: 1.4, height: 1.4)
                .offset(x: 6.2, y: 1.4)
        }
        .frame(width: 12, height: 10)
        .offset(y: 0.6)
    }

    /// The dark band across the face with the two LED eyes behind it.
    private var visor: some View {
        let glass = RoundedRectangle(cornerRadius: 2.3, style: .continuous)
        return ZStack {
            glass.fill(Color(white: 0.08))
            glass.fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                      startPoint: .top, endPoint: .center))
            HStack(spacing: 2.6) {
                ledEye
                ledEye
            }
            glass.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .frame(width: 9.8, height: 4.8)
        .offset(y: -0.9)
    }

    /// One pixel eye: a rounded LED that drifts with `look`, glows in
    /// the mood's colour, slides under a dark lid, slits shut asleep.
    private var ledEye: some View {
        ZStack {
            if pose.eyesClosed {
                Capsule().fill(led).frame(width: 1.9, height: 0.55)
            } else {
                RoundedRectangle(cornerRadius: 0.55, style: .continuous)
                    .fill(led)
                    .frame(width: 1.5, height: max(1.2, pose.pupil * 0.9))
                    .offset(x: pose.look.width * 1.1, y: pose.look.height * 0.8)
                    .shadow(color: led.opacity(0.9), radius: 0.7)
                if lid > 0.01 {
                    let lidHeight = 0.4 + 3.4 * lid
                    Capsule().fill(Color(white: 0.08))
                        .frame(width: 3.2, height: lidHeight)
                        .offset(y: -2.0 + lidHeight / 2)
                }
            }
        }
        .frame(width: 2.4, height: 4.2)
    }
}

// MARK: - Owl

/// Owl — the eyes are the whole point: two huge discs whose pupils ride
/// `look` amplified, so they visibly track the "!" overhead and pin
/// you on the lean-in. Feather tufts prick like the cat's ears, the
/// wings lift on the hop and flutter on a gathering, the beak parts for
/// the ask, and asleep the discs squint into happy arcs.
private struct OwlBody: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    private var beakColor: Color { Color(red: 0.98, green: 0.66, blue: 0.22) }

    /// 1 is alert, -0.6 is drooped; the tufts' posture per mood.
    private var perk: Double {
        switch mood {
        case .waving, .celebrating: return 1.0
        case .gathering: return 0.5
        case .pacing: return 0.15
        case .slumped, .asleep: return -0.6
        }
    }

    var body: some View {
        ZStack {
            wing(left: true)
            wing(left: false)
            egg
            tuft(left: true)
            tuft(left: false)
            eyes
            beak
        }
        .offset(y: 0.4)
    }

    /// The egg body with a pale belly — owls are front-loaded.
    private var egg: some View {
        let shape = Ellipse()
        return ZStack {
            shape.fill(tint)
            shape.fill(LinearGradient(colors: [.white.opacity(0.15), .clear, .black.opacity(0.16)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse().fill(.white.opacity(0.16))
                .frame(width: 7.4, height: 5.6)
                .offset(y: 2.2)
            shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.55)
        }
        .frame(width: 12.2, height: 11.0)
        .clipShape(shape)
        .offset(y: 0.6)
    }

    /// The pointed ear-tuft over each eye: splayed up when alert,
    /// folded flat for sleep and the slump.
    private func tuft(left: Bool) -> some View {
        let side: Double = left ? -1 : 1
        let angle = side * (16 + perk * 14)
        return Path { p in
            p.move(to: CGPoint(x: 0.1, y: 2.8))
            p.addQuadCurve(to: CGPoint(x: 1.0, y: 0), control: CGPoint(x: 0.1, y: 0.9))
            p.addQuadCurve(to: CGPoint(x: 2.1, y: 2.8), control: CGPoint(x: 2.0, y: 0.9))
            p.addQuadCurve(to: CGPoint(x: 0.1, y: 2.8), control: CGPoint(x: 1.05, y: 2.2))
        }
        .fill(tint)
        .frame(width: 2.2, height: 2.8)
        .rotationEffect(.degrees(angle), anchor: .bottom)
        .offset(x: side * 3.3, y: -5.1 + (1 - perk) * 0.8)
    }

    /// A small wing hanging from each shoulder. The hop raises both and
    /// the gathering flutters them; everything else leaves them folded.
    private func wing(left: Bool) -> some View {
        let side: Double = left ? -1 : 1
        let lift = mood == .celebrating ? 1.0 : (mood == .waving ? 0.45 : 0.0)
        let flutter = (mood == .celebrating || mood == .gathering) && !still
            ? sin(phase * 10 + (left ? 0 : 1.3)) * 7 : 0
        return Ellipse()
            .fill(tint)
            .overlay(Ellipse().fill(.black.opacity(0.14)))
            .frame(width: 3.4, height: 6.6)
            .rotationEffect(.degrees(side * (10 + lift * 62) + flutter * side), anchor: .top)
            .offset(x: side * 5.7, y: -1.4)
    }

    /// Two huge discs, edge to edge. `look` is amplified so the pupils
    /// visibly chase the "!"; the lid slides over the disc, and asleep
    /// the whole eye becomes a happy shut arc.
    private var eyes: some View {
        HStack(spacing: 0.4) {
            eye
            eye
        }
        .offset(y: -1.3)
    }

    private var eye: some View {
        ZStack {
            Circle().fill(Color(white: 0.97))
            if pose.eyesClosed {
                // ⌒ — a slept-in happy arc.
                Path { p in
                    p.addArc(center: CGPoint(x: 2.3, y: 2.9), radius: 1.5,
                             startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
                }
                .stroke(Color(white: 0.15), style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
            } else {
                let p = min(pose.pupil * 1.45, 3.4)
                Circle().fill(Color(white: 0.10))
                    .frame(width: p, height: p)
                    .offset(x: pose.look.width * 1.5, y: pose.look.height * 1.3)
                Circle().fill(.white.opacity(0.9))
                    .frame(width: p * 0.34, height: p * 0.34)
                    .offset(x: pose.look.width * 1.5 - p * 0.2,
                            y: pose.look.height * 1.3 - p * 0.22)
                if lid > 0.01 {
                    let lidHeight = 0.6 + 4.8 * lid
                    Capsule().fill(tint)
                        .frame(width: 5.4, height: lidHeight)
                        .offset(y: -2.5 + lidHeight / 2)
                }
            }
            Circle().strokeBorder(tint.opacity(0.45), lineWidth: 0.5)
        }
        .frame(width: 4.6, height: 4.6)
        .clipShape(Circle())
    }

    /// A tiny beak stands in for the mouth: closed on patrol, parted
    /// for the ask, hinged wide for the hop.
    @ViewBuilder private var beak: some View {
        switch pose.mouth {
        case .none, .flat, .wobble, .smile:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 1.7, y: 0))
                p.addLine(to: CGPoint(x: 0.85, y: 1.5))
                p.closeSubpath()
            }
            .fill(beakColor)
            .frame(width: 1.7, height: 1.5)
            .offset(y: 1.5)
        case .open, .grin:
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 1.7, y: 0))
                    p.addLine(to: CGPoint(x: 0.85, y: 0.9))
                    p.closeSubpath()
                }
                .fill(beakColor)
                Path { p in
                    p.move(to: CGPoint(x: 0.25, y: 1.15))
                    p.addLine(to: CGPoint(x: 1.45, y: 1.15))
                    p.addLine(to: CGPoint(x: 0.85, y: 2.1))
                    p.closeSubpath()
                }
                .fill(beakColor.opacity(0.85))
            }
            .frame(width: 1.7, height: 2.1)
            .offset(y: 1.5)
        }
    }
}

// MARK: - Slime

/// Slime — a gooey translucent drop. The tip wobbles on its own clock,
/// kicked harder the further the body is off its rest shape, so every
/// landing rings through it; the slump melts it wider and keels the tip
/// over; the hop pinches a droplet off the crown at the apex. A sheen
/// up-left keeps it reading wet.
private struct SlimeBody: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    let pose: BuddyFigure.Pose
    let lid: Double
    let phase: TimeInterval
    let still: Bool

    /// The tip's lag: a base sway plus a kick that scales with the
    /// squash and the airtime — landings ring, stillness settles.
    private var tipWobble: Double {
        guard !still else { return 0.4 }
        let energy = min(1.4, abs(1 - pose.squash.height) * 4 + pose.air * 1.2)
        return sin(phase * 7.5) * (0.35 + energy * 1.1)
    }

    /// 1 in the slump: the base spreads and the tip keels.
    private var melt: Double { mood == .slumped ? 1 : 0 }

    /// Slime features are dark reads in the goo, not holes.
    private var feature: Color { Color(white: 0.10).opacity(0.8) }

    var body: some View {
        ZStack {
            droplet
            blob
            BuddyEyes(pose: pose, lid: lid, pupilColor: feature,
                      lidColor: tint.opacity(0.9), pupilScale: 0.9)
                .offset(y: -0.6)
            BuddyMouth(mouth: pose.mouth, color: feature.opacity(0.9), y: 2.9)
        }
        .offset(y: 0.5)
    }

    /// The drop: a wide sagging base tapering to a wandering tip. `melt`
    /// spreads the base and drags the tip down-right; `tipWobble` is
    /// the secondary motion — it lags every squash the skeleton applies.
    private var blob: some View {
        let halfW = 5.7 + melt * 1.3
        let tipX = 6.5 + tipWobble + melt * 2.2
        let tipY = 0.7 + melt * 2.6
        let baseY = 10.6
        let path = Path { p in
            p.move(to: CGPoint(x: 6.5 - halfW, y: baseY))
            // Up the left side to the tip.
            p.addCurve(to: CGPoint(x: tipX, y: tipY),
                       control1: CGPoint(x: 6.5 - halfW - 0.4, y: baseY - 5.4),
                       control2: CGPoint(x: tipX - 3.4, y: tipY + 1.6))
            // Down the right side.
            p.addCurve(to: CGPoint(x: 6.5 + halfW, y: baseY),
                       control1: CGPoint(x: tipX + 3.0, y: tipY + 1.8),
                       control2: CGPoint(x: 6.5 + halfW + 0.6, y: baseY - 5.8))
            // The base sags a touch in the middle.
            p.addQuadCurve(to: CGPoint(x: 6.5 - halfW, y: baseY),
                           control: CGPoint(x: 6.5, y: baseY + 0.9))
        }
        return ZStack {
            path.fill(tint.opacity(0.78))
            path.fill(LinearGradient(colors: [.white.opacity(0.20), .clear, .black.opacity(0.10)],
                                     startPoint: .top, endPoint: .bottom))
            Ellipse().fill(.white.opacity(0.45))
                .frame(width: 3.4, height: 1.7)
                .rotationEffect(.degrees(-28))
                .offset(x: -2.7, y: -2.0)
            Circle().fill(.white.opacity(0.5)).frame(width: 0.9, height: 0.9)
                .offset(x: -1.6, y: -3.1)
            path.stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.55))
        }
        .frame(width: 13, height: 11)
        .offset(y: -0.1)
    }

    /// The hop sheds a droplet: it pinches off the crown with the
    /// skeleton's `air` and hangs a beat. Reduce Motion parks it
    /// mid-separation.
    @ViewBuilder private var droplet: some View {
        let sep = mood == .celebrating ? (still ? 0.75 : pose.air) : 0
        if sep > 0.04 {
            Circle()
                .fill(tint.opacity(0.8))
                .frame(width: 2.0, height: 2.0)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.4))
                .offset(x: -4.6 - sep * 0.6, y: -4.2 - sep * 4.0)
                .opacity(min(1, sep * 2.4))
        }
    }
}
