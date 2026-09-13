import AppKit
import JRBarCore
import SwiftUI

/// The buddy itself: a small drawn blob with eyes, a mouth and a ground
/// shadow — one character ("dot") to start. Pose and tint come from
/// `NotchBuddyToy.mood`; `TimelineView(.animation)` drives the walk, the
/// wave, the hop and the blink, and Reduce Motion swaps the moving poses
/// for still ones (the blink stays — a closed eye is a pose too).
struct NotchBuddyView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window a hop plays across; `NotchBuddyToy.hopUntil` sets it.
    private static let hopDuration: TimeInterval = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let mood = toy.mood(at: context.date)
            DotBuddy(
                mood: mood,
                tint: tint(for: mood),
                phase: context.date.timeIntervalSince1970,
                hopProgress: hopProgress(at: context.date),
                waveAge: waveAge(at: context.date, mood: mood),
                still: reduceMotion
            )
        }
        .frame(width: 18, height: 18)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .fixedSize()
        .accessibilityLabel("Notch Buddy")
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

    private func tint(for mood: NotchBuddyToy.Mood) -> Color {
        switch mood {
        case .asleep: return Color(nsColor: .tertiaryLabelColor)
        case .pacing:
            // One provider working → the buddy wears its colour.
            if let provider = toy.workingProvider {
                return ProviderStyle.style(for: provider).accent
            }
            return .accentColor
        case .waving: return .orange
        case .slumped: return .red
        case .celebrating: return .green
        }
    }
}

/// The "dot" character: a soft blob body, two pupils under lids, a small
/// mouth and a ground shadow. Each mood is a pose with the craft in the
/// motion — pacing steps and turns at the ends, the wave and the hop
/// crouch first and land flat, sleep drifts "z"s, and every awake mood
/// blinks on a jittered cadence.
private struct DotBuddy: View {
    let mood: NotchBuddyToy.Mood
    let tint: Color
    /// Seconds, monotonic — the animation clock.
    let phase: TimeInterval
    /// 0→1 while a completion hop plays, else nil.
    let hopProgress: Double?
    /// Seconds since the wave began, else nil.
    let waveAge: TimeInterval?
    /// Reduce Motion: poses stay, motion goes.
    let still: Bool

    /// Eyes and mouth read as holes in the blob, cut through to the pill.
    private var cutout: Color { Color(nsColor: .windowBackgroundColor) }

    // MARK: Pose

    private enum Mouth { case none, flat, open, smile }

    /// Everything the frame needs, resolved once per tick.
    private struct Pose {
        var offset = CGSize.zero
        var squash = CGSize(width: 1, height: 1)
        var lean = 0.0          // degrees
        var look = CGSize.zero  // pupil drift inside the eye
        var lid = 0.0           // resting lid, 0 open → 1 closed
        var air = 0.0           // 0 grounded → 1 apex; drives the shadow
        var pupil = 2.1
        var mouth = Mouth.none
        var eyesClosed = false  // asleep draws lid lines, not pupils
    }

    private var pose: Pose {
        if still { return stillPose }
        switch mood {
        case .asleep: return asleepPose
        case .pacing: return pacingPose
        case .waving: return wavingPose
        case .slumped: return slumpedPose
        case .celebrating: return celebratingPose
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
        case .waving:
            pose.lean = 10
            pose.pupil = 2.4
            pose.look.height = -0.5
            pose.mouth = .open
        case .slumped:
            pose.offset.height = 2.2
            pose.squash = CGSize(width: 1.28, height: 0.68)
            pose.lid = 0.38
            pose.look.height = 0.6
            pose.mouth = .flat
        case .celebrating:
            pose.pupil = 2.2
            pose.look.height = -0.3
            pose.mouth = .smile
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

    /// The ask: a crouch, a jump, a landing — once — then a fast wave.
    private var wavingPose: Pose {
        var pose = Pose()
        pose.pupil = 2.4
        pose.mouth = .open
        let age = waveAge ?? .infinity
        if age < 0.14 {
            // Anticipation crouch.
            let t = age / 0.14
            pose.squash = CGSize(width: 1 + 0.16 * t, height: 1 - 0.2 * t)
            pose.offset.height = 1.4 * t
        } else if age < 0.55 {
            // The jump up, easing out.
            let t = (age - 0.14) / 0.41
            let e = 1 - (1 - t) * (1 - t)
            pose.offset.height = 1.4 - 6.9 * e
            pose.air = e
            pose.squash = CGSize(width: 1 - 0.14 * e, height: 1 + 0.2 * e)
            pose.lean = 6 * e
        } else if age < 0.9 {
            // Falling, then a flat land-squash that releases.
            let t = (age - 0.55) / 0.35
            pose.offset.height = -5.5 * (1 - t * t)
            pose.air = 1 - t * t
            let impact = sin(min(t / 0.45, 1) * .pi)
            pose.squash = CGSize(width: 1 + 0.22 * impact, height: 1 - 0.24 * impact)
            pose.lean = 6 * (1 - t)
        } else {
            // The wave proper: quick lean with a little bounce and sway.
            pose.lean = sin(phase * 7) * 13
            pose.offset.height = -abs(sin(phase * 7)) * 0.9
            pose.offset.width = sin(phase * 3.5) * 0.7
        }
        // Eyes on the "!" while it is up, then on you.
        pose.look.height = age < 1.3 ? -0.5 : 0
        return pose
    }

    /// The completion hop: crouch, stretch up, fall, land flat. The
    /// sparkles live in `effects`.
    private var celebratingPose: Pose {
        var pose = Pose()
        pose.pupil = 2.2
        pose.mouth = .smile
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
    private var slumpedPose: Pose {
        var pose = Pose()
        let sag = sin(phase * 0.5) * 0.5 + 0.5
        pose.offset.height = 2.2 + 0.3 * sag
        pose.squash = CGSize(width: 1.28, height: 0.68 - 0.04 * sag)
        pose.lid = 0.38
        pose.look.height = 0.6
        pose.mouth = .flat
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

    /// The "!" pops once per ask: springs in, holds a beat, fades.
    private var bang: (scale: Double, opacity: Double) {
        guard mood == .waving, let waveAge else { return (0, 0) }
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

    /// Two sparkles thrown near the hop's apex, the second late.
    private func sparkle(_ i: Int) -> (x: Double, y: Double, opacity: Double, scale: Double)? {
        guard mood == .celebrating else { return nil }
        if still { return i == 0 ? (-5.4, -4.5, 0.7, 1) : nil }
        guard let hopProgress else { return nil }
        let t = (hopProgress - (i == 0 ? 0.32 : 0.5)) / 0.45
        guard t > 0, t < 1 else { return nil }
        let a = sin(t * .pi)
        return i == 0
            ? (x: -5.4, y: -4.5, opacity: a, scale: 0.6 + 0.6 * a)
            : (x: 5.6, y: -6.0, opacity: a, scale: 0.5 + 0.6 * a)
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
            // The shadow stays planted while the body leaves it.
            Ellipse()
                .fill(.black.opacity(0.22 * (1 - pose.air * 0.55)))
                .frame(width: 8 * (1 - pose.air * 0.35), height: 1.5)
                .offset(y: 7)
            ZStack {
                blob
                face
            }
            .scaleEffect(x: pose.squash.width, y: pose.squash.height)
            .rotationEffect(.degrees(pose.lean))
            .offset(pose.offset)
            effects
        }
    }

    /// Not a circle: a soft rounded square, darkened toward the bottom.
    private var blob: some View {
        let shape = RoundedRectangle(cornerRadius: 5.2, style: .continuous)
        return shape
            .fill(tint)
            .overlay(shape.fill(LinearGradient(colors: [.clear, .black.opacity(0.16)],
                                               startPoint: .center, endPoint: .bottom)))
            .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
            .frame(width: 12.5, height: 11)
            .offset(y: 0.5)
    }

    private var face: some View {
        ZStack {
            HStack(spacing: 1.8) {
                eye
                eye
            }
            .offset(y: -1.0)
            mouth
        }
        .offset(y: 0.5)
    }

    /// One eye: a pupil that drifts with `look`, under a lid drawn in the
    /// body's own tint so closing is just the blob growing over it.
    private var eye: some View {
        ZStack {
            if pose.eyesClosed {
                Capsule().fill(cutout).frame(width: 2.3, height: 0.8)
            } else {
                Circle().fill(cutout)
                    .frame(width: pose.pupil, height: pose.pupil)
                    .offset(pose.look)
                if lid > 0.01 {
                    let lidHeight = 0.5 + 4.0 * lid
                    Capsule().fill(tint)
                        .frame(width: 4.6, height: lidHeight)
                        .offset(y: -2.0 + lidHeight / 2)
                }
            }
        }
        .frame(width: 2.6, height: 4.4)
    }

    @ViewBuilder private var mouth: some View {
        switch pose.mouth {
        case .none:
            EmptyView()
        case .flat:
            Capsule().fill(cutout).frame(width: 2.0, height: 0.7).offset(y: 2.4)
        case .open:
            Capsule().fill(cutout).frame(width: 1.7, height: 1.5).offset(y: 2.4)
        case .smile:
            Path { path in
                path.addArc(center: CGPoint(x: 2.5, y: 1.6), radius: 1.6,
                            startAngle: .degrees(25), endAngle: .degrees(155),
                            clockwise: false)
            }
            .stroke(cutout, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            .frame(width: 5, height: 4)
            .offset(y: 1.6)
        }
    }

    /// The loose glyphs: "z"s overhead, the ask's "!", the hop's
    /// sparkles. Drawn outside the squash so they stay honest.
    @ViewBuilder private var effects: some View {
        if let z = zee(0) { zView(z) }
        if let z = zee(1) { zView(z) }
        if bang.opacity > 0.01 {
            Text("!")
                .font(.system(size: 7, weight: .black, design: .rounded))
                .foregroundStyle(.orange)
                .scaleEffect(max(bang.scale, 0.01))
                .offset(y: -8)
                .opacity(bang.opacity)
        }
        if let s = sparkle(0) { sparkleView(s) }
        if let s = sparkle(1) { sparkleView(s) }
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
}
