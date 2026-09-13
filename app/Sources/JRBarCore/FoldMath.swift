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
/// of dragged behind it: an α–β predictor. Sensor → capture → display
/// costs 60–80 ms, so while the lid is moving the render angle leads
/// the measurement by ~60 ms of predicted travel, clamped to ±8° so a
/// wrong guess can never shoot past the glass. While the lid is parked
/// the prediction is off entirely — the render angle IS the measurement,
/// so a resting fold never drifts.
///
/// Feed it each accepted hinge sample; tick it on every render frame so
/// a stale feed decays instead of holding a lead. All times are host
/// seconds (CACurrentMediaTime).
public struct AlphaBeta: Sendable {
    /// What the renderer should draw: the clamped lead while moving,
    /// the raw measurement while parked.
    public private(set) var renderAngle = 0.0
    /// Lid velocity, deg/s — dt-normalized and smoothed. Negative is
    /// closing. Feeds the motion-aware blur.
    public private(set) var velocity = 0.0

    private var predicted = 0.0
    private var leadVelocity = 0.0
    private var previousRaw: Double?
    private var lastSampleAt: TimeInterval?
    private var lastMotionAt: TimeInterval?
    private var lastFeedAt: TimeInterval?
    private var primed = false

    /// How far ahead the lead aims, in seconds of predicted travel.
    public static let leadSeconds: TimeInterval = 0.06
    /// The lead can never run further than this from the measurement.
    public static let leadLimit: Double = 8
    /// A residual this violent is a discontinuity (sensor hop), not a
    /// trend — snap to it instead of chasing it.
    static let residualSnap: Double = 1200
    /// β gain on the velocity correction.
    static let betaGain: Double = 0.08
    /// Below this instantaneous velocity the lid reads as still.
    static let motionFloor: Double = 0.8
    /// Stillness must hold this long before the prediction freezes.
    static let stillConfirm: TimeInterval = 0.2
    /// No fresh sample for this long and the lead decays to zero.
    static let staleAfter: TimeInterval = 0.25

    public init() {}

    public mutating func reset() { self = AlphaBeta() }

    /// Feed an accepted, in-range hinge sample.
    public mutating func feed(_ rawAngle: Double, at: TimeInterval) {
        guard rawAngle.isFinite, at.isFinite else { return }
        guard primed, let previous = previousRaw, let tPrev = lastSampleAt else {
            primed = true
            previousRaw = rawAngle
            lastSampleAt = at
            lastFeedAt = at
            renderAngle = rawAngle
            predicted = rawAngle
            leadVelocity = 0
            velocity = 0
            lastMotionAt = nil
            return
        }
        let dt = max(1e-4, at - tPrev)
        let instant = (rawAngle - previous) / dt
        previousRaw = rawAngle
        lastSampleAt = at
        lastFeedAt = at

        if abs(instant) >= Self.motionFloor {
            lastMotionAt = at
            // A real reversal can't ride the old lead through the turn —
            // it would overshoot exactly where the eye catches it.
            if instant * leadVelocity < 0 { leadVelocity = 0 }
        }
        let still = lastMotionAt.map { at - $0 > Self.stillConfirm } ?? false
        if still {
            leadVelocity = 0
            predicted = rawAngle
            renderAngle = rawAngle
        } else {
            // How wrong the last lead was, in deg/s, dt-normalized so a
            // poll-rate change can't mistune the gain.
            var residual = (rawAngle - predicted) / dt
            residual = min(Self.residualSnap, max(-Self.residualSnap, residual))
            leadVelocity += Self.betaGain * residual
            let candidate = predicted + leadVelocity * Self.leadSeconds
            predicted = min(rawAngle + Self.leadLimit,
                            max(rawAngle - Self.leadLimit, candidate))
            renderAngle = predicted
        }
        velocity += (instant - velocity) * 0.25
    }

    /// Per-render-frame decay: a feed that goes quiet can't leave a lead
    /// or a blur boost standing on a parked lid — and it can't leave the
    /// *angle* standing either. Jitter-rejected samples never reach
    /// `feed`, so a settling lid can starve the feed while `predicted`
    /// still holds a lead; once stillness is confirmed the measurement
    /// is the truth and the render angle rejoins it.
    public mutating func tick(dt: Double, at: TimeInterval) {
        guard dt.isFinite, dt > 0 else { return }
        if let last = lastFeedAt, at - last > Self.staleAfter {
            leadVelocity = 0
            velocity *= exp(-dt / 0.3)
            if abs(velocity) < 0.5 { velocity = 0 }
            // Ease what is left of the lead home rather than freezing
            // it mid-gesture — the stillness snap below lands it.
            if let raw = previousRaw {
                predicted += (raw - predicted) * (1 - exp(-dt / 0.2))
                renderAngle = predicted
            }
        }
        if let motion = lastMotionAt, at - motion > Self.stillConfirm {
            leadVelocity = 0
            if let raw = previousRaw {
                predicted = raw
                renderAngle = raw
            }
        }
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
