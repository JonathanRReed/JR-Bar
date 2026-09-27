import Foundation

/// Work-time accounting uses live connection intervals, never the age of a
/// deduplicated state frame. A reconnect starts a new interval; missed timer
/// beats cannot pay more than one ordinary tick. The other reward rules are
/// deliberately not part of this clock.
public struct AquariumWorkClock: Sendable {
    private var previous: TimeInterval?

    public init() {}

    public mutating func reset(connected: Bool = false, at now: TimeInterval = 0) {
        previous = connected && now.isFinite ? now : nil
    }

    public mutating func consume(connected: Bool, at now: TimeInterval,
                                 maximum: TimeInterval) -> TimeInterval {
        guard connected, now.isFinite, maximum.isFinite, maximum > 0 else {
            previous = nil
            return 0
        }
        defer { previous = now }
        guard let previous else { return 0 }
        return min(maximum, max(0, now - previous))
    }
}
