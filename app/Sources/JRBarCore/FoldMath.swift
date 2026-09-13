import Foundation

/// Fold's math, kept pure in JRBarCore so the rules are testable with no
/// sensor, no display and no daemon attached (docs/TOYS.md). The app-side
/// pieces (`FoldToy`, `LidAngleSensor`, the overlay) only feed values in
/// and act on what comes back.
public enum FoldMath {
    /// How folded the desktop looks for a lid angle: 0 at or above the
    /// activation angle, ramping linearly to 1 forty degrees below it,
    /// clamped to [0, 1]. A sensor reading makes no sense below ~0 or
    /// above ~135 anyway; the clamp is what matters.
    public static func foldAmount(angle: Double, activation: Double) -> Double {
        let fold = (activation - angle) / 40
        guard fold.isFinite else { return 0 }
        return min(1, max(0, fold))
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
