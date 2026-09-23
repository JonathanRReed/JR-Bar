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
}

/// The hinge sensor wobbles a degree or two while the lid sits still, and
/// every accepted reading redraws a full-screen Metal pass. The filter
/// holds a deadband around the resting angle: readings inside it are
/// noise and never reach the tracker. Once the lid genuinely moves —
/// `tolerance` degrees from the anchor — the filter opens and streams
/// every reading until the lid rests again, because re-anchoring on each
/// accepted sample is what turned a 5° deadband into 5° stair-steps down
/// the whole close. Rest is read off the readings, though, and a slow
/// enough close reads as rest: under about 2° per `restAfter` (≈6.7°/s)
/// the filter re-arms partway down and the rest of that close advances
/// in tolerance-sized steps — a known trade, see `restAfter`. A
/// tolerance of 0 (or less) accepts everything; the first reading always
/// passes.
public struct JitterFilter: Sendable {
    public var tolerance: Double
    /// Stillness that re-arms the deadband once motion started: readings
    /// that stay inside the rest window of one spot for a third of a
    /// second are a parked lid. Measured on the readings, not the gaps
    /// between them — the pump publishes every period whether the angle
    /// moved or not, so a gap-timed rest never came, and a lid parked on
    /// a 100↔101 flicker streamed every wobble into the tracker for good.
    ///
    /// The cost is the slow close. From the default tolerance up the
    /// window holds two whole degrees (R and R−1), so a lid closing
    /// slower than about 2° per restAfter — ≈6.7°/s — sits inside it
    /// long enough to count as parked: the filter re-arms on R−1, and
    /// from there only a reading a full tolerance away gets through, so
    /// the close lands in 2° steps at the default tolerance and 5° steps
    /// at the widest. Faster closes stream every edge. Lengthening this
    /// narrows the range (0.6 s moves the line to ≈3.3°/s) but streams
    /// that much longer after every park and shifts the dwell clock — a
    /// change to make on the hardware, not here.
    public static let restAfter: TimeInterval = 0.3
    /// The widest wobble rest may hold — the sensor's whole-degree
    /// flicker, with room — or the tolerance when that is tighter.
    /// Capped rather than riding `tolerance` alone: a 5° window would
    /// call a steady 10°/s close parked after three readings and bring
    /// the stair-steps back. The cap moves the line rather than removing
    /// it — two whole degrees still fit, so closes under ≈6.7°/s re-arm
    /// anyway (see `restAfter`).
    public static let restWindow: Double = 1.5
    private var anchor: Double?
    private var streaming = false
    /// Where the lid sits while streaming, and since when — the rest
    /// clock, restarted whenever a reading leaves the window.
    private var restAngle: Double = 0
    private var restAt: TimeInterval = 0

    public init(tolerance: Double) {
        self.tolerance = tolerance
    }

    /// True when `angle` should be used. `at` is the sample's host
    /// seconds (CACurrentMediaTime) so the rest detection shares the
    /// tracker's clock.
    public mutating func accept(_ angle: Double, at: TimeInterval) -> Bool {
        guard let anchor, tolerance > 0, at.isFinite else {
            self.anchor = angle
            return true
        }
        if !streaming {
            guard abs(angle - anchor) >= tolerance else { return false }
            // Left the deadband: from here to rest, every edge is real
            // lid travel — no more re-anchoring to step over.
            streaming = true
            restAngle = angle
            restAt = at
            return true
        }
        if abs(angle - restAngle) < min(tolerance, Self.restWindow) {
            if at - restAt >= Self.restAfter {
                // Parked again: re-anchor on the reading it settled at.
                streaming = false
                self.anchor = angle
            }
        } else {
            restAngle = angle
            restAt = at
        }
        return true
    }

    /// Forgets the baseline so the next reading passes.
    public mutating func reset() {
        anchor = nil
        streaming = false
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
    /// screen, a locked one, and a session another user switched in
    /// over. The first that holds names the pause.
    ///
    /// The lock matters because the display stays lit through agent runs
    /// (keep-display-awake is on by default): a locked Mac with the lid
    /// at an angle is a real state, and the fold's capture streams — and
    /// the Screen Recording indicator with them — must never sit behind
    /// a lock screen. Mac Duo stops its capture on lock for the same
    /// reason.
    public static func reason(angle: Double?, closedLid: Bool, builtInPresent: Bool,
                              mirrored: Bool, screenAsleep: Bool,
                              screenLocked: Bool = false,
                              sessionInactive: Bool = false) -> String? {
        if closedLid || (angle.map { $0 <= closedAngle } ?? false) { return "lid closed" }
        if !builtInPresent { return "no built-in display" }
        if mirrored { return "display is mirrored" }
        if screenAsleep { return "screen asleep" }
        if screenLocked { return "screen locked" }
        if sessionInactive { return "another user is signed in" }
        return nil
    }
}

/// The card's "Try it" (Foldy's one-click demo): a scripted close and
/// reopen played through the simulate path — the same tracker, chase
/// and renderer a real lid drives, so the demo is the fold's own
/// motion, not an animation of it. Pure, so the script can be pinned.
public enum FoldTryIt {
    /// Seconds to swing the lid down, hold it there, and bring it back.
    public static let closeDuration: TimeInterval = 1.3
    public static let holdDuration: TimeInterval = 0.6
    public static let openDuration: TimeInterval = 1.3
    public static var totalDuration: TimeInterval { closeDuration + holdDuration + openDuration }
    /// How far past the activation angle the demo folds.
    public static let depth: Double = 38

    /// Where the demo starts: the lid's own angle when there is one and
    /// it sits above the fold, else a comfortable open lid — never so
    /// close to the activation angle that the fold starts on frame one.
    public static func startAngle(current: Double?, activation: Double) -> Double {
        let floor = activation + 8
        guard let current, current.isFinite else { return max(110, floor) }
        return max(current, floor)
    }

    /// The deepest the demo goes: `depth` past activation, never into
    /// the closed-lid pause.
    public static func bottomAngle(activation: Double) -> Double {
        max(FoldPause.closedAngle + 5, activation - depth)
    }

    /// The simulated angle `elapsed` seconds in, or nil once it's over.
    /// Eased in and out on both legs, the way a hand moves a lid.
    public static func angle(at elapsed: TimeInterval, start: Double, activation: Double) -> Double? {
        guard elapsed >= 0, elapsed <= totalDuration else { return nil }
        let bottom = bottomAngle(activation: activation)
        func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }
        if elapsed < closeDuration {
            return start + (bottom - start) * ease(elapsed / closeDuration)
        }
        if elapsed < closeDuration + holdDuration { return bottom }
        let u = (elapsed - closeDuration - holdDuration) / openDuration
        return bottom + (start - bottom) * ease(min(1, u))
    }
}
