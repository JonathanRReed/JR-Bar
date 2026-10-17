import Foundation
import JRBarCore

/// A dismissed gesture stays flat until the physical lid reaches neutral.
struct FoldDismissal: Sendable {
    private(set) var suppressed = false
    private var restingAngle: Double?
    private var restingAt: TimeInterval = 0
    private var mode: FoldAnchor?
    private var lastSampleAt: TimeInterval?

    mutating func dismiss() {
        suppressed = true
        restingAngle = nil
        mode = nil
        lastSampleAt = nil
    }

    /// Use the incoming physical sample, never the simulated rendering angle.
    static func safetyClear(angle: Double?, closed: Bool, builtInPresent: Bool,
                            mirrored: Bool, screenAsleep: Bool, screenLocked: Bool,
                            sessionInactive: Bool) -> Bool {
        FoldPause.reason(angle: angle, closedLid: closed, builtInPresent: builtInPresent,
                         mirrored: mirrored, screenAsleep: screenAsleep,
                         screenLocked: screenLocked, sessionInactive: sessionInactive) == nil
    }

    /// The clearing sample stays flat. A later sample may start a new fold.
    mutating func note(angle: Double?, closed: Bool, safetyClear: Bool, mode: FoldAnchor,
                       activation: Double, tolerance: Double, at now: TimeInterval) -> Bool {
        guard suppressed else { return false }
        let interrupted = lastSampleAt.map { now < $0 } == true
            || FoldSensorSilence.isSilent(lastSampleAt: lastSampleAt, now: now)
        if interrupted { restingAngle = nil }
        lastSampleAt = now.isFinite ? now : nil
        if self.mode != mode {
            self.mode = mode
            restingAngle = nil
        }
        guard safetyClear, let angle, angle.isFinite, now.isFinite, !closed,
              angle > FoldPause.closedAngle else {
            restingAngle = nil
            return false
        }
        if mode == .angle {
            guard angle > activation + FoldArming().margin else { return false }
        } else {
            guard let rest = restingAngle, abs(angle - rest) <= tolerance else {
                restingAngle = angle
                restingAt = now
                return false
            }
            guard now - restingAt >= MoveAnchor().settleAfter else { return false }
        }
        suppressed = false
        restingAngle = nil
        return true
    }
}
