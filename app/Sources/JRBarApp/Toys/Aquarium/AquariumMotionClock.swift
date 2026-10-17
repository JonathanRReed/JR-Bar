import Foundation
import JRBarCore

/// The scene's clock is separate from session and game time.
final class AquariumMotionClock {
    private var visual: TimeInterval?

    func time(at now: TimeInterval, still: Bool) -> TimeInterval {
        guard now.isFinite else { return visual ?? 0 }
        if visual == nil || !still { visual = now }
        return visual ?? now
    }

    /// Status poses settle immediately in Still. Completed fish hold their
    /// place until the real session clock retires them.
    static func poseDate(for fish: Fish, at now: Date, still: Bool) -> Date {
        guard still else { return now }
        switch fish.state {
        case .surfacing: return fish.stateSince.addingTimeInterval(1.15)
        case .sinking: return fish.stateSince.addingTimeInterval(8.2)
        case .leaving: return fish.stateSince
        case .swimming, .idling: return now
        }
    }
}
