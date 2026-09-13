import Foundation

/// Fold's math, kept pure in JRBarCore so the rules are testable with no
/// sensor, no display and no daemon attached (docs/TOYS.md). The app-side
/// pieces (`FoldToy`, `LidAngleSensor`, the overlay) only feed values in
/// and act on what comes back.
public enum FoldMath {
    /// The renderer's delta saturates here: a lid more than ~72° past the
    /// anchor reads the same as one at 72°, and above the anchor a small
    /// negative swing is allowed before the overlay hides.
    public static let deltaRange: ClosedRange<Double> = -0.65...1.25

    /// Radians the lid has swung past the anchor — positive when closed
    /// further than `activation`, zero when aligned. This, not a linear
    /// "fold amount", drives the shader: at zero the projected image is
    /// pixel-identical to the real desktop, so activating is invisible.
    public static func deltaRadians(angle: Double, activation: Double) -> Double {
        let delta = (activation - angle) * .pi / 180
        guard delta.isFinite else { return 0 }
        return min(deltaRange.upperBound, max(deltaRange.lowerBound, delta))
    }

    /// How folded the desktop reads, 0…1: the plane's recession,
    /// `|sin delta|`. Feeds the dim and blur strength so both ease in
    /// with the tilt instead of popping on at activation.
    public static func foldAmount(angle: Double, activation: Double) -> Double {
        abs(sin(deltaRadians(angle: angle, activation: activation)))
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
        hasFrame && abs(delta) > 0.002
    }

    /// The easing the hinge needs: raw 30 Hz sensor readings step, the
    /// fold should glide. Exponential approach with an ~80 ms time
    /// constant — the same feel the reference toy gets from its lerp.
    public static func smoothed(current: Double, target: Double, dt: Double) -> Double {
        guard current.isFinite, target.isFinite, dt.isFinite, dt > 0 else { return target }
        return current + (target - current) * (1 - exp(-dt / 0.08))
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
