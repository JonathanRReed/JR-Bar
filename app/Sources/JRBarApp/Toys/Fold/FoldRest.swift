import Foundation

/// The fold at rest: the lid parked, nothing in the machine moving. The
/// hinge sensor still reports ten times a second, and at rest its whole-
/// degree flicker (95, 94, 95…) is all it says. Each of those readings
/// used to run the whole engine — a reconcile, the display link born and
/// killed, a diagnostic line built — for a lid that had not moved.
///
/// The gate lets every reading through until the lid has held within
/// `band` of one spot for `settle` seconds, with the machine idle, and
/// then stops the flicker at the door. `settle` is longer than the
/// jitter filter's re-arm (`JitterFilter.restAfter`, 0.3 s) and the
/// movement anchor's settle (`MoveAnchor.settleAfter`, 0.4 s), so both
/// finish on real readings before the gate closes. A reading outside
/// the band, or inside the arming band, always goes through, and so
/// arming is never a reading later than it was.
struct FoldRestGate: Sendable {
    /// Degrees either side of the resting reading that count as the
    /// same place: the sensor's one-degree flicker.
    static let band: Double = 1
    /// Seconds the readings must hold still, reaching the machine,
    /// before the gate closes.
    static let settle: TimeInterval = 0.5

    /// The reading the lid came to rest on; nil until the first.
    private(set) var center: Double?
    /// When the lid arrived at `center`, on the readings' clock.
    private var since: TimeInterval = 0

    /// Whether `angle`, read at `at`, reaches the machine. `idle` says
    /// the machine has nothing in motion (see `FoldToy`), and
    /// `insideArmingBand` that the reading is where a fold can start.
    mutating func admits(_ angle: Double, at: TimeInterval, idle: Bool, insideArmingBand: Bool) -> Bool {
        guard angle.isFinite, at.isFinite else { return true }
        guard let center, abs(angle - center) <= Self.band, !insideArmingBand else {
            // Somewhere new: the stillness clock starts again from here.
            self.center = angle
            since = at
            return true
        }
        return !(idle && at - since >= Self.settle)
    }

    /// True once readings at `at` stop at the gate (given an idle
    /// machine) — the moment to tell the sensor it may stay quiet.
    func closed(at: TimeInterval) -> Bool {
        center != nil && at - since >= Self.settle
    }

    /// Forgets the resting spot: the next reading starts a fresh one.
    mutating func reset() {
        center = nil
    }
}

/// What the Fold card shows while the lid moves: the angle in whole
/// degrees, the fold's state line and the pause behind the status chip.
/// Every change reaches the card, but no more than ten times a second —
/// the sensor reads 120 times a second near the fold, the display link
/// ticks faster still, and each change a SwiftUI card draws lays the
/// Toys page out again. The reading is looked at no more than ten times
/// a second either, and a change inside the tenth lands when it is up,
/// so the card never stays behind.
struct FoldCardFeed: Sendable {
    struct Reading: Equatable, Sendable {
        var angle: Double?
        var detail: String
        var pause: String?
    }

    /// The shortest gap between two looks at the reading.
    static let interval: TimeInterval = 0.1

    /// What the card shows now.
    private(set) var shown = Reading(angle: nil, detail: "", pause: nil)
    /// When the reading was last looked at, on the caller's clock.
    private var checkedAt: TimeInterval = -.infinity

    /// When a reading offered at `now` may be looked at: now, or at the
    /// end of the last look's tenth of a second.
    func due(at now: TimeInterval) -> TimeInterval {
        max(now, checkedAt + Self.interval)
    }

    /// Looks at `reading`, its angle rounded to whole degrees, and lands
    /// it when it differs from what the card shows. Returns what to
    /// show, or nil when nothing changed. The caller checks `due` first.
    mutating func land(_ reading: Reading, at now: TimeInterval) -> Reading? {
        checkedAt = now
        var whole = reading
        whole.angle = reading.angle.map { $0.rounded() }
        guard whole != shown else { return nil }
        shown = whole
        return whole
    }
}
