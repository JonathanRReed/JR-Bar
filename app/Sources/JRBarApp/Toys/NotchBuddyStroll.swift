import AppKit
import CoreGraphics
import Foundation

/// The floating buddy's calm walkabout (docs/TOYS.md) — neko's manners,
/// not the goose's. Now and then, while the agents are working and
/// nothing is asking, it hops up onto the top edge of the frontmost
/// window (or the bottom of the screen when no window has room), strolls
/// a little way along it, and comes home to the spot you parked it on.
/// It only ever moves its own panel: never the cursor, never a window,
/// and a press on it cancels the stroll. Pure, so the path is pinned.
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

    // MARK: When

    /// Minutes between the decision beats' chances, and the chance each
    /// beat takes once the quiet stretch has passed — about one stroll
    /// every twelve minutes of work.
    static let minGap: TimeInterval = 8 * 60
    static let chance: Double = 0.25

    /// Only a working, unbothered buddy strolls: something is running,
    /// nothing asks or failed, it isn't being carried, and Reduce Motion
    /// is off.
    static func shouldStroll(working: Int, waiting: Int, failed: Int, dragging: Bool,
                             reduceMotion: Bool, sinceLast: TimeInterval, roll: Double) -> Bool {
        working > 0 && waiting == 0 && failed == 0 && !dragging && !reduceMotion
            && sinceLast >= minGap && roll < chance
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
        return BuddyStroll(legs: [
            hop(home, a),
            Leg(from: a, to: b, duration: length / strollSpeed, hop: false),
            hop(b, home),
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
    /// pose's own patrol).
    func heading(at elapsed: TimeInterval) -> Double? {
        var t = elapsed
        for leg in legs {
            if t < leg.duration {
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
