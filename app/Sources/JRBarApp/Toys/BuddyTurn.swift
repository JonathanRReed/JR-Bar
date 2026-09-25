import CoreGraphics
import Foundation

/// A change of heading, eased (docs/TOYS.md). The walking buddy used to
/// face the new way in one frame: a 10° flip of the lean and the pupils
/// jumping from one side of the eye to the other. Now a heading change
/// takes `duration` on a smoothstep. The eyes lead and land first, the
/// body follows, the lean passes through upright, and the body narrows a
/// touch at the midpoint, the way a small creature does while it turns
/// side-on. Stepping out of the mood's own patrol into a walk, and back
/// out of it, blends the two poses over the same beat, so a hop onto a
/// window's edge never lands with a snap. Reduce Motion takes the new
/// stance in one step. Pure, so every frame is pinned.
struct BuddyTurn: Equatable, Sendable {
    /// Where the pose stands between turns.
    struct Stance: Equatable, Sendable {
        /// Which way the body faces, -1 left … +1 right.
        var facing: Double
        /// Which way the eyes look, on the same scale. They lead the body.
        var look: Double
        /// How much of the pose is the walk's: 0 is the mood's own patrol,
        /// 1 is the stroll.
        var weight: Double

        /// In the mood's own patrol, last facing right.
        static let patrol = Stance(facing: 1, look: 1, weight: 0)

        /// Walking the way `heading` says (+1 right, -1 left).
        static func walking(_ heading: Double) -> Stance {
            let side = heading < 0 ? -1.0 : 1.0
            return Stance(facing: side, look: side, weight: 1)
        }
    }

    /// One drawn frame of the turn.
    struct Frame: Equatable, Sendable {
        var facing: Double
        var look: Double
        var weight: Double
        /// The midpoint narrowing; 1×1 outside a turn.
        var squash: CGSize
        /// The change has landed on its target.
        var settled: Bool

        /// The stroll's lean into the stride, in degrees.
        var lean: Double { facing * BuddyTurn.leanDegrees }
        /// Where the pupils sit across the eye.
        var lookWidth: Double { look * BuddyTurn.lookReach }
    }

    /// The whole turn, body included.
    static let duration: TimeInterval = 0.35
    /// The eyes' share of it: they cross first and wait for the body.
    static let eyeDuration: TimeInterval = 0.26
    /// How much narrower the body is at the midpoint of a full reversal.
    static let narrowing: Double = 0.07
    /// The walk's lean into the stride, and how far the pupils sit toward
    /// the way it walks — the numbers the patrol has always used.
    static let leanDegrees: Double = 5
    static let lookReach: Double = 0.9

    var from: Stance = .patrol
    var to: Stance = .patrol
    /// When the change was asked for.
    var began: Date = .distantPast

    /// The frame `elapsed` seconds into a change from `from` to `to`.
    /// Past `duration` (or under Reduce Motion) it is the target itself.
    static func eased(from: Stance, to: Stance, elapsed: TimeInterval, still: Bool = false) -> Frame {
        guard !still, elapsed.isFinite, elapsed < duration else {
            return Frame(facing: to.facing, look: to.look, weight: to.weight,
                         squash: CGSize(width: 1, height: 1), settled: true)
        }
        let t = max(0, elapsed)
        let body = smooth(t / duration)
        let eyes = smooth(t / eyeDuration)
        // A full reversal narrows by `narrowing` at its midpoint; a
        // smaller swing narrows in proportion.
        let swing = min(1, abs(to.facing - from.facing) / 2)
        let pinch = narrowing * swing * sin(body * .pi)
        return Frame(facing: from.facing + (to.facing - from.facing) * body,
                     look: from.look + (to.look - from.look) * eyes,
                     weight: from.weight + (to.weight - from.weight) * body,
                     squash: CGSize(width: 1 - pinch, height: 1 + pinch * 0.5),
                     settled: false)
    }

    /// The same, from one heading to another: nil is the mood's own patrol.
    static func eased(from: Double?, to: Double?, elapsed: TimeInterval, still: Bool = false) -> Frame {
        var start = from.map(Stance.walking) ?? .patrol
        let end = to.map(Stance.walking) ?? Stance(facing: start.facing, look: start.look, weight: 0)
        if from == nil, to != nil {
            // Out of the patrol there is nothing to turn from: the walk
            // blends in already facing its way.
            start.facing = end.facing
            start.look = end.look
        }
        return eased(from: start, to: end, elapsed: elapsed, still: still)
    }

    /// The frame drawn at `now`.
    func frame(at now: Date, still: Bool = false) -> Frame {
        Self.eased(from: from, to: to, elapsed: now.timeIntervalSince(began), still: still)
    }

    /// Nothing to draw: back in the patrol and settled there.
    func isResting(at now: Date) -> Bool {
        to.weight == 0 && frame(at: now).settled
    }

    /// A new heading to face (nil: back to the patrol). The change starts
    /// from wherever the pose is drawn right now, so a second turn that
    /// lands mid-turn carries on from there instead of snapping back. The
    /// same target again keeps the turn in flight. Returns whether
    /// anything changed.
    @discardableResult
    mutating func retarget(_ heading: Double?, at now: Date, still: Bool = false) -> Bool {
        let drawn = frame(at: now, still: still)
        var start = Stance(facing: drawn.facing, look: drawn.look, weight: drawn.weight)
        let target: Stance
        if let heading {
            target = .walking(heading)
            if start.weight < 0.01 {
                start.facing = target.facing
                start.look = target.look
            }
        } else if to.weight == 0 {
            // Already on its way back to the patrol.
            target = to
        } else {
            // The turn in flight finishes while the walk fades out.
            target = Stance(facing: to.facing, look: to.look, weight: 0)
        }
        guard target != to else { return false }
        from = start
        to = target
        began = now
        return true
    }

    // MARK: The carry's dangle

    /// The carried buddy's tilt, following the cursor's travel on a short
    /// time constant instead of taking each mouse event's tilt whole. A
    /// sudden change of direction swings it back through upright over a
    /// few frames rather than flipping it in one.
    static let dangleLag: TimeInterval = 0.08
    /// The most one event can count for: an event after a pause moves
    /// the dangle a frame's worth, not the whole way.
    static let longestStep: TimeInterval = 1.0 / 30.0

    static func follow(_ current: Double, toward target: Double, dt: TimeInterval) -> Double {
        guard target.isFinite else { return current.isFinite ? current : 0 }
        guard current.isFinite else { return target }
        guard dt.isFinite, dt > 0 else { return current }
        let k = 1 - exp(-min(dt, longestStep) / dangleLag)
        return current + (target - current) * k
    }

    // MARK: Easing

    /// Smoothstep, clamped.
    static func smooth(_ t: Double) -> Double {
        let t = min(max(t.isFinite ? t : 1, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A mood change, eased: for `duration` the pose the buddy had fades into
/// the one it has now. A completion hop used to start from dead centre
/// wherever the patrol had carried it, and the patrol picked up again
/// three points off to the side the frame the hop ended; an ask, a slump
/// and waking up all jumped the same way. The new mood's own entrance
/// (the ask's crouch, the slump's tumble) still plays; it just starts
/// from where the body was.
struct BuddyHandoff: Equatable, Sendable {
    /// The mood it is leaving.
    var from: NotchBuddyToy.Mood
    /// Seconds since the change.
    var age: TimeInterval
    /// When the change landed part-way through an earlier one, the pose it
    /// leaves is the blend drawn at that moment, as each mood's share.
    /// Empty: `from` whole.
    var blend: [NotchBuddyToy.Mood: Double] = [:]

    static let duration: TimeInterval = 0.24

    /// How much of the new mood's pose shows, 0 → 1.
    var weight: Double { BuddyTurn.smooth(age / Self.duration) }
    var isOver: Bool { !(age < Self.duration) }

    /// The pose it leaves, as each mood's share.
    var leaving: [NotchBuddyToy.Mood: Double] { blend.isEmpty ? [from: 1] : blend }

    /// What is drawn at this age, handing into `mood`, as each mood's
    /// share: the leaving pose fading out, `mood` fading in. A change
    /// that lands now starts from exactly this. A share too small to
    /// see is dropped, so the list stays short.
    func shares(into mood: NotchBuddyToy.Mood) -> [NotchBuddyToy.Mood: Double] {
        let w = weight
        var out = leaving.mapValues { $0 * (1 - w) }
        out[mood, default: 0] += w
        return out.filter { $0.value > 0.001 }
    }
}

/// Each mood's share of the figure drawn this frame, for the parts a body
/// shapes by mood: the crab's claws, the axolotl's fronds, the cat's ears
/// and tail, the owl's tufts and wings, the slime's melt, the mushroom's
/// slump and the saucer's beam. Outside a handoff it is the mood whole.
/// Through one, each part takes every mood's own value by its share, so
/// it swings over the same 0.24 s as the pose instead of jumping.
struct BuddyMoodShares: Equatable, Sendable {
    /// The mood being handed into.
    var mood: NotchBuddyToy.Mood
    /// Each mood's share, summing to 1.
    var shares: [NotchBuddyToy.Mood: Double]

    init(_ mood: NotchBuddyToy.Mood, handoff: BuddyHandoff? = nil) {
        self.mood = mood
        var drawn: [NotchBuddyToy.Mood: Double] = [mood: 1]
        if let handoff, !handoff.isOver { drawn = handoff.shares(into: mood) }
        let total = drawn.values.reduce(0, +)
        shares = total > 0 ? drawn.mapValues { $0 / total } : [mood: 1]
    }

    /// How much of the figure is `mood`'s, 0 … 1.
    func share(of mood: NotchBuddyToy.Mood) -> Double { shares[mood] ?? 0 }

    /// A part's measure: each mood's own value by its share. Summed in
    /// a fixed order, so a frame never differs from the last by rounding.
    func mix(_ value: (NotchBuddyToy.Mood) -> Double) -> Double {
        var sum = 0.0
        for mood in shares.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            sum += value(mood) * (shares[mood] ?? 0)
        }
        return sum
    }
}

/// The buddy arriving where it now lives, drawn over `duration`: grown in
/// from the size it had and drifted in from where it was, so a drop out
/// of the notch at 2× doesn't blink and double in one frame, and a buddy
/// back from a nap pops up instead of appearing.
struct BuddyArrival: Equatable, Sendable {
    /// The size it starts at, as a share of its own.
    var fromScale: Double
    /// Where it starts relative to where it lands, in screen points
    /// (SwiftUI's y-down).
    var drift: CGSize
    var age: TimeInterval

    static let duration: TimeInterval = 0.3

    var isOver: Bool { !(age < Self.duration) }
    private var eased: Double { BuddyTurn.smooth(age / Self.duration) }
    var scale: Double { fromScale + (1 - fromScale) * eased }
    var offset: CGSize {
        CGSize(width: drift.width * (1 - eased), height: drift.height * (1 - eased))
    }
}
