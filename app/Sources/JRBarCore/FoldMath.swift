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
/// reopen played through the simulate path — the same spring, gate ease
/// and renderer a real lid drives, so the demo is the fold's own
/// motion, not an animation of it. It folds from the fold's reference:
/// where the lid rests when the fold starts from there, or the set
/// angle. Pure, so the script can be pinned.
public enum FoldTryIt {
    /// Seconds to swing the lid down, hold it there, and bring it back.
    public static let closeDuration: TimeInterval = 1.3
    public static let holdDuration: TimeInterval = 0.6
    public static let openDuration: TimeInterval = 1.3
    public static var totalDuration: TimeInterval { closeDuration + holdDuration + openDuration }
    /// How far below the reference the demo folds: deep enough that the
    /// Duo's picture goes soft and dark from a resting lid.
    public static let depth: Double = 50
    /// How far above a set angle the demo starts, so the fold doesn't
    /// begin on frame one. A resting-angle fold starts right at the
    /// reference: that fold begins with the first move anyway.
    public static let setAngleLead: Double = 8

    /// Where the demo starts: the lid's own angle when there is one and
    /// it sits at or above `reference + lead`, else that floor — or a
    /// comfortable open lid with no reading at all.
    public static func startAngle(current: Double?, reference: Double,
                                  lead: Double = setAngleLead) -> Double {
        let floor = reference + max(0, lead)
        guard let current, current.isFinite else { return max(110, floor) }
        return max(current, floor)
    }

    /// The deepest the demo goes: `depth` below the reference, never
    /// into the closed-lid pause.
    public static func bottomAngle(reference: Double) -> Double {
        max(FoldPause.closedAngle + 5, reference - depth)
    }

    /// The simulated angle `elapsed` seconds in, or nil once it's over.
    /// Eased in and out on both legs, the way a hand moves a lid.
    public static func angle(at elapsed: TimeInterval, start: Double, reference: Double) -> Double? {
        guard elapsed >= 0, elapsed <= totalDuration else { return nil }
        let bottom = bottomAngle(reference: reference)
        func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }
        if elapsed < closeDuration {
            return start + (bottom - start) * ease(elapsed / closeDuration)
        }
        if elapsed < closeDuration + holdDuration { return bottom }
        let u = (elapsed - closeDuration - holdDuration) / openDuration
        return bottom + (start - bottom) * ease(min(1, u))
    }
}
