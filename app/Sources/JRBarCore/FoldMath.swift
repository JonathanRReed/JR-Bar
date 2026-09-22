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
/// the whole close. A tolerance of 0 (or less) accepts everything; the
/// first reading always passes.
public struct JitterFilter: Sendable {
    public var tolerance: Double
    /// Stillness that re-arms the deadband once motion started: readings
    /// that stay inside the rest window of one spot for a third of a
    /// second are a parked lid. Measured on the readings, not the gaps
    /// between them — the pump publishes every period whether the angle
    /// moved or not, so a gap-timed rest never came, and a lid parked on
    /// a 100↔101 flicker streamed every wobble into the tracker for good.
    public static let restAfter: TimeInterval = 0.3
    /// The widest wobble rest may hold — the sensor's whole-degree
    /// flicker, with room — or the tolerance when that is tighter.
    /// Capped rather than riding `tolerance` alone: a 5° window would
    /// call a steady 10°/s close parked after three readings and bring
    /// the stair-steps back.
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
