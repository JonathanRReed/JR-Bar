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
/// - `FoldPortalModel` — the settings+delta → shader-params mapping:
///   the Perspective/Blur/Shade/Frost knobs, the activation-edge
///   opacity ramp and the dissolve to black over the last ~20° of
///   travel.

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
    /// stay); parked at rest does not.
    func moving(_ angle: Double) -> Bool {
        guard angle.isFinite, let a = anchor else { return false }
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
                      frost: Double, holdPicture: Bool = false,
                      usedBuckets: Int, reduceMotion: Bool) {
        p.delta = Float(delta)
        p.persp = Float(min(1, max(0, perspective)))
        // Hold-in-place counter-rotates the content plane by delta·k —
        // the Perspective knob IS k, so a fixed eye sees the desktop
        // stay put while the glass tilts over it (off = 0, the picture
        // rides the lid).
        p.hold = holdPicture ? Float(min(1, max(0, perspective))) : 0
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
                       shade: Double, frost: Double, holdPicture: Bool = false,
                       usedBuckets: Int, reduceMotion: Bool) -> FoldRenderer.Params {
        var p = FoldRenderer.Params()
        apply(to: &p, delta: delta, perspective: perspective, blur: blur,
              shade: shade, frost: frost, holdPicture: holdPicture,
              usedBuckets: usedBuckets, reduceMotion: reduceMotion)
        return p
    }
}
