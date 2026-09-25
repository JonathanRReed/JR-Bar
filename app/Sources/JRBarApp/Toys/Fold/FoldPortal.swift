import CoreGraphics
import Foundation
import JRBarCore

/// The Portal fold's pure model — every rule the renderer and toy
/// follow, with no Metal, no HID and no timers in the way, so the whole
/// thing is testable from `JRBarAppTests` (docs/TOYS.md, docs/TOY-PARITY.md
/// "Duo-style fold"). Four pieces:
///
/// - `SlewTracker` — the lid's display angle. A critically damped
///   tracker with a hard cap on the visible angular rate: the 10 Hz,
///   integer-degree sensor becomes a continuous glide with no
///   overshoot, and a slammed lid eases shut in ~300 ms instead of
///   lurching between samples.
/// - `MoveAnchor` — the movement-anchored reference: where the lid was
///   resting when the gesture began. Still for `settleAfter` while flat
///   and the rest spot becomes the anchor; a live fold freezes it until
///   the picture unwinds home or the dwell pause re-seats it.
/// - `FoldArming` — the capture-lifecycle state machine. The
///   ScreenCaptureKit streams exist only inside the arming band
///   (activation + margin) in fixed-angle mode, or from the first move
///   off the anchor in movement mode; they linger through a short
///   cooldown so the Screen Recording indicator only shows while a fold
///   can actually be on screen, and die at once on a full close. It
///   also owns the fold gate's hysteresis at the activation edge.
/// - `DeltaChase` — the displayed delta's asymmetric follower: instant
///   while the target grows (closing keeps the old direct-assignment
///   response), a slew-limited unwind when the target drops — fast
///   enough to track a real lid opening exactly, so the return trip
///   retraces the close; only a gate snap ever sees the rate limit.
/// - `PortalDepth` — window z-order → depth buckets and normalized card
///   rects for the shader's layered room.
/// - `FoldPortalModel` — the Room look's settings+delta → shader-params
///   mapping: the Perspective/Blur/Shade/Frost knobs, the activation-
///   edge opacity ramp and the dissolve to black over the last ~20° of
///   travel.
/// - `FoldDuoModel` — the Duo look: one picture held still in space
///   while the glass swings through it, softening and darkening away
///   from the hinge until a seated eye loses the glass.
/// - `EdgeInterpolator` — draws the 10 Hz sensor one period in the
///   past, gliding between its edges, so a steady close moves at a
///   steady speed instead of pulsing ten times a second.
/// - `FirstFrameCatchUp` and `FoldBlackout` — the Duo's ends: no pop
///   when the first captured frame lands late, and black held across
///   the closed-lid pause so a reopen unfolds from black.

// MARK: - SlewTracker

/// A slew-limited critically damped tracker for the lid angle.
///
/// The hinge sensor reports integer degrees at ~10 Hz; a real close
/// arrives as a staircase of 9–13° steps. Feeding those steps straight
/// to a spring lurches; extrapolating past them overshoots. This tracker
/// instead chases the newest sample with a critically damped second-
/// order step whose velocity is hard-capped: between samples the render
/// angle moves in sub-degree increments at a bounded rate, and a slammed
/// lid settles in ~250–350 ms — the cap, not the sensor's cadence, sets
/// the visible pace. It can never overshoot: the crossing guard snaps
/// the position onto the target the moment a step would pass it, which
/// is also what lets a parked lid hold dead still.
struct SlewTracker: Sendable {
    /// What the renderer should draw, in degrees. Continuous and
    /// monotone toward the target — never ahead of it.
    private(set) var angle = 0.0
    /// The visible angular rate in deg/s. Diagnostic only — nothing
    /// downstream differentiates it (the old velocity-driven motion
    /// smear is gone by design).
    private(set) var velocity = 0.0
    /// True once a real measurement has primed the tracker.
    private(set) var primed = false
    private var target = 0.0

    /// Critical-damping stiffness. 20 tracks a slow staircase with
    /// under a half-degree of lag; the slew cap, not this, owns the
    /// slam pace.
    var omega = 20.0
    /// The visible-rate ceiling in deg/s. A full slam crosses the fold's
    /// ~40° working range in ~300 ms at this cap.
    var maxRate = 150.0
    /// A single tick larger than this is a stall (a slept display, a
    /// wedged runloop), not a frame — clamped so a huge dt can't fire
    /// the tracker past its target in one step.
    var maxDt = 0.05

    init() {}

    mutating func reset() { self = SlewTracker() }

    /// The newest measured lid position. Repeat values are cheap no-ops
    /// — the tracker's own state carries the continuity between them.
    mutating func feed(_ raw: Double) {
        guard raw.isFinite else { return }
        if !primed {
            primed = true
            angle = raw
            velocity = 0
        }
        target = raw
    }

    /// One render-frame step. Semi-implicit Euler stays stable at any
    /// vsync cadence; the velocity is capped each step so the visible
    /// rate never exceeds `maxRate`, and the crossing guard makes
    /// overshoot structurally impossible.
    mutating func tick(dt rawDt: Double) {
        guard primed, rawDt.isFinite, rawDt > 0 else { return }
        let dt = min(rawDt, maxDt)
        var v = velocity
            + (-omega * omega * (angle - target) - 2 * omega * velocity) * dt
        v = max(-maxRate, min(maxRate, v))
        var next = angle + v * dt
        if (next - target) * (angle - target) < 0 {
            // The step would cross the target — land on it instead.
            next = target
            v = 0
        } else if abs(next - target) < 0.02 && abs(v) < 1.0 {
            // Arrival snap: a critically damped approach is asymptotic,
            // so without this epsilon the tracker creeps forever and
            // `atRest` never goes true.
            next = target
            v = 0
        }
        if next == target, abs(v) < 1 { v = 0 }
        angle = next
        velocity = v
    }

    /// Parked means exactly on the last measurement with no rate left —
    /// the toy's vsync link stands down only from here.
    var atRest: Bool { !primed || (angle == target && velocity == 0) }
}

// MARK: - MoveAnchor

/// The movement-anchored reference (FoldAnchor.movement): where the lid
/// was resting when the gesture began.
///
/// While the lid is flat — at or above the anchor, no fold in flight —
/// a rest spot held for `settleAfter` becomes the new anchor, so the
/// fold always starts from wherever the lid was last parked. Below the
/// anchor the fold is live and the reference freezes: parking mid-fold
/// must not re-anchor (that would collapse a held fold after 400 ms);
/// handing the desktop back is the dwell pause's job, and it re-seats
/// the anchor itself. Opening back through the anchor is what counts as
/// flat — the stillness clock resumes from there.
struct MoveAnchor: Sendable {
    /// The reference angle a fold measures from. nil until the first
    /// real sample seats it.
    private(set) var anchor: Double?
    /// Where the lid last rested in the flat zone.
    private var restAngle: Double?
    /// When the current rest spot was entered.
    private var restAt: TimeInterval = 0

    /// Seconds of stillness in the flat zone before the rest spot
    /// re-seats the anchor — long enough that the sensor's own 100 ms
    /// cadence can't do it mid-gesture.
    var settleAfter: TimeInterval = 0.4
    /// The stillness deadband in degrees — the sensor's jitter window.
    var tolerance = 1.5
    /// How far off the anchor counts as a real move — what arms the
    /// capture. nil uses `tolerance`, either way off the anchor. The toy
    /// sets 3° in both looks and counts only a move down: a nudge never
    /// flashes the Screen Recording indicator, and neither does tilting
    /// the screen back, which has nothing to fold.
    var armThreshold: Double?
    /// How far below the anchor counts as folded: past this the
    /// reference freezes until the lid returns.
    var flightMargin = 3.0

    init() {}

    mutating func reset() { self = MoveAnchor() }

    /// Feed a raw lid sample at host time `at`. Folded or not, the
    /// anchor never moves mid-flight.
    mutating func feed(_ angle: Double, at: TimeInterval) {
        guard angle.isFinite, at.isFinite else { return }
        guard let a = anchor else {
            anchor = angle
            restAngle = angle
            restAt = at
            return
        }
        if a - angle > flightMargin {
            // In flight: the rest clock restarts so a return to flat
            // still owes its own settle before re-anchoring.
            restAngle = angle
            restAt = at
            return
        }
        if let r = restAngle, abs(angle - r) <= tolerance {
            if at - restAt >= settleAfter { anchor = angle }
        } else {
            restAngle = angle
            restAt = at
        }
    }

    /// A real deviation from the anchor — what arms the capture in
    /// movement mode. A held fold counts as moving (the streams must
    /// stay); parked at rest does not. With `armThreshold` set only a
    /// move down counts; a reopen back through the anchor keeps its
    /// streams through the arming cooldown.
    func moving(_ angle: Double) -> Bool {
        guard angle.isFinite, let a = anchor else { return false }
        if let threshold = armThreshold { return a - angle > threshold }
        return abs(angle - a) > tolerance
    }

    /// Seat the anchor directly — the dwell pause hands the desktop
    /// back and the parked angle becomes the new reference.
    mutating func reseat(_ angle: Double, at: TimeInterval) {
        guard angle.isFinite, at.isFinite else { return }
        anchor = angle
        restAngle = angle
        restAt = at
    }
}

// MARK: - FoldArming

/// The capture-lifecycle state machine: when the ScreenCaptureKit
/// streams may exist, and whether the fold gate is open.
///
/// Streams start only once the lid enters the arming band — the
/// activation angle plus `margin` — so the purple Screen Recording
/// indicator shows only while a fold can actually be on screen. Leaving
/// the band starts a `cooldown` countdown instead of cutting the stream
/// at once (a lid hovering near the band edge must not flap the
/// indicator); a real close below `closedAngle` or the daemon's
/// clamshell truth stops it immediately. The fold gate itself gets
/// `hysteresis`: it opens at `activation` and won't close again until
/// the lid is a degree past it, so a sensor wobble on the line can
/// never flick the overlay.
struct FoldArming: Sendable {
    enum Phase: Equatable, Sendable {
        /// No streams, nothing captured.
        case idle
        /// Inside the band — both streams live.
        case armed
        /// Left the band upward; streams linger until the timestamp so a
        /// re-entry never pays a capture restart.
        case cooling(until: TimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// The activation-edge gate with hysteresis applied.
    private(set) var foldGateOpen = false

    /// Band half-height above the activation angle — matches the
    /// sensor's own polling-band margin.
    var margin = 12.0
    /// Seconds the streams linger after the lid leaves the band.
    var cooldown = 2.0
    /// Degrees past activation the lid must reach before the gate shuts.
    var hysteresis = 1.0
    /// At or under this the lid counts as closed — streams die at once.
    var closedAngle = FoldPause.closedAngle

    struct Outcome: Equatable, Sendable {
        /// Both capture streams should exist.
        var capture = false
        /// The fold gate (activation edge, with hysteresis) is open.
        var foldGate = false
        /// When a cooling phase expires, so the owner can schedule the
        /// shutdown check rather than polling it.
        var cooldownEndsAt: TimeInterval? = nil
    }

    init() {}

    mutating func reset() { self = FoldArming() }

    /// Evaluate the machine. `angle` is the freshest raw reading (or the
    /// simulation while held); `closed` is the daemon's clamshell truth;
    /// `now` is host seconds.
    @discardableResult
    mutating func update(angle: Double?, activation: Double, closed: Bool,
                         now: TimeInterval) -> Outcome {
        let lidShut = closed || (angle.map { $0 <= closedAngle } ?? false)
        guard let a = angle, a.isFinite, !lidShut else {
            // A full close — or a sensor with nothing to say — stops the
            // streams immediately; the indicator never outlives the lid.
            phase = .idle
            foldGateOpen = false
            return Outcome()
        }
        if a <= activation + margin {
            phase = .armed
        } else {
            switch phase {
            case .armed:
                phase = .cooling(until: now + cooldown)
            case .cooling(let until) where now >= until:
                phase = .idle
            default:
                break
            }
        }
        if a <= activation {
            foldGateOpen = true
        } else if a > activation + hysteresis {
            foldGateOpen = false
        }
        var cooldownEndsAt: TimeInterval?
        if case .cooling(let until) = phase { cooldownEndsAt = until }
        return Outcome(capture: phase != .idle, foldGate: foldGateOpen,
                       cooldownEndsAt: cooldownEndsAt)
    }

    /// The movement-anchored evaluation: there is no fixed activation
    /// angle, so the streams arm on the first real move off the
    /// `MoveAnchor` instead of on crossing the band. `moving` is the
    /// toy's deviation-from-anchor read — a held fold stays "moving"
    /// (the capture must live while the fold does), a parked lid goes
    /// still and cools down, and the same `cooldown`/`closedAngle`
    /// rules apply. The gate is open whenever capture is: the delta's
    /// own positive-only math holds it at zero above the anchor.
    @discardableResult
    mutating func updateMovement(moving: Bool, closed: Bool,
                                 now: TimeInterval) -> Outcome {
        guard !closed else {
            phase = .idle
            foldGateOpen = false
            return Outcome()
        }
        if moving {
            phase = .armed
            foldGateOpen = true
        } else {
            switch phase {
            case .armed:
                phase = .cooling(until: now + cooldown)
            case .cooling(let until) where now >= until:
                phase = .idle
                foldGateOpen = false
            case .idle:
                foldGateOpen = false
            default:
                break
            }
        }
        var cooldownEndsAt: TimeInterval?
        if case .cooling(let until) = phase { cooldownEndsAt = until }
        return Outcome(capture: phase != .idle, foldGate: foldGateOpen,
                       cooldownEndsAt: cooldownEndsAt)
    }
}

// MARK: - DeltaChase

/// The displayed delta's asymmetric follower.
///
/// `targetDelta` is not always honest motion: when the lid swings back
/// past activation + hysteresis the fold gate shuts and the target
/// snaps to 0 while the room is visibly mid-fold. Assigning it straight
/// to `displayedDelta` — what the toy used to do — cut the overlay to
/// black mid-swing ("going up just snaps"). So the chase splits the
/// directions:
///
/// - A growing target is followed in the same tick. Closing keeps the
///   old direct-assignment response bit for bit — no added lag on the
///   gesture that matters.
/// - A dropping target unwinds at a bounded rate — `unwindRate` rad/s,
///   never a spring. The rate sits just above the tracker's own
///   `maxRate` (150°/s ≈ 2.62 rad/s), so a real lid opening drops the
///   target no faster than the chase can follow: the unwind lands on
///   the target every tick and the return trip retraces the close
///   pixel for pixel. Only a gate snap — the target leaping to 0 faster
///   than any hinge can move — ever sees the rate limit, and there the
///   slew IS the easing: a monotone counter-rotation through the hinge,
///   ~300 ms for a full working-range unwind, pinned at the target so
///   it can never swing below 0.
struct DeltaChase: Sendable {
    /// What the renderer should draw, in radians. Monotone downward
    /// during an unwind — never below the target.
    private(set) var value = 0.0
    /// The unwind rate in rad/s. Diagnostic only.
    private(set) var velocity = 0.0
    /// The newest target the chase has seen.
    private(set) var target = 0.0

    /// The unwind's speed in rad/s. Just above the fastest real lid
    /// opening (the tracker's 150°/s cap is ~2.62 rad/s), so ordinary
    /// opening motion is followed exactly — the same angle always draws
    /// the same image — while a gate snap still eases back in ~300 ms
    /// instead of cutting to black.
    var unwindRate = 3.0
    /// A single tick larger than this is a stall (a slept display), not
    /// a frame — clamped so a huge dt can't fire the chase past its
    /// target in one step.
    var maxDt = 0.05

    init() {}

    /// Parked on a value with no rate left — resets plant the chase so
    /// a stale unwind can't resurrect after a pause or a provider swap.
    mutating func reset(to newValue: Double = 0) {
        self = DeltaChase()
        value = newValue
        target = newValue
    }

    /// One render-frame step toward `newTarget`. A dropping target is
    /// chased linearly at `unwindRate`; the step never crosses the
    /// target, so a real opening (slower than the rate) is tracked
    /// exactly and only a snap is eased.
    @discardableResult
    mutating func tick(target newTarget: Double, dt rawDt: Double) -> Double {
        guard newTarget.isFinite else { return value }
        target = max(0, newTarget)
        if target >= value {
            // Closing (or aligned): the old direct assignment, unchanged.
            value = target
            velocity = 0
            return value
        }
        guard rawDt.isFinite, rawDt > 0 else { return value }
        let dt = min(rawDt, maxDt)
        let next = max(target, value - unwindRate * dt)
        velocity = (next - value) / dt
        value = next
        return value
    }

    /// Rest means exactly on the last target with no rate left — the
    /// toy's vsync link stands down only from here.
    var atRest: Bool { value == target && velocity == 0 }
}

// MARK: - PortalDepth

/// Window z-order → depth buckets and card rects.
///
/// The Portal room is a stack of planes parallel to the screen hanging
/// off the hinge: the wallpaper is the far wall and each captured
/// window is a card floating in front of it at its own depth. Cards are
/// punched into one alpha texture per depth bucket, so the whole room
/// composites in a single fullscreen pass and the per-frame cost is a
/// handful of blit copies — capped at `maxWindows` cards so the render
/// stays under its frame budget no matter how busy the desktop is.
enum PortalDepth {
    /// Alpha-punched textures, nearest first — each is a texture, a
    /// blit pass and a shader sample, so the count stays small.
    static let bucketCount = 3
    /// Bucket depths as a fraction of the room depth, nearest first.
    static let bucketFractions: [Double] = [0.18, 0.5, 0.85]
    /// How many on-screen windows become cards. Windows past this sit on
    /// the far wall — the room stays readable and the render stays cheap.
    static let maxWindows = 12
    /// Windows smaller than this aren't worth a card of their own.
    static let minWindowSize = 24.0

    /// A window card: the window's rect in display-normalized uv (origin
    /// top-left, y down — the captured texture's own space) and its
    /// depth bucket index.
    struct Card: Equatable, Sendable {
        var rect: CGRect
        var bucket: Int
    }

    /// The raw window-list facts, abstracted so the filter is testable
    /// without a window server. `rect` is Quartz points, global
    /// top-left origin — `CGWindowListCopyWindowInfo`'s own space.
    struct WindowInfo: Equatable, Sendable {
        var rect: CGRect
        var layer: Int
        var ownerPID: Int32
        var alpha: Double
    }

    /// The on-screen window list (front-to-back, the order
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` returns) →
    /// display-local normalized rects. Normal windows only — layer 0 —
    /// so the menu bar, status items, Dock tiles and desktop elements
    /// stay on the far wall: chrome recedes, content floats. Our own
    /// windows are excluded so the fold can never see itself.
    static func cardRects(from windows: [WindowInfo], displayFrame: CGRect,
                          ownPID: Int32) -> [CGRect] {
        var rects: [CGRect] = []
        for w in windows where rects.count < maxWindows {
            guard w.layer == 0, w.ownerPID != ownPID, w.alpha > 0.01 else { continue }
            let clipped = w.rect.intersection(displayFrame)
            guard !clipped.isNull, !clipped.isEmpty,
                  clipped.width >= minWindowSize, clipped.height >= minWindowSize
            else { continue }
            rects.append(CGRect(
                x: (clipped.minX - displayFrame.minX) / displayFrame.width,
                y: (clipped.minY - displayFrame.minY) / displayFrame.height,
                width: clipped.width / displayFrame.width,
                height: clipped.height / displayFrame.height))
        }
        return rects
    }

    /// z-order → bucket. The frontmost windows sit nearest the glass;
    /// the back of the list merges toward the far wall.
    static func cards(for rects: [CGRect]) -> [Card] {
        let n = min(rects.count, maxWindows)
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            Card(rect: rects[i], bucket: min(bucketCount - 1, i * bucketCount / n))
        }
    }

    /// Bucket depths in screen heights for the shader's depth table.
    /// The unused lanes read 0 — the shader never samples past
    /// `bucketCount`.
    static func depths(roomDepth: Double) -> SIMD4<Float> {
        var d = SIMD4<Float>(0, 0, 0, 0)
        for i in 0..<bucketCount { d[i] = Float(bucketFractions[i] * roomDepth) }
        return d
    }
}

// MARK: - FoldPortalModel

/// The delta + settings → shader-params mapping, kept pure so the
/// Portal model's numbers are testable without a GPU.
enum FoldPortalModel {
    /// The stable arc, matching `FoldMath.deltaRadians`'s clamp — the
    /// dissolve is measured against it.
    static let maxDelta = 1.25
    /// Radians of delta over which the overlay fades in at the
    /// activation edge — the portal never pops.
    static let fadeSpan = 0.05
    /// The fraction of `maxDelta` where the dissolve to black begins —
    /// ~0.7 of 71.6° leaves the last ~20° for the fade-out.
    static let dissolveStart = 0.7
    /// The far wall's depth in screen heights.
    static let roomDepth = 0.45

    /// opacity is the activation-edge ramp; dissolve is the fade to
    /// black near full close. Both are pure functions of delta so the
    /// gesture reverses exactly.
    static func opacity(delta: Double) -> Double {
        min(1, max(0, delta / fadeSpan))
    }

    static func dissolve(delta: Double) -> Double {
        let t = min(1, max(0, (delta / maxDelta - dissolveStart) / (1 - dissolveStart)))
        return t * t * (3 - 2 * t)
    }

    /// The animatable uniform fields, written in place. The toy runs
    /// this every vsync tick; writing only the animatable fields keeps
    /// the renderer-owned ones — `imageSize` and `texAspect` from the
    /// capture upload, `cover` and `aspect` from the encode — alive
    /// across ticks. (A wholesale `params = params(...)` reset them to
    /// the defaults every frame, which quietly broke the edge feather
    /// and the cover fit.)
    static func apply(to p: inout FoldRenderer.Params, delta: Double,
                      perspective: Double, blur: Double, shade: Double,
                      frost: Double, hold: Double = 1,
                      usedBuckets: Int, reduceMotion: Bool) {
        p.delta = Float(delta)
        p.persp = Float(min(1, max(0, perspective)))
        // The Hold slider, as it reads: 1 keeps the desktop where a
        // fixed eye saw it while the glass tilts over it, 0 glues the
        // picture to the lid. (It used to be `perspective` when on and
        // 0 when off, which the shader read backwards.)
        p.hold = Float(min(1, max(0, hold.isFinite ? hold : 1)))
        p.blurStrength = Float(min(1, max(0, blur)))
        p.dimStrength = Float(min(1, max(0, shade)))
        p.frost = Float(min(1, max(0, frost)))
        p.opacity = Float(opacity(delta: delta))
        p.dissolve = Float(dissolve(delta: delta))
        p.roomDepth = Float(roomDepth)
        p.depths = PortalDepth.depths(roomDepth: roomDepth)
        p.bucketCount = Float(min(usedBuckets, PortalDepth.bucketCount))
        p.mode = reduceMotion ? 1 : 0
    }

    /// The full parameter set for one frame. `usedBuckets` is how many
    /// depth buckets actually hold cards this frame — the shader skips
    /// the rest, so an empty desktop costs the far wall only.
    static func params(delta: Double, perspective: Double, blur: Double,
                       shade: Double, frost: Double, hold: Double = 1,
                       usedBuckets: Int, reduceMotion: Bool) -> FoldRenderer.Params {
        var p = FoldRenderer.Params()
        apply(to: &p, delta: delta, perspective: perspective, blur: blur,
              shade: shade, frost: frost, hold: hold,
              usedBuckets: usedBuckets, reduceMotion: reduceMotion)
        return p
    }
}

// MARK: - FoldDuoModel

/// The Duo look: the iPhone Duo's fold on a Mac lid (docs/TOYS.md §Fold).
///
/// The Duo keeps its picture fixed in space while the glass swings
/// through it. Here that picture is the desktop as a seated eye saw it
/// on the resting lid: every pixel of the moving glass shows the point
/// of the resting plane that lies behind it on a ray from the eye. Seen
/// from the seat the desktop neither moves nor shrinks; only the glass
/// silhouette drops. On the glass itself this is a stretch that grows
/// toward the top.
///
/// Away from the hinge the picture softens and darkens, measured in the
/// picture's own rows (e = 0 at the hinge row, 1 at the far edge): blur
/// σ grows as e^1.35, the hinge-side fifth never darkens, and the far
/// edge is black by half-closed. Both ride an eased `motion` with zero
/// slope at the start, so the first degrees look like nothing at all.
/// The whole glass fades to black as a seated eye loses it edge-on, so
/// the fold is black well before the closed-lid pause.
///
/// Units: one screen height H. The frame is the keyboard's side view —
/// forward toward the person, up from the deck — with the hinge at the
/// origin. The lid at angle θ runs along u(θ) = (cos θ, sin θ) and its
/// screen faces n(θ) = (sin θ, −cos θ). Angles in the API are degrees.
enum FoldDuoModel {
    /// The seated eye at the default Perspective: 2.6 H toward the
    /// person and 2.0 H up (about 51 cm and 39 cm on a 14-inch panel).
    static let baseEye = SIMD2<Double>(2.6, 2.0)
    /// σ at the far edge at full motion and Blur 1, in screen heights.
    /// 0.10 H is about the Duo's own softness; the default 0.6 sits a
    /// notch under it.
    static let blurScale = 0.10
    /// The darkening gain at Shade 1. The default 0.67 gives the Duo's
    /// "twice the transition": the far edge is black once motion ≥ 0.5.
    static let darkScale = 3.0
    /// The hinge-side share of the picture that never darkens.
    static let darkStart = 0.2
    /// The Duo's falloff exponent for blur and darkening alike.
    static let gamma = 1.35
    /// The end fade runs from black at edge-on + 2° to clear at + 22°.
    static let endFadeFrom = 2.0
    static let endFadeSpan = 20.0
    /// Degrees of travel over which the overlay fades in at the start.
    static let alphaSpan = 2.0
    /// Seconds the overlay takes to fade in the first time it orders in
    /// for a gesture — a late first frame never pops.
    static let orderInDuration: TimeInterval = 0.12
    /// Gaussian pyramid levels the renderer builds.
    static let pyramidLevels = 8
    /// Pyramid level L, read as a cubic B-spline, carries σ ≈ 0.82·2^L
    /// base pixels: the levels' own 5-tap binomials add (4^L − 1)/3 px²
    /// and the B-spline another 4^L/3.
    static let levelSigma = 0.82

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// The eye for a Perspective (0…1): the default 0.6 is the seated
    /// eye; lower sits further back (flatter), higher leans in.
    static func eye(perspective: Double) -> SIMD2<Double> {
        let p = perspective.isFinite ? min(1, max(0, perspective)) : 0.6
        return baseEye * (1.6 - p)
    }

    /// The lid angle, in degrees, at which the eye sees the glass
    /// edge-on — below it the eye is behind the screen. 37.6° for the
    /// default eye.
    static func edgeOn(eye: SIMD2<Double>) -> Double {
        atan2(eye.y, eye.x) * 180 / .pi
    }

    /// The angle the glass is drawn as if it stood at: the real lid at a
    /// full hold, the resting lid (the identity) at 0.
    static func heldAngle(theta: Double, reference: Double, hold: Double) -> Double {
        let k = hold.isFinite ? min(1, max(0, hold)) : 1
        return reference - k * (reference - theta)
    }

    /// Where a panel pixel samples the picture. `x` is lateral from the
    /// screen's centre and `h` the height up the glass, both in screen
    /// heights; `u`/`v` are picture uv (v = 0 at the top, like the
    /// capture). Invalid when the eye is behind the glass or the resting
    /// plane — that pixel is black.
    struct Source: Equatable {
        var u: Double
        var v: Double
        var valid: Bool
    }

    static func source(x: Double, h: Double, theta: Double, reference: Double,
                       hold: Double, eye: SIMD2<Double>, aspect: Double) -> Source {
        let thE = radians(heldAngle(theta: theta, reference: reference, hold: hold))
        let th0 = radians(reference)
        let u0 = SIMD2<Double>(cos(th0), sin(th0))
        let n0 = SIMD2<Double>(sin(th0), -cos(th0))
        let nE = SIMD2<Double>(sin(thE), -cos(thE))
        let w = h * SIMD2<Double>(cos(thE), sin(thE))
        let en0 = (eye * n0).sum()
        let den = ((w - eye) * n0).sum()
        let valid = en0 > 0 && (eye * nE).sum() > 0 && den < -1e-4
        let t = valid ? -en0 / den : 1
        let hit = eye + t * (w - eye)
        return Source(u: t * x / aspect + 0.5, v: 1 - (hit * u0).sum(), valid: valid)
    }

    /// The eased transition, 0…1: smoothstep over `fadeLength` of the
    /// travel from the reference down to the closed line — zero slope at
    /// the start, done by half-closed at the default 0.55.
    static func motion(delta: Double, reference: Double, fadeLength: Double) -> Double {
        guard delta.isFinite, delta > 0 else { return 0 }
        let span = FoldSettings.clampFadeLength(fadeLength) * max(1, reference - FoldPause.closedAngle)
        return smoothstep(0, 1, delta / span)
    }

    /// Blur σ, in screen heights, at picture row `e`.
    static func sigma(e: Double, motion: Double, blur: Double) -> Double {
        let b = blur.isFinite ? min(1, max(0, blur)) : 0
        return blurScale * b * motion * pow(min(1, max(0, e)), gamma)
    }

    /// The darkening, 0…1, at picture row `e`.
    static func darkening(e: Double, motion: Double, shade: Double) -> Double {
        let g = min(1, max(0, (e - darkStart) / (1 - darkStart)))
        let gain = darkScale * (shade.isFinite ? min(1, max(0, shade)) : 0)
        return min(1, gain * motion * pow(g, gamma))
    }

    /// The fade to black as the seated eye loses the glass: 1 (black)
    /// at or under edge-on + 2°, 0 from edge-on + 22° up.
    static func endFade(theta: Double, eye: SIMD2<Double>) -> Double {
        let black = blackAngle(eye: eye)
        return 1 - smoothstep(black, black + endFadeSpan, theta)
    }

    /// The highest lid angle the end fade still draws all black:
    /// edge-on + 2°, 39.6° for the default eye.
    static func blackAngle(eye: SIMD2<Double>) -> Double {
        edgeOn(eye: eye) + endFadeFrom
    }

    /// Where a reopen from the black hold starts its unfold, as a delta
    /// in radians: the glass drawn at the last angle that is still all
    /// black. The first frame after the hold matches it, and the unwind
    /// down to the live lid brings the picture up out of black instead
    /// of cutting straight to a half-lit desktop. 0 for a reference at
    /// or under that angle.
    static func reopenDelta(reference: Double, perspective: Double) -> Double {
        guard reference.isFinite else { return 0 }
        return radians(max(0, reference - blackAngle(eye: eye(perspective: perspective))))
    }

    /// The reference a Duo frame draws from: taken when the overlay
    /// orders in and kept until it orders out, so one gesture draws from
    /// one lid even when the anchor moves under it — the dwell pause
    /// re-seats it at the parked angle while the fold is still unwinding.
    static func drawnReference(held: Double?, current: Double?, overlayVisible: Bool) -> Double? {
        if !overlayVisible || held == nil, let current { return current }
        return held
    }

    /// The overlay's own alpha over the first degrees of travel.
    static func alpha(delta: Double) -> Double {
        guard delta.isFinite else { return 0 }
        return min(1, max(0, delta / alphaSpan))
    }

    /// The order-in fade, 0…1, `elapsed` seconds after the overlay first
    /// ordered in for this gesture.
    static func orderInRamp(elapsed: TimeInterval) -> Double {
        smoothstep(0, orderInDuration, elapsed)
    }

    /// The pyramid level that carries `sigmaPixels` of blur.
    static func lod(sigmaPixels: Double, levels: Int = pyramidLevels) -> Double {
        let raw = log2(max(sigmaPixels, 1e-4) / levelSigma)
        return min(Double(max(1, levels) - 1), max(0, raw))
    }

    /// The Duo's uniforms, written in place every vsync tick; like the
    /// Room's `apply`, only the animatable fields — the upload's size and
    /// level count and the encode's aspect survive. Reduce Motion keeps
    /// the picture on the glass with no blur: it darkens only.
    static func apply(to p: inout FoldRenderer.Params, reference: Double, theta: Double,
                      hold: Double, perspective: Double, blur: Double, shade: Double,
                      fadeLength: Double, reduceMotion: Bool) {
        let delta = max(0, reference - theta)
        let e = eye(perspective: perspective)
        let m = motion(delta: delta, reference: reference, fadeLength: fadeLength)
        p.delta = Float(radians(delta))
        p.thetaRef = Float(radians(reference))
        p.theta = Float(radians(theta))
        p.eyeF = Float(e.x)
        p.eyeU = Float(e.y)
        p.hold = reduceMotion ? 0 : Float(hold.isFinite ? min(1, max(0, hold)) : 1)
        p.motion = Float(m)
        p.blurMax = reduceMotion ? 0 : Float(blurScale * (blur.isFinite ? min(1, max(0, blur)) : 0))
        p.darkGain = Float(darkScale * (shade.isFinite ? min(1, max(0, shade)) : 0))
        p.endFade = Float(endFade(theta: theta, eye: e))
        p.opacity = Float(alpha(delta: delta))
        p.blackout = 0
        p.mode = 0
    }

    /// The closed-lid hold: flat black, nothing sampled, fully opaque.
    static func applyBlackout(to p: inout FoldRenderer.Params) {
        p.blackout = 1
        p.opacity = 1
    }
}

// MARK: - EdgeInterpolator

/// The 10 Hz hinge sensor, drawn one period in the past.
///
/// The sensor reports whole degrees about every 100 ms, so a steady
/// close arrives as a staircase. A tracker chasing each step speeds up
/// right after it and slows before the next — a ±25 % pulse ten times a
/// second that reads as judder. This draws the lid `delay` in the past
/// instead, straight between the edges it has already seen, so the
/// visible speed is the lid's real speed, at the same ~150 ms latency
/// the old path had. Past the last edge it holds; a reversal is just
/// another segment. A lid leaving rest back-dates its first segment by
/// one period, so motion starts at once instead of stretching across
/// the whole rest.
struct EdgeInterpolator: Sendable {
    struct Edge: Equatable, Sendable {
        var at: TimeInterval
        var value: Double
    }

    /// The sensor's own cadence.
    var period: TimeInterval = 0.1
    /// How far in the past the lid is drawn.
    var delay: TimeInterval = 0.1
    /// The newest edges, oldest first. Four covers the delay with room
    /// for a poll's timing wobble.
    private(set) var edges: [Edge] = []
    private static let keep = 4

    init() {}

    mutating func reset() { edges = [] }

    /// A reading. Repeats are not edges; the first reading seats the
    /// lid where it is.
    mutating func feed(_ value: Double, at t: TimeInterval) {
        guard value.isFinite, t.isFinite else { return }
        guard let last = edges.last else {
            edges = [Edge(at: t - period, value: value), Edge(at: t, value: value)]
            return
        }
        guard value != last.value else { return }
        guard t > last.at else {
            // Out of order (a clock hiccup): take the value, keep time.
            edges[edges.count - 1].value = value
            return
        }
        if t - last.at > period * 1.5 {
            // Leaving rest: the lid began to move about one period
            // before this edge showed it.
            edges.append(Edge(at: t - period, value: last.value))
        }
        edges.append(Edge(at: t, value: value))
        if edges.count > Self.keep { edges.removeFirst(edges.count - Self.keep) }
    }

    /// The lid to draw at host time `t`, or nil before any reading.
    func value(at t: TimeInterval) -> Double? {
        guard let first = edges.first, let last = edges.last else { return nil }
        let q = t - delay
        if q <= first.at { return first.value }
        if q >= last.at { return last.value }
        for i in 1..<edges.count where q <= edges[i].at {
            let a = edges[i - 1], b = edges[i]
            let span = b.at - a.at
            guard span > 0 else { return b.value }
            return a.value + (b.value - a.value) * (q - a.at) / span
        }
        return last.value
    }

    /// True once the drawn lid has reached the newest edge — nothing
    /// left to glide until the sensor speaks again.
    func settled(at t: TimeInterval) -> Bool {
        guard let last = edges.last else { return true }
        return t - delay >= last.at
    }
}

// MARK: - FirstFrameCatchUp

/// The movement fold's first-frame ease. The capture starts with the
/// gesture and its first frame lands 200–300 ms later, by which time a
/// quick close is already 10–20° in. Jumping straight there pops; this
/// eases the displayed delta from 0 up to the live one over 150 ms
/// instead, and then steps aside for good.
struct FirstFrameCatchUp: Sendable {
    static let duration: TimeInterval = 0.15
    /// Below this much travel (radians) there is nothing to catch up.
    static let threshold = 2.0 * Double.pi / 180
    private(set) var startedAt: TimeInterval?

    init() {}

    var active: Bool { startedAt != nil }

    mutating func reset() { startedAt = nil }

    /// The first frame just landed with `liveDelta` already on the lid.
    mutating func begin(liveDelta: Double, at t: TimeInterval) {
        guard liveDelta.isFinite, liveDelta > Self.threshold, t.isFinite else { return }
        startedAt = t
    }

    /// The share of the live delta to show at `t`; 1 once done, and
    /// the ease retires itself there.
    mutating func scale(at t: TimeInterval) -> Double {
        guard let s = startedAt else { return 1 }
        let u = (t - s) / Self.duration
        if u >= 1 || !u.isFinite {
            startedAt = nil
            return 1
        }
        return FoldDuoModel.smoothstep(0, 1, max(0, u))
    }
}

// MARK: - FoldBlackout

/// The Duo's closed-lid hold. By the time the lid reaches the closed
/// line the Duo picture is already black; ordering the overlay out there
/// would flash the sharp desktop, and a reopen would pop straight to it.
/// So the overlay stays up as a flat black pass with capture stopped,
/// and lets go on the first of: `watchdog` seconds (restarted once when
/// the lid reopens, so the reopen gets its own time to land a frame),
/// the lid back past `releaseAngle` with a fresh frame in hand (the fold
/// then unfolds from black), or anything that means nobody is looking
/// at this desktop — the owner checks sleep, lock and session itself.
/// It never draws above the lock screen and never uses private spaces.
struct FoldBlackout: Sendable {
    static let watchdog: TimeInterval = 3
    /// 10° above the closed line.
    static let releaseAngle = FoldPause.closedAngle + 10

    private(set) var active = false
    /// When the hold lets go on its own.
    private(set) var deadline: TimeInterval = 0
    private var reopened = false

    init() {}

    /// Start holding black at `now`; a no-op while already holding.
    mutating func hold(at now: TimeInterval) {
        guard !active else { return }
        active = true
        reopened = false
        deadline = now + Self.watchdog
    }

    /// A lid reading while holding: the first one above the closed line
    /// restarts the watchdog, once.
    mutating func note(angle: Double?, at now: TimeInterval) {
        guard active, !reopened, let a = angle, a.isFinite,
              a > FoldPause.closedAngle else { return }
        reopened = true
        deadline = now + Self.watchdog
    }

    func expired(at now: TimeInterval) -> Bool { active && now >= deadline }

    /// The lid is open enough and a frame captured after the close is
    /// in hand: the fold can take over from black.
    func releases(angle: Double?, freshFrame: Bool) -> Bool {
        guard active, freshFrame, let a = angle, a.isFinite else { return false }
        return a >= Self.releaseAngle
    }

    mutating func end() { self = FoldBlackout() }

    /// What the watchdog does when it fires: true hands the overlay to
    /// the live fold the way a release does, false orders it out. A lid
    /// open again, drawing, with a frame in hand hands over: under the
    /// release angle the fold draws black too, so the sharp desktop
    /// never shows through a fresh order-in. With no frame there is
    /// nothing to draw.
    static func watchdogHandsOver(angle: Double?, drawing: Bool, freshFrame: Bool) -> Bool {
        guard drawing, freshFrame, let a = angle, a.isFinite else { return false }
        return a > FoldPause.closedAngle
    }
}
