import Foundation

/// How many times a utility did a piece of real work in the last minute —
/// a Dock preview shown, a window captured — for the cost line the toys
/// already show (`ToyCostLine`). Ticked where the work happens; read only
/// while a card is open. Deliberately not observable: a tick must
/// invalidate nothing.
@MainActor
final class UtilityEventLog {
    /// The span a count covers.
    static let window: TimeInterval = 60
    private var stamps: [TimeInterval]
    private var next = 0

    /// Room for more than four events a second over the minute — past
    /// anything a utility should ever do.
    init(capacity: Int = 256) {
        stamps = Array(repeating: -.infinity, count: max(1, capacity))
    }

    func tick(at now: TimeInterval = ToyMeter.uptime) {
        stamps[next] = now
        next = (next + 1) % stamps.count
    }

    /// Events in the last minute.
    func count(at now: TimeInterval = ToyMeter.uptime) -> Int {
        let since = now - Self.window
        return stamps.lazy.filter { $0 > since && $0 <= now }.count
    }
}

/// The counters the utility cards read.
@MainActor
enum UtilityCost {
    /// Dock previews that opened.
    static let dockPreviews = UtilityEventLog()
    /// Window stills actually captured (a cached still is not counted).
    static let dockCaptures = UtilityEventLog()

    /// "3 previews", "1 capture", "no captures".
    nonisolated static func count(_ count: Int, _ noun: String) -> String {
        if count == 0 { return "no \(noun)s" }
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    /// What a switched-off utility costs.
    nonisolated static let off = "Off · nothing running"
}
