import Foundation

/// Fold's math, kept pure in JRBarCore so the rules are testable with no
/// sensor, no display and no daemon attached (docs/TOYS.md). The app-side
/// pieces (`FoldToy`, `LidAngleSensor`, the overlay) only feed values in
/// and act on what comes back.
public enum FoldMath {
    /// The fold is a physical delta, not a normalized gesture: how far
    /// the lid has swung past the reference (activation) angle, in
    /// radians. The held plane counter-rotates by exactly this, so the
    /// desktop appears to stay where it was — a synthetic arc is what
    /// made the v3 shader lose the illusion. Clamped at 1.25 rad (~72°),
    /// the arc the shader's geometry is stable over; the closed-lid
    /// pause (5°) parks the overlay before a deeper delta could matter.
    public static func deltaRadians(angle: Double, reference: Double) -> Double {
        guard angle.isFinite, reference.isFinite, angle < reference else { return 0 }
        return min(1.25, (reference - angle) * .pi / 180)
    }

    /// The activation gate, checked on the raw angle before any jitter
    /// filtering: above the limit the overlay must be off no matter what
    /// a filtered value still says.
    public static func allows(rawAngle: Double, activation: Double) -> Bool {
        rawAngle.isFinite && rawAngle <= activation
    }

    /// True when a delta is worth an overlay: aligned is invisible, so a
    /// hair of tilt still paints nothing. `hasFrame` keeps the hidden
    /// overlay honest while capture spins up.
    public static func showsOverlay(delta: Double, hasFrame: Bool) -> Bool {
        hasFrame && delta > 0.002
    }

    /// The easing the hinge needs: raw sensor readings step, the fold
    /// should glide. Exponential approach with an 80 ms time constant —
    /// the cadence the reference implementation lands on.
    public static func smoothed(current: Double, target: Double, dt: Double) -> Double {
        guard current.isFinite, target.isFinite, dt.isFinite, dt > 0 else { return target }
        return current + (target - current) * (1 - exp(-dt / 0.08))
    }
}

/// The display glide, second order. A first-order ease transmits a
/// slope step straight to the eye — the tracker's dead reckoning
/// changes slope at every sensor edge (~10 Hz), which reads as a fine
/// judder riding the close. A critically damped spring carries its own
/// velocity, so an edge's slope step becomes an acceleration change and
/// the judder disappears without adding lag; ω≈14 rad/s keeps the
/// responsiveness of the old 80 ms ease.
public struct DeltaSpring: Sendable {
    public private(set) var value = 0.0
    public private(set) var velocity = 0.0

    /// ≈14 rad/s ≈ the old 80 ms exponential's half-response.
    public static let omega = 14.0

    public init() {}

    /// Snaps to rest — a parked fold holds exactly this.
    public mutating func reset(to value: Double = 0) {
        self.value = value
        velocity = 0
    }

    /// Semi-implicit Euler — stable at any render cadence. The fold
    /// delta is physical: it can never go below aligned, so the spring
    /// clamps at 0 rather than ringing through it.
    @discardableResult
    public mutating func tick(target: Double, dt: Double) -> Double {
        guard value.isFinite, target.isFinite, velocity.isFinite,
              dt.isFinite, dt > 0 else {
            value = target
            velocity = 0
            return target
        }
        let w = Self.omega
        velocity += (-w * w * (value - target) - 2 * w * velocity) * dt
        value += velocity * dt
        if value < 0 { value = 0; velocity = max(0, velocity) }
        return value
    }

    /// Rest means both halves quiet — a spring still coasting through
    /// the floor would otherwise park mid-settle.
    public var atRest: Bool { value <= 0.002 && abs(velocity) < 0.05 }
}

/// The hinge tracker — deliberately simple, because prediction was the
/// bug.
///
/// The reference implementation's whole motion pipeline is: read the
/// sensor, ease toward it. Measured against it, our dead-reckoning
/// extrapolation was the judder source: on a real close each 10 Hz edge
/// is 9–13°, so the velocity estimate led 8° past the truth and the next
/// edge yanked it back — a multi-degree sawtooth riding every close,
/// worst exactly when the lid moves fast. The ~100 ms of sensor latency
/// it covered costs less than the sawtooth it bought — but snapping the
/// render target to each edge still feeds the display spring a 10 Hz
/// staircase, and every step re-energizes it into a faint judder.
///
/// So the render angle is a piecewise-linear fit through the samples:
/// each edge eases in over the interval it took to arrive, landing on
/// the newest reading just as the next lands. It never leads the truth
/// — every rendered value interpolates between two measured points —
/// and it never lags the old snap by more than the ramp's own run.
/// The spring downstream owns the last of the smoothing.
///
/// Velocity survives only as an input to the motion-blur boost — it is
/// estimated at edges, capped at a physical slam speed, and never feeds
/// the render. All times are host seconds (CACurrentMediaTime).
public struct LidTracker: Sendable {
    /// What the renderer should draw: a bounded ramp toward the newest
    /// accepted hinge reading — it eases from the value the last edge
    /// left to this edge over the interval the edge took to arrive,
    /// then holds. Unlike the old dead reckoning it can never pass the
    /// truth: the ramp only ever interpolates between two measured
    /// points.
    public private(set) var renderAngle = 0.0
    /// Lid velocity in deg/s, estimated at each edge and blended.
    /// Negative is closing. Cosmetic — feeds only the motion-aware blur.
    public private(set) var velocity = 0.0

    private var edgeAt: TimeInterval = 0
    private var lastRaw: Double = 0
    /// The angle the current ramp started from — the value mid-flight
    /// when the edge landed, so direction changes stay continuous.
    private var rampFrom = 0.0
    /// Seconds the current ramp runs — the interval the newest edge
    /// took to arrive, so at steady cadence the render reaches each
    /// sample just as the next lands.
    private var rampSpan = LidTracker.samplePeriod
    private var primed = false

    /// The measured sensor cadence: the HID report only changes every
    /// ~100 ms, so polls between edges carry no information.
    public static let samplePeriod: TimeInterval = 0.1
    /// No new edge for this long and the lid counts as parked — the
    /// blur boost stops reading motion it cannot see.
    public static let restAfter: TimeInterval = 0.3
    /// How much each edge's velocity estimate moves the blended one.
    public static let velocityBlend: Double = 0.6
    /// A lid cannot move faster than a slam; an edge-rate beyond this is
    /// the timestamp's noise, not the hinge's truth.
    public static let maxLidSpeed: Double = 240
    /// A counter-directional edge slower than this is sensor wobble, not
    /// intent: it pulls the estimate gently instead of snapping the
    /// direction.
    public static let reversalFloor: Double = 15

    public init() {}

    public mutating func reset() { self = LidTracker() }

    /// Feed an accepted hinge sample. Only a value change is an edge —
    /// an unchanged poll at 120 Hz is the sensor between updates, not
    /// a stopped lid.
    public mutating func feed(_ raw: Double, at: TimeInterval) {
        guard raw.isFinite, at.isFinite else { return }
        guard primed else {
            primed = true
            edgeAt = at
            lastRaw = raw
            rampFrom = raw
            renderAngle = raw
            velocity = 0
            return
        }
        guard raw != lastRaw else { return }
        let dt = max(0.02, at - edgeAt)
        // The ramp runs for exactly the interval this edge took to
        // arrive: at steady cadence the render lands on each sample just
        // as the next lands — a piecewise-linear fit through the
        // measurements with no added lag and no extrapolation.
        let newSpan = min(0.4, max(0.04, dt))
        // Edge-to-edge: `renderAngle` may be mid-ramp, so measure off
        // the previous accepted reading, not the eased display value.
        let vNew = max(-Self.maxLidSpeed, min(Self.maxLidSpeed, (raw - lastRaw) / dt))
        if vNew * velocity < 0 {
            if abs(vNew) >= Self.reversalFloor {
                // A real reversal: take the new direction whole — a
                // blended estimate rides the old way through the turn.
                velocity = vNew
            } else {
                // Wobble against the travel: a weak pull only.
                velocity += (vNew - velocity) * Self.velocityBlend * 0.4
            }
        } else {
            velocity = velocity == 0 ? vNew : velocity + (vNew - velocity) * Self.velocityBlend
        }
        // Hand off from exactly where the display was when this edge
        // landed — a mid-ramp value, so direction changes stay smooth.
        let eased = rampFrom + (lastRaw - rampFrom) * min(1, max(0, (at - edgeAt) / rampSpan))
        rampFrom = eased
        renderAngle = eased
        rampSpan = newSpan
        edgeAt = at
        lastRaw = raw
    }

    /// Per render frame: the ramp walks the render angle from the last
    /// edge's value to the newest one over the interval that edge took
    /// to arrive, then holds — and the blur boost's decay: `restAfter`
    /// quiet and the velocity reads zero.
    public mutating func tick(dt: Double, at: TimeInterval) {
        guard at.isFinite, primed else { return }
        let span = at - edgeAt
        renderAngle = rampFrom + (lastRaw - rampFrom) * min(1, max(0, span / rampSpan))
        if span > Self.restAfter { velocity = 0 }
    }
}

/// The hinge sensor wobbles a degree or two while the lid sits still, and
/// every accepted reading redraws a full-screen Metal pass. The filter
/// holds a deadband around the resting angle: readings inside it are
/// noise and never reach the tracker. Once the lid genuinely moves —
/// `tolerance` degrees from the anchor — the filter opens and streams
/// every reading until the lid rests again, because re-anchoring on each
/// accepted sample is what turned a 5° deadband into 5° stair-steps down
/// the whole close. A tolerance of 0 (or less) accepts everything; the
/// first reading always passes.
public struct JitterFilter: Sendable {
    public var tolerance: Double
    /// Quiet time that re-arms the deadband once motion started. One
    /// sensor period is ~100 ms; a lid that has not moved for a third of
    /// a second is parked.
    public static let restAfter: TimeInterval = 0.3
    private var anchor: Double?
    private var streaming = false
    private var lastAt: TimeInterval = 0

    public init(tolerance: Double) {
        self.tolerance = tolerance
    }

    /// True when `angle` should be used. `at` is the sample's host
    /// seconds (CACurrentMediaTime) so the rest detection shares the
    /// tracker's clock.
    public mutating func accept(_ angle: Double, at: TimeInterval) -> Bool {
        guard let anchor, tolerance > 0, at.isFinite else {
            self.anchor = angle
            lastAt = at
            return true
        }
        if !streaming {
            guard abs(angle - anchor) >= tolerance else { return false }
            // Left the deadband: from here to rest, every edge is real
            // lid travel — no more re-anchoring to step over.
            streaming = true
            lastAt = at
            return true
        }
        if at - lastAt > Self.restAfter {
            // Parked again: re-anchor on the reading it settled at.
            streaming = false
            self.anchor = angle
        }
        lastAt = at
        return true
    }

    /// Forgets the baseline so the next reading passes.
    public mutating func reset() {
        anchor = nil
        streaming = false
        lastAt = 0
    }
}

/// Why Fold is paused right now, or nil when it may run. The strings are
/// written for the status chip, in Jonathan's voice.
public enum FoldPause {
    /// The lid counts as closed at or under five degrees: the sensor
    /// bottoms out a few degrees above a true zero, and a lid that far
    /// down has nothing to show.
    public static let closedAngle: Double = 5

    /// Checks the safety inputs in contract order: a closed lid (sensor
    /// or daemon), a missing built-in display, a mirrored one, a sleeping
    /// screen. The first that holds names the pause.
    public static func reason(angle: Double?, closedLid: Bool, builtInPresent: Bool,
                              mirrored: Bool, screenAsleep: Bool) -> String? {
        if closedLid || (angle.map { $0 <= closedAngle } ?? false) { return "lid closed" }
        if !builtInPresent { return "no built-in display" }
        if mirrored { return "display is mirrored" }
        if screenAsleep { return "screen asleep" }
        return nil
    }
}
