import AppKit
import CoreGraphics
import Foundation
import JRBarCore

/// The floating buddy's calm walkabout (docs/TOYS.md) — neko's manners,
/// not the goose's. Now and then, while the agents are working and
/// nothing is asking, it hops up onto the top edge of the frontmost
/// window (or the bottom of the screen when no window has room), strolls
/// a little way along it, turns round on the spot, wanders part of the
/// way back, and comes home to the spot you parked it on. It only ever
/// moves its own panel: never the cursor, never a window. A press on it
/// holds it still, and a carry ends the walk. Pure, so the path is
/// pinned.
struct BuddyStroll: Equatable {
    /// One straight piece of the path, centre to centre in screen
    /// coordinates (AppKit's bottom-left origin).
    struct Leg: Equatable {
        var from: CGPoint
        var to: CGPoint
        var duration: TimeInterval
        /// The stroll itself walks at an even pace; getting there and
        /// back is a hop, eased at both ends.
        var hop: Bool
        /// The way it faces on this leg when the travel doesn't say:
        /// the turn on the spot faces the way the next leg walks, so the
        /// turn plays while it stands.
        var facing: Double? = nil
    }

    var legs: [Leg]
    /// The window edge it walks on, as that window's frame when planned
    /// — nil for the screen bottom. The panel re-reads the window list
    /// once a second while it walks and heads home if this edge moved.
    var ledge: CGRect?

    var duration: TimeInterval { legs.reduce(0) { $0 + $1.duration } }

    /// Points a second along the edge, and getting up and down.
    static let strollSpeed: Double = 34
    static let hopSpeed: Double = 150
    /// The longest stroll, end to end.
    static let maxStroll: Double = 260
    /// The shortest stroll worth the trip.
    static let minStroll: Double = 60
    /// Standing at the far end while it turns round: the turn itself
    /// (`BuddyTurn.duration`) and a beat before it sets off back.
    static let turnPause: TimeInterval = 0.6
    /// How much of the way out it walks back before hopping home.
    static let backShare: Double = 0.5

    // MARK: When

    /// The quiet stretch after a walk, and the chance each once-a-minute
    /// beat takes once it has passed, for a walk about every `every`
    /// minutes (the card's "How often it walks"). At the default twelve
    /// that is eight quiet minutes and a one-in-four chance a minute —
    /// the cadence the walkabout has always had.
    static func minGap(every: Double) -> TimeInterval {
        NotchBuddySettings.clampedWalkEvery(every) * 60 * 2 / 3
    }

    static func chance(every: Double) -> Double {
        min(1, 3 / NotchBuddySettings.clampedWalkEvery(every))
    }

    /// Only a working, unbothered buddy strolls: something is running,
    /// nothing asks or failed, it isn't being carried, and Reduce Motion
    /// is off.
    static func shouldStroll(working: Int, waiting: Int, failed: Int, dragging: Bool,
                             reduceMotion: Bool, sinceLast: TimeInterval, roll: Double,
                             every: Double = NotchBuddySettings.defaultWalkEvery) -> Bool {
        working > 0 && waiting == 0 && failed == 0 && !dragging && !reduceMotion
            && sinceLast >= minGap(every: every) && roll < chance(every: every)
    }

    /// Whether a walk under way carries on, asked once a second: the
    /// same calm a walk starts on, the buddy still out and floating,
    /// walks still allowed (turning "Take walks" off mid-walk sends it
    /// home), and its edge still standing. The edge is looked up only
    /// when everything else holds.
    static func carriesOn(working: Int, waiting: Int, failed: Int, showing: Bool, free: Bool,
                          takesWalks: Bool, ledgeStands: @autoclosure () -> Bool) -> Bool {
        guard working > 0, waiting == 0, failed == 0, showing, free, takesWalks else { return false }
        return ledgeStands()
    }

    // MARK: Where

    /// The path from `home` (the parked centre) for a pet `size` big on
    /// the screen area `visible`. `windows` are the on-screen windows'
    /// frames, front to back, in AppKit coordinates. `rightward` picks
    /// the way it sets off when both ways have room.
    static func plan(home: CGPoint, size: CGSize, visible: CGRect, windows: [CGRect],
                     rightward: Bool) -> BuddyStroll? {
        let half = size.width / 2
        for window in windows {
            // Its top edge on this screen, with room above it for the
            // pet to stand and wide enough to walk.
            let top = window.maxY
            guard top + size.height <= visible.maxY, top - size.height >= visible.minY,
                  window.width >= size.width + 120 else { continue }
            let lo = max(window.minX, visible.minX) + half + 6
            let hi = min(window.maxX, visible.maxX) - half - 6
            guard hi - lo >= minStroll else { continue }
            return along(y: top + size.height / 2 - 1, lo: lo, hi: hi, home: home,
                         rightward: rightward, ledge: window)
        }
        let lo = visible.minX + half + 6
        let hi = visible.maxX - half - 6
        guard hi - lo >= minStroll else { return nil }
        return along(y: visible.minY + size.height / 2 + 1, lo: lo, hi: hi, home: home,
                     rightward: rightward, ledge: nil)
    }

    private static func along(y: Double, lo: Double, hi: Double, home: CGPoint,
                              rightward: Bool, ledge: CGRect?) -> BuddyStroll? {
        let start = min(hi, max(lo, home.x))
        var right = rightward
        var room = right ? hi - start : start - lo
        if room < minStroll {
            right.toggle()
            room = right ? hi - start : start - lo
        }
        guard room >= minStroll else { return nil }
        let length = min(maxStroll, room)
        let a = CGPoint(x: start, y: y)
        let b = CGPoint(x: start + (right ? length : -length), y: y)
        // Out to the far point (the edge's end when the edge is short),
        // round on the spot, and part of the way back before hopping home.
        let back = length * backShare
        let c = CGPoint(x: b.x + (right ? -back : back), y: y)
        return BuddyStroll(legs: [
            hop(home, a),
            Leg(from: a, to: b, duration: length / strollSpeed, hop: false),
            Leg(from: b, to: b, duration: turnPause, hop: false, facing: right ? -1 : 1),
            Leg(from: b, to: c, duration: back / strollSpeed, hop: false),
            hop(c, home),
        ], ledge: ledge)
    }

    private static func hop(_ from: CGPoint, _ to: CGPoint) -> Leg {
        let d = hypot(to.x - from.x, to.y - from.y)
        return Leg(from: from, to: to, duration: max(0.35, d / hopSpeed), hop: true)
    }

    /// Straight home from wherever it is — an ask opened, the edge moved.
    static func homeward(from: CGPoint, home: CGPoint) -> BuddyStroll {
        BuddyStroll(legs: [hop(from, home)], ledge: nil)
    }

    // MARK: Walking it

    /// Where the pet is `elapsed` seconds in, or nil once it is home.
    func point(at elapsed: TimeInterval) -> CGPoint? {
        guard elapsed >= 0 else { return legs.first?.from }
        var t = elapsed
        for leg in legs {
            if t < leg.duration {
                var p = t / leg.duration
                if leg.hop { p = p * p * (3 - 2 * p) }
                return CGPoint(x: leg.from.x + (leg.to.x - leg.from.x) * p,
                               y: leg.from.y + (leg.to.y - leg.from.y) * p)
            }
            t -= leg.duration
        }
        return nil
    }

    /// Which way the pet faces `elapsed` seconds in: +1 right, -1 left,
    /// nil while it isn't strolling along the edge (the hops keep the
    /// pose's own patrol). The figure eases between them (`BuddyTurn`);
    /// this is the target, not the drawn value.
    func heading(at elapsed: TimeInterval) -> Double? {
        var t = elapsed
        for leg in legs {
            if t < leg.duration {
                if let facing = leg.facing { return facing }
                guard !leg.hop, leg.to.x != leg.from.x else { return nil }
                return leg.to.x > leg.from.x ? 1 : -1
            }
            t -= leg.duration
        }
        return nil
    }

    /// The edge is still where it was: some window's frame matches the
    /// planned one within a few points. The screen bottom never moves.
    static func ledgeStands(_ ledge: CGRect?, in windows: [CGRect]) -> Bool {
        guard let ledge else { return true }
        return windows.contains {
            abs($0.minX - ledge.minX) <= 4 && abs($0.maxX - ledge.maxX) <= 4
                && abs($0.maxY - ledge.maxY) <= 4
        }
    }

    /// The on-screen app windows, front to back, in AppKit coordinates —
    /// bounds and layer only, which need no permission. Ours are left
    /// out: the buddy doesn't stand on its own panel.
    @MainActor
    static func windowFrames() -> [CGRect] {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != own,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
                          width: rect.width, height: rect.height)
        }
    }
}

/// A walk in flight, the way the free panel steps it: the plan, the clock
/// it runs on, and the holds a press puts in it. The panel reads
/// `centre(at:)` and `heading(at:)` once a frame and moves its window;
/// every rule about where the pet is drawn lives here, so the per-frame
/// motion is pinned by the tests rather than by eye.
struct BuddyWalk: Equatable {
    var plan: BuddyStroll
    /// When (uptime) the plan set off, pushed later by every hold.
    var began: TimeInterval
    /// Held still since (uptime): a press on the pet, or its menu open.
    /// nil while it walks.
    var heldSince: TimeInterval?

    init(plan: BuddyStroll, began: TimeInterval) {
        self.plan = plan
        self.began = began
    }

    /// How far into the plan it is at `now`; a hold stops the clock.
    func elapsed(at now: TimeInterval) -> TimeInterval {
        (heldSince ?? now) - began
    }

    /// The pet's centre at `now`, or nil once it is home.
    func centre(at now: TimeInterval) -> CGPoint? {
        plan.point(at: elapsed(at: now))
    }

    /// The heading to face at `now` (the figure's turn target).
    func heading(at now: TimeInterval) -> Double? {
        plan.heading(at: elapsed(at: now))
    }

    /// A press landed on it: it stands where it is until the release.
    mutating func hold(at now: TimeInterval) {
        if heldSince == nil { heldSince = now }
    }

    /// The press let go: the walk picks up where it stopped.
    mutating func release(at now: TimeInterval) {
        guard let held = heldSince else { return }
        began += max(0, now - held)
        heldSince = nil
    }

    /// Straight home from where it is drawn — an ask opened, the edge
    /// went, the panel was resized or re-parked. Starting from the drawn
    /// spot is what keeps the change from jumping.
    mutating func headHome(from drawn: CGPoint, home: CGPoint, at now: TimeInterval) {
        plan = BuddyStroll.homeward(from: drawn, home: home)
        began = now
        heldSince = nil
    }

    /// The window origin for a centre, on whole points the way the panel
    /// sets it.
    static func origin(for centre: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded())
    }
}
