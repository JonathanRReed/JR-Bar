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

/// The piece that makes the fold feel attached to your finger instead
/// of dragged behind it: dead reckoning off the sensor's own edges.
///
/// The hinge report is a 10 Hz sensor — probed at 240 Hz it only
/// changes value every ~100 ms, stepping 9–13° on a moderate close and
/// sitting perfectly steady at rest. A predictor that reads poll-to-poll
/// deltas sees a sawtooth (a 10° step at the poll that first catches it,
/// then zero velocity until the next edge); this tracker treats only a
/// value CHANGE as information. Each edge updates a blended velocity
/// estimate and resets the anchor; `tick` extrapolates that velocity
/// from the edge for at most `maxExtrapolation`, clamped to ±`leadLimit`.
/// The ~100 ms of sensor latency is covered by the extrapolation, and
/// at each edge the dead-reckoned position is already near the new
/// value, so the toy's one easing stage only absorbs the residual —
/// there is deliberately no smoothing in here, two stages would add lag.
///
/// Feed it every accepted hinge sample (unchanged polls return early);
/// tick it on every render frame. All times are host seconds
/// (CACurrentMediaTime).
public struct LidTracker: Sendable {
    /// What the renderer should draw: the last edge plus its bounded
    /// extrapolation — the measurement itself while parked.
    public private(set) var renderAngle = 0.0
    /// Lid velocity in deg/s, estimated at each edge and blended.
    /// Negative is closing. Feeds the motion-aware blur.
    public private(set) var velocity = 0.0

    private var edgeAngle = 0.0
    private var edgeAt: TimeInterval = 0
    private var lastRaw: Double = 0
    private var primed = false

    /// The measured sensor cadence: the HID report only changes every
    /// ~100 ms, so polls between edges carry no information.
    public static let samplePeriod: TimeInterval = 0.1
    /// How far past an edge the velocity may be trusted — a little more
    /// than one sensor period covers the report's own latency.
    public static let maxExtrapolation: TimeInterval = 0.15
    /// The extrapolation can never run further than this from the edge.
    public static let leadLimit: Double = 8
    /// No new edge for this long and the lid counts as parked — one
    /// extra edge after a pause is just the lid moving again.
    public static let restAfter: TimeInterval = 0.3
    /// How much each edge's velocity estimate moves the blended one.
    public static let velocityBlend: Double = 0.6

    public init() {}

    public mutating func reset() { self = LidTracker() }

    /// Feed an accepted hinge sample. Only a value change is an edge —
    /// an unchanged poll at 120 Hz is the sensor between updates, not
    /// a stopped lid.
    public mutating func feed(_ raw: Double, at: TimeInterval) {
        guard raw.isFinite, at.isFinite else { return }
        guard primed else {
            primed = true
            edgeAngle = raw
            edgeAt = at
            lastRaw = raw
            renderAngle = raw
            velocity = 0
            return
        }
        guard raw != lastRaw else { return }
        let dt = max(0.02, at - edgeAt)
        let vNew = (raw - edgeAngle) / dt
        velocity = velocity == 0 ? vNew : velocity + (vNew - velocity) * Self.velocityBlend
        if vNew * velocity < 0 {
            // A reversal: the blended estimate would ride the old
            // direction through the turn and overshoot exactly where
            // the eye catches it — take the new direction whole.
            velocity = vNew
        }
        edgeAngle = raw
        edgeAt = at
        lastRaw = raw
    }

    /// Per-render-frame dead reckoning: the render angle is the last
    /// edge plus its velocity for up to `maxExtrapolation` — long enough
    /// to cover the sensor's ~100 ms latency, short enough that a wrong
    /// estimate can't run away. Parked (`restAfter` quiet) the velocity
    /// is zero and the render angle IS the last edge.
    public mutating func tick(dt: Double, at: TimeInterval) {
        guard at.isFinite, primed else { return }
        let since = at - edgeAt
        if since > Self.restAfter { velocity = 0 }
        let extrap = velocity * min(since, Self.maxExtrapolation)
        renderAngle = edgeAngle + min(Self.leadLimit, max(-Self.leadLimit, extrap))
    }
}

/// The hinge sensor wobbles a degree or two while the lid sits still, and
/// every accepted reading redraws a full-screen Metal pass. The filter
/// lets a reading through only once it has moved `tolerance` degrees from
/// the last one it accepted, so a resting lid costs nothing. A tolerance
/// of 0 (or less) accepts everything; the first reading always passes.
public struct JitterFilter: Sendable {
    public var tolerance: Double
    private var lastAccepted: Double?

    public init(tolerance: Double) {
        self.tolerance = tolerance
    }

    /// True when `angle` should be used.
    public mutating func accept(_ angle: Double) -> Bool {
        guard let last = lastAccepted, tolerance > 0 else {
            lastAccepted = angle
            return true
        }
        guard abs(angle - last) >= tolerance else { return false }
        lastAccepted = angle
        return true
    }

    /// Forgets the baseline so the next reading passes.
    public mutating func reset() {
        lastAccepted = nil
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
