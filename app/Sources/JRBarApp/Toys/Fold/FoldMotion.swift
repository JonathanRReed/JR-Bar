import Foundation
import JRBarCore

/// Fold's one motion path: the hinge sensor in, the angle to draw out.
///
/// The sensor reports whole degrees from a sample-and-hold that refreshes
/// about ten times a second, so a close arrives as a staircase: a 5°/s
/// close is one degree every 200 ms, a 90°/s slam is nine degrees every
/// 100 ms. Three pieces turn that into motion that follows the lid:
///
/// - `FoldLidTracker` reads each change of the reading as a timed
///   measurement (a one-degree step means the true angle just crossed
///   the half-degree between the two readings), keeps a speed estimate,
///   and dead-reckons the angle between readings. Its gain follows the
///   size of the surprise, the way the one-euro filter's cutoff follows
///   the speed: small corrections are trusted lightly so the speed does
///   not shake, a real change of pace is trusted fully so the picture
///   does not trail it.
/// - `FoldAngleSpring` is one critically damped spring on that target,
///   written in the target's own moving frame, so a steady close is
///   followed with no lag and a stop settles without overshoot. It is
///   stepped exactly, so any frame time is stable.
/// - `FoldMotion` holds the two together with the rest guard: while the
///   lid is parked, the sensor's one-degree flicker is held at the door
///   and nothing moves, and the first reading that cannot be flicker ends
///   the rest. Nothing is dropped while the lid is moving.
///
/// Every piece takes its clock as an argument and owns no timer, so the
/// whole path replays deterministically from a recorded angle trace.

// MARK: - FoldLidTracker

struct FoldLidTracker: Sendable {
    /// Seconds with no change in the reading before a new change counts
    /// as the lid leaving rest.
    static let restGap: TimeInterval = 0.6
    /// The longest the angle is carried forward on the speed estimate
    /// when the lid is fast: one sensor period.
    static let reachFloor: TimeInterval = 0.1
    /// The longest it is carried at any speed.
    static let reachCeiling: TimeInterval = 0.5
    /// The distance, in degrees, the carry may cover at slow speeds: a
    /// little over one reading step, so the angle keeps gliding until the
    /// next whole degree is due.
    static let reachDegrees = 1.3
    /// After the carry runs out, how long the angle is held before it
    /// eases back to the last reading, and how fast.
    static let holdAfterReach: TimeInterval = 0.05
    static let returnTime: TimeInterval = 0.08
    /// A change of at least this many degrees on leaving rest is a fast
    /// start; its speed is at least the step over a sensor period.
    static let fastStartStep = 3.0
    static let fastStartSpan: TimeInterval = 0.06
    /// Mean age of a sample-and-hold reading, as a share of the speed.
    static let sampleAge: TimeInterval = 0.02

    // The gains: a calm correction and a surprised one, and the residual
    // (degrees) over which one becomes the other.
    static let calmPosition = 0.3, surprisedPosition = 0.9
    static let calmRate = 0.1, surprisedRate = 0.9
    static let calmResidual = 0.8, surprisedResidual = 2.0
    /// How far the carry is trimmed after a surprise: a lid that just
    /// changed pace is as likely to be slowing as speeding, and carrying
    /// it on at the old speed is what overshoots a stop.
    static let surprisedCarry = 0.2
    /// The first edges after a rest trust the readings more, fading by
    /// this factor per edge to the calm gains.
    static let warmFade = 0.7

    private(set) var position = 0.0
    private(set) var rate = 0.0
    private var updatedAt: TimeInterval = 0
    private var reading = 0.0
    private var primed = false
    private var firstEdge: (value: Double, at: TimeInterval)?
    private var edgesSinceRest = 0
    private var surprise = 0.0
    private var restPending = false
    private var changedAt: TimeInterval = -.infinity

    var isPrimed: Bool { primed }

    mutating func reset() { self = FoldLidTracker() }

    /// Seats the tracker on `angle` with no motion, as a first reading.
    mutating func seat(_ angle: Double, at t: TimeInterval) {
        guard angle.isFinite, t.isFinite else { return }
        self = FoldLidTracker()
        primed = true
        restPending = true
        position = angle
        reading = angle
        updatedAt = t
        changedAt = t
    }

    /// The next change is the lid leaving rest, whatever the clock says.
    mutating func beginFromRest() { restPending = true }

    /// A reading that did not move the tracker (held at the door) still
    /// counts as the reading's latest change.
    mutating func noteHeld(_ value: Double, at t: TimeInterval) {
        guard primed, value.isFinite, t.isFinite, value != reading else { return }
        changedAt = t
    }

    mutating func feed(_ value: Double, at t: TimeInterval) {
        guard value.isFinite, t.isFinite else { return }
        guard primed else {
            seat(value, at: t)
            return
        }
        guard value != reading else { return }
        guard t > updatedAt else {
            // A clock hiccup: take the value, keep the time.
            reading = value
            return
        }
        let step = value - reading
        let boundary = abs(step) == 1 ? value - 0.5 * (step > 0 ? 1 : -1) : value
        let gap = t - updatedAt
        if gap > Self.restGap || restPending {
            restPending = false
            edgesSinceRest = 0
            surprise = 0
            position = boundary
            firstEdge = (boundary, t)
            rate = abs(step) >= Self.fastStartStep ? step / Self.fastStartSpan : 0
            updatedAt = t
            reading = value
            changedAt = t
            return
        }
        edgesSinceRest += 1
        defer { changedAt = t }
        if let first = firstEdge {
            // The second edge after a rest: a two-point speed.
            rate = (boundary - first.value) / max(1e-3, t - first.at)
            firstEdge = nil
            position = boundary
            updatedAt = t
            reading = value
            return
        }
        var measured = boundary
        if abs(step) == 1 { measured -= rate * Self.sampleAge }
        let predicted = position + rate * gap
        let residual = measured - predicted
        surprise = FoldDuoModel.smoothstep(Self.calmResidual, Self.surprisedResidual, abs(residual))
        let warm = pow(Self.warmFade, Double(edgesSinceRest))
        let calmP = max(Self.calmPosition, 0.8 * warm)
        let calmR = max(Self.calmRate, 0.7 * warm)
        let gainP = calmP + (Self.surprisedPosition - calmP) * surprise
        let gainR = calmR + (Self.surprisedRate - calmR) * surprise
        position = predicted + gainP * residual
        rate += gainR * residual / gap
        updatedAt = t
        reading = value
    }

    /// How long the angle is carried on the speed estimate at this speed.
    var reach: TimeInterval {
        let speed = abs(rate)
        guard speed > 1e-6 else { return Self.reachFloor }
        return min(Self.reachCeiling, max(Self.reachFloor, Self.reachDegrees / speed))
    }

    /// The angle and its speed to aim at, `t` host seconds. Past the
    /// carry the angle holds, then eases back to the last reading, and
    /// the speed is 0.
    func sample(at t: TimeInterval) -> (angle: Double, rate: Double)? {
        guard primed else { return nil }
        let age = max(0, t - updatedAt)
        let reach = self.reach
        let carry = 1 - (1 - Self.surprisedCarry) * surprise
        var angle = position + rate * carry * min(age, reach)
        let hold = reach + Self.holdAfterReach
        if age > hold {
            let k = exp(-(age - hold) / Self.returnTime)
            angle = reading + (angle - reading) * k
            if k < 1e-3 { angle = reading }
        }
        return (angle, age <= reach ? rate * carry : 0)
    }

    /// True once the eased return has landed on the last reading.
    func settled(at t: TimeInterval) -> Bool {
        guard primed else { return true }
        // Never carried anywhere: nothing to ease back.
        if rate == 0, position == reading { return true }
        let age = max(0, t - updatedAt)
        return age > reach + Self.holdAfterReach + Self.returnTime * 7
    }
}

// MARK: - FoldAngleSpring

/// One critically damped spring on the lid angle, in the moving frame of
/// its target: given the target's speed it follows a steady ramp with no
/// lag, and the exact solution makes it stable at any frame time.
struct FoldAngleSpring: Sendable {
    /// Natural frequency, rad/s. 25 settles a jump in about a tenth of a
    /// second and smooths the corrections between readings.
    var omega = 25.0
    /// The visible angular speed never exceeds this, deg/s.
    var maxRate = 240.0
    /// A single tick longer than this is a stall (a slept display), not
    /// a frame.
    var maxDt = 0.05

    private(set) var position = 0.0
    private(set) var velocity = 0.0
    private(set) var primed = false

    mutating func reset() { self = FoldAngleSpring(omega: omega, maxRate: maxRate, maxDt: maxDt) }

    mutating func seat(_ angle: Double) {
        guard angle.isFinite else { return }
        position = angle
        velocity = 0
        primed = true
    }

    /// One frame. `target` and `rate` are the aim and its speed (deg/s).
    mutating func tick(target: Double, rate: Double, dt rawDt: Double) {
        guard target.isFinite, rate.isFinite else { return }
        guard primed else {
            seat(target)
            return
        }
        guard rawDt.isFinite, rawDt > 0 else { return }
        let dt = min(rawDt, maxDt)
        // `target` is the aim at the end of this step; it moved `rate * dt`
        // to get there, and the spring is solved in its moving frame.
        let y0 = position - (target - rate * dt)
        let w0 = velocity - rate
        let decay = exp(-omega * dt)
        let carry = w0 + omega * y0
        let y = (y0 + carry * dt) * decay
        let w = (w0 - omega * carry * dt) * decay
        var nextVelocity = rate + w
        var nextPosition = target + y
        if abs(nextVelocity) > maxRate {
            nextVelocity = nextVelocity < 0 ? -maxRate : maxRate
            nextPosition = position + nextVelocity * dt
        }
        position = nextPosition
        velocity = nextVelocity
        if rate == 0, abs(position - target) < 0.01, abs(velocity) < 0.2 {
            position = target
            velocity = 0
        }
    }
}

// MARK: - FoldMotion

struct FoldMotion: Sendable {
    /// Readings within this many degrees of the parked lid are flicker.
    /// 0 holds nothing. The setting `jitterTolerance` feeds it.
    var tolerance = 1.5
    /// Seconds of stillness (inside one spot's window) before the lid
    /// counts as parked.
    static let restAfter: TimeInterval = 0.6
    /// The widest wobble that still counts as one spot.
    static let restWindow = 1.5

    private var tracker = FoldLidTracker()
    private var spring = FoldAngleSpring()
    private var direct: Double?
    private var restAngle = 0.0
    private var restAt: TimeInterval = 0
    private var restLow = 0.0
    private var restHigh = 0.0
    private var parked: ClosedRange<Double>?
    private var lastTarget: (angle: Double, rate: Double)?

    /// The angle to draw, from the last tick; nil before any reading.
    var angle: Double? { spring.primed ? spring.position : nil }
    var velocity: Double { spring.velocity }
    var isParked: Bool { parked != nil }

    mutating func reset() {
        tracker.reset()
        spring.reset()
        direct = nil
        parked = nil
        lastTarget = nil
    }

    /// Seats everything on `angle`, at rest — the sensor's reading after
    /// a simulation hands the lid back.
    mutating func seat(_ value: Double, at t: TimeInterval) {
        reset()
        guard value.isFinite, t.isFinite else { return }
        tracker.seat(value, at: t)
        spring.seat(value)
        restAngle = value
        restAt = t
        restLow = value
        restHigh = value
    }

    /// A sensor reading. Returns false when the rest guard held it (a
    /// parked lid's flicker) and true when it reached the motion.
    @discardableResult
    mutating func feed(_ reading: Double, at t: TimeInterval) -> Bool {
        guard reading.isFinite, t.isFinite else { return false }
        direct = nil
        if let spot = parked {
            let slack = max(0, tolerance - 1)
            if tolerance > 0, reading >= spot.lowerBound - slack, reading <= spot.upperBound + slack {
                tracker.noteHeld(reading, at: t)
                return false
            }
            parked = nil
            tracker.beginFromRest()
            beginRestWindow(reading, at: t)
        }
        guard tracker.isPrimed else {
            tracker.feed(reading, at: t)
            spring.seat(reading)
            beginRestWindow(reading, at: t)
            return true
        }
        let window = min(tolerance, Self.restWindow)
        if abs(reading - restAngle) < window {
            restLow = min(restLow, reading)
            restHigh = max(restHigh, reading)
        } else {
            beginRestWindow(reading, at: t)
        }
        tracker.feed(reading, at: t)
        return true
    }

    private mutating func beginRestWindow(_ reading: Double, at t: TimeInterval) {
        restAngle = reading
        restAt = t
        restLow = reading
        restHigh = reading
    }

    /// The simulation slider and Try it: already smooth, so the angle
    /// goes straight to the spring.
    mutating func feedDirect(_ value: Double) {
        guard value.isFinite else { return }
        direct = value
        parked = nil
        if !spring.primed { spring.seat(value) }
    }

    /// One frame at host time `now`, `dt` seconds after the last.
    @discardableResult
    mutating func tick(at now: TimeInterval, dt: Double) -> Double? {
        if let value = direct {
            spring.tick(target: value, rate: 0, dt: dt)
            lastTarget = (value, 0)
            return angle
        }
        guard tracker.isPrimed else { return nil }
        if parked == nil, tolerance > 0, now - restAt >= Self.restAfter {
            parked = restLow...restHigh
        }
        guard let aim = tracker.sample(at: now) else { return angle }
        spring.tick(target: aim.angle, rate: aim.rate, dt: dt)
        lastTarget = aim
        return angle
    }

    /// Nothing left to move: the lid parked, the tracker's return landed
    /// and the spring on its target. The display link stands down here.
    func atRest(at now: TimeInterval) -> Bool {
        // A slider write can arrive while the display clock is stopped.
        // Compare with its new target so that write wakes the clock.
        if let value = direct { return spring.position == value && spring.velocity == 0 }
        guard tracker.isPrimed else { return true }
        guard tracker.settled(at: now), let aim = lastTarget ?? tracker.sample(at: now) else { return false }
        return spring.position == aim.angle && spring.velocity == 0
    }
}

// MARK: - FoldGateEase

/// The displayed delta between the spring's honest motion and the gate.
///
/// Almost always the delta is just what the lid angle says. The exception
/// is a gate that shuts under a fold in flight — the resting angle
/// re-seated, the dwell pause handing the desktop back — which makes the
/// target leap to 0 faster than any hinge could move. That leap is eased
/// out over a quarter second instead of cutting the picture. A target
/// that falls no faster than the lid can open is followed exactly, so a
/// real reopen retraces the close.
struct FoldGateEase: Sendable {
    static let releaseDuration: TimeInterval = 0.25
    /// rad/s: just above the spring's own speed cap (240°/s ≈ 4.2 rad/s),
    /// so honest motion is never mistaken for a snap.
    static let followRate = 5.0
    static let maxDt = 0.05

    private(set) var value = 0.0
    private var target = 0.0
    private var release: (from: Double, elapsed: Double)?

    /// Exactly on the target with nothing easing.
    var atRest: Bool { release == nil && value == target }

    mutating func reset() { self = FoldGateEase() }

    @discardableResult
    mutating func tick(target newTarget: Double, dt rawDt: Double) -> Double {
        guard newTarget.isFinite else { return value }
        target = max(0, newTarget)
        if target >= value {
            value = target
            release = nil
            return value
        }
        guard rawDt.isFinite, rawDt > 0 else { return value }
        let dt = min(rawDt, Self.maxDt)
        if var easing = release {
            easing.elapsed = min(Self.releaseDuration, easing.elapsed + dt)
            let u = easing.elapsed / Self.releaseDuration
            let eased = u * u * (3 - 2 * u)
            value = max(target, target + (easing.from - target) * (1 - eased))
            release = easing.elapsed >= Self.releaseDuration ? nil : easing
            if release == nil { value = target }
            return value
        }
        if value - target <= Self.followRate * dt {
            value = target
        } else if target == 0 {
            release = (value, 0)
            return tick(target: target, dt: dt)
        } else {
            value = max(target, value - Self.followRate * dt)
        }
        return value
    }
}

// MARK: - FoldEntryFade

/// How a fold already under way comes into view. The capture starts with
/// the gesture and its first frame lands a few tenths of a second later,
/// by which time the lid may be well down; the fold then appears at the
/// lid's real angle, never rushed to it. What fades is the overlay's
/// opacity: over the lid's next few degrees of travel, or a fifth of a
/// second, whichever finishes first, so a lid parked right there still
/// gets its fold.
struct FoldEntryFade: Sendable {
    /// Degrees of travel past the entry angle that bring it to full.
    static let travel = 8.0
    static let duration: TimeInterval = 0.2
    /// Below this much delta (radians) the Duo's own two-degree opacity
    /// ramp already covers the entry.
    static let threshold = 2.0 * Double.pi / 180

    private var start: (delta: Double, at: TimeInterval)?

    var active: Bool { start != nil }

    mutating func reset() { start = nil }

    mutating func begin(delta: Double, at t: TimeInterval) {
        guard delta.isFinite, t.isFinite, delta > Self.threshold else { return }
        start = (delta, t)
    }

    /// The opacity share at `t` for the lid `delta` radians in; 1 once
    /// done, and the fade retires itself there.
    mutating func opacity(delta: Double, at t: TimeInterval) -> Double {
        guard let start else { return 1 }
        let travelled = (delta - start.delta) * 180 / .pi
        let byLid = FoldDuoModel.smoothstep(0, Self.travel, travelled)
        let byTime = FoldDuoModel.smoothstep(0, Self.duration, t - start.at)
        let share = max(byLid, byTime)
        if share >= 1 { self.start = nil }
        return share
    }
}
