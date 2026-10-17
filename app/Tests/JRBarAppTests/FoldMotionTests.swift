import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Fold's motion path (FoldMotion.swift), replayed from recorded-style
/// angle traces: the hinge sensor as it behaves on the bench (whole
/// degrees from a sample-and-hold that refreshes about ten times a
/// second, polled at 120 Hz while the fold is armed) in, the angle the
/// display link would draw at 120 Hz out. The clock is the loop counter:
/// nothing here waits on the wall.
@Suite("Fold motion")
struct FoldMotionTests {
    struct Frame {
        var t: Double
        var truth: Double
        var shown: Double
        var velocity: Double
    }

    /// One sample-and-hold sensor reading: the whole degree the true lid
    /// was at the sensor's last refresh before `t`.
    static func reading(_ truth: (Double) -> Double, at t: Double,
                        period: Double = 0.1, phase: Double = 0.037) -> Double {
        let beat = ((t - phase) / period).rounded(.down)
        return truth(max(0, beat) * period + phase).rounded()
    }

    /// Replays `truth` through the motion: a poll every `pollEvery`
    /// seconds feeds the reading, a tick every 1/120 s draws.
    static func replay(_ truth: (Double) -> Double, duration: Double,
                       pollEvery: Double = 1.0 / 120, tolerance: Double = 1.5) -> [Frame] {
        var motion = FoldMotion()
        motion.tolerance = tolerance
        let dt = 1.0 / 120
        var frames: [Frame] = []
        var nextPoll = 0.0
        var t = 0.0
        while t < duration {
            while nextPoll <= t + 1e-12 {
                motion.feed(reading(truth, at: nextPoll), at: nextPoll)
                nextPoll += pollEvery
            }
            let shown = motion.tick(at: t, dt: dt) ?? truth(t)
            frames.append(Frame(t: t, truth: truth(t), shown: shown, velocity: motion.velocity))
            t += dt
        }
        return frames
    }

    /// A lid at `start` until 0.3 s, then closing at a steady `speed` to
    /// `stop` and holding there.
    static func close(speed: Double, start: Double = 110, stop: Double = 40) -> (Double) -> Double {
        { t in max(stop, start - speed * max(0, t - 0.3)) }
    }

    /// The steady stretch of a close: past the first reading's settling
    /// and short of the stop.
    static func steady(_ frames: [Frame], speed: Double, start: Double = 110, stop: Double = 40) -> [Frame] {
        frames.filter { $0.t > max(0.85, 0.3 + 12 / speed) && $0.truth < start - 8 && $0.truth > stop + 8 }
    }

    /// Lag of the drawn lid behind the real one, in ms (negative: ahead),
    /// and the speed ripple, peak to peak as a share of the lid's speed.
    static func measure(_ frames: [Frame], speed: Double) -> (lagMs: Double, ripple: Double) {
        let lag = frames.map { $0.shown - $0.truth }.reduce(0, +) / Double(frames.count)
        let speeds = frames.map { -$0.velocity }
        return (lag / speed * 1000, ((speeds.max() ?? 0) - (speeds.min() ?? 0)) / speed * 100)
    }

    // MARK: Steady closes

    @Test("a 5°/s close moves steadily: no plateaus, no steps, never backwards")
    func slowClose() throws {
        let frames = Self.replay(Self.close(speed: 5), duration: 14)
        let window = Self.steady(frames, speed: 5)
        try #require(window.count > 600)
        let m = Self.measure(window, speed: 5)
        #expect(m.ripple < 60, "speed ripple \(m.ripple)%")
        #expect(abs(m.lagMs) < 150, "lag \(m.lagMs) ms")
        var longest = 0, run = 0
        for frame in window {
            // A plateau is the picture standing still while the lid moves.
            if -frame.velocity < 0.25 * 5 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        #expect(longest == 0, "stood still for \(longest) frames mid-close")
        for pair in zip(window, window.dropFirst()) {
            #expect(pair.1.shown <= pair.0.shown + 1e-9, "moved back up at \(pair.1.t)")
        }
    }

    @Test("a 20°/s close follows within 60 ms and with a quiet speed")
    func mediumClose() throws {
        let frames = Self.replay(Self.close(speed: 20), duration: 5)
        let window = Self.steady(frames, speed: 20)
        try #require(window.count > 200)
        let m = Self.measure(window, speed: 20)
        #expect(m.ripple < 25, "speed ripple \(m.ripple)%")
        #expect(abs(m.lagMs) < 60, "lag \(m.lagMs) ms")
        for pair in zip(window, window.dropFirst()) {
            #expect(pair.1.shown <= pair.0.shown + 1e-9, "moved back up at \(pair.1.t)")
        }
    }

    @Test("a 90°/s slam keeps up within 60 ms and without pulsing")
    func fastClose() throws {
        let frames = Self.replay(Self.close(speed: 90), duration: 2)
        let window = Self.steady(frames, speed: 90)
        try #require(window.count > 12)
        let m = Self.measure(window, speed: 90)
        #expect(m.ripple < 12, "speed ripple \(m.ripple)%")
        #expect(abs(m.lagMs) < 60, "lag \(m.lagMs) ms")
        // Velocity continuity: no frame changes the speed by a third of it.
        for pair in zip(frames, frames.dropFirst()) where pair.0.t > 0.85 && pair.0.truth > 48 {
            #expect(abs(pair.1.velocity - pair.0.velocity) < 30, "speed jumped at \(pair.1.t)")
        }
    }

    @Test("the polled rate does not matter: 10 Hz readings draw the same close")
    func parkedPollRate() throws {
        let frames = Self.replay(Self.close(speed: 40), duration: 3, pollEvery: 0.1)
        let window = Self.steady(frames, speed: 40)
        try #require(window.count > 100)
        let m = Self.measure(window, speed: 40)
        #expect(m.ripple < 25, "speed ripple \(m.ripple)%")
        #expect(abs(m.lagMs) < 80, "lag \(m.lagMs) ms")
    }

    // MARK: Reversals

    /// A hand's move: minimum-jerk between waypoints, each leg taking
    /// `leg` seconds, from `t0`.
    static func hand(_ waypoints: [Double], leg: Double, t0: Double = 0.3) -> (Double) -> Double {
        { t in
            let u = (t - t0) / leg
            guard u > 0 else { return waypoints[0] }
            let index = min(waypoints.count - 2, Int(u))
            let w = min(1, u - Double(index))
            let s = w * w * w * (10 - 15 * w + 6 * w * w)
            return waypoints[index] + (waypoints[index + 1] - waypoints[index]) * s
        }
    }

    @Test("open, close, open: the picture turns with the lid, rebounds by a few degrees at most, and settles")
    func reversals() throws {
        // 90° opens to 105°, closes to 60°, opens to 100°; 0.7 s a leg,
        // the way a hand moves it: speeding up out of each turn and
        // slowing into the next, 45° legs peaking near 120°/s.
        let waypoints = [90.0, 105, 60, 100]
        let truth = Self.hand(waypoints, leg: 0.7)
        let end = 0.3 + 0.7 * 3
        let frames = Self.replay(truth, duration: end + 1.5)
        let high = frames.map(\.shown).max() ?? 0
        let low = frames.map(\.shown).min() ?? 0
        #expect(high <= 105 + 3.2, "went \(high - 105)° past the top turn")
        #expect(low >= 60 - 2.0, "went \(60 - low)° past the bottom turn")
        // Mid-leg the picture only ever moves the way the lid does.
        for frame in frames {
            let legSpeed = (truth(frame.t + 0.005) - truth(frame.t - 0.005)) / 0.01
            if abs(legSpeed) > 40, frame.t > 0.8 {
                #expect(frame.velocity * legSpeed > 0, "moved against the lid at \(frame.t)")
            }
        }
        // It trails a hand's turn, never by more than a few frames' worth.
        let worst = frames.map { abs($0.shown - $0.truth) }.max() ?? 0
        #expect(worst < 14, "trailed the lid by \(worst)°")
        // The speed changes at the pace of the hand: a frame on which a
        // reading arrives late in a turn corrects it by tens of °/s, not
        // by the whole speed.
        for pair in zip(frames, frames.dropFirst()) {
            #expect(abs(pair.1.velocity - pair.0.velocity) < 90, "speed jumped at \(pair.1.t)")
        }
        // After the last stop it comes to rest on the lid, with at most a
        // couple of degrees of rebound on the way.
        let after = frames.filter { $0.t > end + 0.05 }
        #expect(after.allSatisfy { abs($0.shown - 100) < 2.0 }, "rebounded past 2°")
        let last = try #require(frames.last)
        #expect(abs(last.shown - 100) < 0.6, "settles on the lid: \(last.shown)")
    }

    @Test("a lid that stops lands on the stop and the picture follows it, ease-out or slam")
    func stopsLand() throws {
        for speed in [20.0, 60, 90] {
            let frames = Self.replay(Self.close(speed: speed), duration: 0.3 + 70 / speed + 1.5)
            let low = frames.map(\.shown).min() ?? 0
            // A slam can be carried a sensor period past its last reading
            // before the next reading says it stopped.
            #expect(low >= 40 - speed * 0.08, "\(speed)°/s overshot to \(low)")
            let end = try #require(frames.last)
            #expect(abs(end.shown - 40) < 0.6, "\(speed)°/s settled at \(end.shown)")
        }
    }

    // MARK: Rest

    @Test("a parked lid's one-degree flicker never moves the picture, and the motion comes to rest")
    func flickerAtRest() throws {
        var motion = FoldMotion()
        let dt = 1.0 / 120
        var shown: [Double] = []
        var t = 0.0
        var held = 0
        var restAt: Double?
        while t < 8 {
            if Int((t * 120).rounded()) % 12 == 0 {
                let reading = Int(t / 0.1) % 2 == 0 ? 100.0 : 101.0
                if !motion.feed(reading, at: t) { held += 1 }
            }
            _ = motion.tick(at: t, dt: dt)
            shown.append(motion.angle ?? 0)
            if restAt == nil, motion.atRest(at: t) { restAt = t }
            t += dt
        }
        #expect(motion.isParked)
        #expect(held > 40, "the guard held the flicker at the door (\(held))")
        let wobble = (shown.max() ?? 0) - (shown.min() ?? 0)
        #expect(wobble < 0.6, "the flicker moved the picture \(wobble)°")
        let rested = try #require(restAt, "the motion never came to rest")
        #expect(rested < 2.5, "and rest takes \(rested) s to arrive")
        // At rest the angle is exactly still.
        let tail = shown.suffix(240)
        #expect((tail.max() ?? 0) == (tail.min() ?? 0))
    }

    @Test("the first reading that cannot be flicker ends the rest")
    func leavingRest() {
        var motion = FoldMotion()
        let dt = 1.0 / 120
        var t = 0.0
        while t < 4 {
            if Int((t * 120).rounded()) % 12 == 0 {
                motion.feed(Int(t / 0.1) % 2 == 0 ? 100 : 101, at: t)
            }
            _ = motion.tick(at: t, dt: dt)
            t += dt
        }
        #expect(motion.isParked)
        let heldLow = motion.feed(100, at: t)
        let heldHigh = motion.feed(101, at: t + 0.1)
        let moved = motion.feed(99, at: t + 0.2)
        #expect(!heldLow && !heldHigh, "inside the flicker's own range: held")
        #expect(moved, "a degree past the range is a move")
        #expect(!motion.isParked)
    }

    @Test("a zero tolerance holds nothing")
    func zeroTolerance() {
        var motion = FoldMotion()
        motion.tolerance = 0
        var t = 0.0
        var held = 0
        for i in 0..<200 {
            if !motion.feed(i % 2 == 0 ? 100 : 101, at: t) { held += 1 }
            _ = motion.tick(at: t, dt: 0.01)
            t += 0.1
        }
        #expect(held == 0)
        #expect(!motion.isParked)
    }

    @Test("a slow close that outlasts the rest window still streams")
    func crawl() throws {
        // 2.5°/s: a degree every 0.4 s, so the lid sits inside one spot's
        // window long enough to park — and the very next reading breaks it.
        let frames = Self.replay(Self.close(speed: 2.5), duration: 20)
        let window = frames.filter { $0.t > 3 && $0.truth < 100 && $0.truth > 55 }
        try #require(window.count > 600)
        let lag = window.map { $0.shown - $0.truth }.reduce(0, +) / Double(window.count)
        #expect(abs(lag) < 1.5, "trailed by \(lag)°")
        var longest = 0, run = 0
        for frame in window {
            if abs(frame.velocity) < 0.3 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        #expect(longest < 90, "stood still for \(Double(longest) / 120) s mid-close")
    }

    // MARK: Direct and spring

    @Test("a slider change wakes motion before the next display tick")
    func directChangeWakesMotion() {
        var motion = FoldMotion()
        let dt = 1.0 / 120
        motion.feedDirect(110)
        _ = motion.tick(at: 0, dt: dt)
        #expect(motion.atRest(at: 1))

        motion.feedDirect(60)
        #expect(!motion.atRest(at: 1), "the stopped clock must see the pending slider target")
        let wanted = FoldTickPolicy.wantsTick(
            armed: true, targetDelta: 0, displayedDelta: 0,
            motionAtRest: motion.atRest(at: 1), easeAtRest: true,
            blackout: false, entryFading: false)
        #expect(wanted)
        _ = motion.tick(at: 1, dt: dt)
        #expect((motion.angle ?? 110) < 110)

        for frame in 1...240 { _ = motion.tick(at: 1 + Double(frame) * dt, dt: dt) }
        #expect(motion.angle == 60)
        #expect(motion.atRest(at: 3))
        motion.feedDirect(60)
        #expect(motion.atRest(at: 3), "an unchanged slider target needs no clock")
    }

    @Test("the slider and Try it go straight to the spring and rest on the value")
    func directPath() {
        var motion = FoldMotion()
        let dt = 1.0 / 120
        motion.feedDirect(100)
        var t = 0.0
        _ = motion.tick(at: t, dt: dt)
        #expect(motion.angle == 100)
        motion.feedDirect(60)
        var last = 100.0
        var settled: Double?
        while t < 3 {
            t += dt
            _ = motion.tick(at: t, dt: dt)
            let shown = motion.angle ?? 0
            #expect(shown >= 60 - 1e-9, "overshot the value at \(t)")
            #expect(shown <= last + 1e-9)
            last = shown
            if settled == nil, motion.atRest(at: t) { settled = t }
        }
        #expect(motion.angle == 60)
        #expect((settled ?? 9) < 1.0)
    }

    @Test("a critically damped step never overshoots and a stall is not a teleport")
    func springSteps() {
        var spring = FoldAngleSpring()
        spring.seat(100)
        for _ in 0..<600 {
            spring.tick(target: 40, rate: 0, dt: 1.0 / 120)
            #expect(spring.position >= 40 - 1e-9)
        }
        #expect(spring.position == 40 && spring.velocity == 0)
        // A huge dt clamps to a stall frame.
        var stalled = FoldAngleSpring()
        stalled.seat(100)
        stalled.tick(target: 40, rate: 0, dt: 5)
        #expect(stalled.position > 40 && stalled.position < 100)
        // Garbage cannot corrupt it.
        stalled.tick(target: .nan, rate: 0, dt: 0.01)
        stalled.tick(target: 40, rate: .infinity, dt: 0.01)
        stalled.tick(target: 40, rate: 0, dt: -1)
        #expect(stalled.position.isFinite && stalled.velocity.isFinite)
        // The speed cap holds.
        var capped = FoldAngleSpring()
        capped.seat(170)
        for _ in 0..<30 {
            let before = capped.position
            capped.tick(target: 0, rate: 0, dt: 1.0 / 120)
            #expect(before - capped.position <= capped.maxRate / 120 + 1e-9)
        }
    }

    @Test("a spring on a moving target follows its ramp with no lag")
    func springFollowsRamp() {
        var spring = FoldAngleSpring()
        let dt = 1.0 / 120
        spring.seat(100)
        var target = 100.0
        for _ in 0..<240 {
            target -= 30 * dt
            spring.tick(target: target, rate: -30, dt: dt)
        }
        #expect(abs(spring.position - target) < 1e-6, "trails by \(spring.position - target)°")
    }

    // MARK: The tracker

    @Test("a fast first step starts the lid at once and a one-degree step does not guess")
    func trackerLeavesRest() {
        var fast = FoldLidTracker()
        fast.seat(110, at: 0)
        fast.feed(104, at: 2)
        #expect(fast.rate < -40, "a six-degree first step is at least 50°/s: \(fast.rate)")
        var slow = FoldLidTracker()
        slow.seat(110, at: 0)
        slow.feed(109, at: 2)
        #expect(slow.rate == 0)
        #expect(abs(slow.position - 109.5) < 1e-9, "the half-degree between the readings")
        slow.feed(108, at: 2.2)
        #expect(abs(slow.rate + 5) < 1e-9, "two edges give a speed: \(slow.rate)")
    }

    @Test("a lid that stops is not carried past one sensor period, then eases back to the reading")
    func trackerStops() throws {
        var tracker = FoldLidTracker()
        tracker.seat(100, at: 0)
        for i in 1...6 { tracker.feed(100 - 9 * Double(i), at: 0.1 * Double(i)) }
        let last = 100 - 54.0
        let atEdge = try #require(tracker.sample(at: 0.6))
        #expect(atEdge.rate < -50)
        let carried = try #require(tracker.sample(at: 0.7))
        #expect(carried.angle < last, "dead-reckoned on")
        #expect(carried.angle >= last - 9.5, "by at most a period of travel")
        let later = try #require(tracker.sample(at: 1.5))
        #expect(later.rate == 0)
        #expect(abs(later.angle - last) < 0.01, "eased back to the reading")
        #expect(tracker.settled(at: 1.5))
        #expect(!tracker.settled(at: 0.7))
    }

    @Test("non-finite readings cannot corrupt the motion")
    func garbage() {
        var motion = FoldMotion()
        motion.feed(100, at: 0)
        let nan = motion.feed(.nan, at: 0.1)
        let late = motion.feed(90, at: .infinity)
        #expect(!nan && !late)
        _ = motion.tick(at: 0.2, dt: 0.01)
        #expect(motion.angle?.isFinite == true)
        #expect(motion.velocity.isFinite)
    }

    // MARK: Gate ease

    @Test("a growing target is followed in the same tick — closing never waits")
    func easeClosing() {
        var ease = FoldGateEase()
        #expect(ease.tick(target: 0.4, dt: 1.0 / 60) == 0.4)
        #expect(ease.tick(target: 0.9, dt: 1.0 / 60) == 0.9)
        #expect(ease.atRest)
    }

    @Test("a target that falls at the lid's own pace is followed exactly")
    func easeFollowsAnOpeningLid() {
        var ease = FoldGateEase()
        _ = ease.tick(target: 1.0, dt: 1.0 / 120)
        var target = 1.0
        let fastestLid = 240.0 * .pi / 180
        while target > 0 {
            target = max(0, target - fastestLid / 120)
            let shown = ease.tick(target: target, dt: 1.0 / 120)
            #expect(shown == target, "lagged an honest opening at \(target)")
        }
        #expect(ease.atRest)
    }

    @Test("a gate that snaps shut unwinds over a quarter second and lands exactly on zero")
    func easeSnap() throws {
        var ease = FoldGateEase()
        _ = ease.tick(target: 0.5, dt: 1.0 / 60)
        let dt = 1.0 / 120
        var t = 0.0
        var previous = ease.value
        var landed: Double?
        while t < 1 {
            let v = ease.tick(target: 0, dt: dt)
            #expect(v >= 0 && v <= previous + 1e-9, "not monotone at \(t)")
            if landed == nil, ease.atRest { landed = t }
            previous = v
            t += dt
        }
        let done = try #require(landed)
        #expect(done > 0.2 && done < 0.3, "landed after \(done) s")
        #expect(ease.value == 0)
        // It starts gently (no cut) and the bulk moves in the middle.
        var probe = FoldGateEase()
        _ = probe.tick(target: 0.5, dt: dt)
        let first = probe.tick(target: 0, dt: dt)
        #expect(first > 0.49, "the first frame barely moves: \(first)")
    }

    @Test("a snap to a smaller fold slews, and a target that comes back cancels a release")
    func easePartialAndCancel() {
        var ease = FoldGateEase()
        _ = ease.tick(target: 0.8, dt: 1.0 / 60)
        var previous = ease.value
        for _ in 0..<120 {
            let v = ease.tick(target: 0.3, dt: 1.0 / 60)
            #expect(v >= 0.3 - 1e-9 && v <= previous + 1e-9)
            previous = v
        }
        #expect(ease.value == 0.3 && ease.atRest)
        _ = ease.tick(target: 0, dt: 1.0 / 60)
        _ = ease.tick(target: 0, dt: 1.0 / 60)
        #expect(!ease.atRest)
        #expect(ease.tick(target: 0.6, dt: 1.0 / 60) == 0.6)
        #expect(ease.atRest)
        #expect(ease.tick(target: .nan, dt: 1.0 / 60) == 0.6)
        ease.reset()
        #expect(ease.value == 0 && ease.atRest)
    }

    // MARK: Entry fade

    @Test("a fold that comes into view mid-close fades in on the lid's travel, never faster than the lid")
    func entryFadeFollowsTheLid() {
        var fade = FoldEntryFade()
        let entry = 20.0 * .pi / 180
        fade.begin(delta: entry, at: 10)
        #expect(fade.active)
        #expect(fade.opacity(delta: entry, at: 10) == 0, "the first frame is the live desktop")
        // A fast lid: the travel finishes it long before the time floor.
        var fast = fade
        #expect(fast.opacity(delta: entry + 4 * .pi / 180, at: 10.01) > 0.4)
        #expect(fast.opacity(delta: entry + 9 * .pi / 180, at: 10.02) == 1)
        #expect(!fast.active, "done means gone")
        // A lid parked right there still gets its fold, after 0.2 s.
        var parked = fade
        let half = parked.opacity(delta: entry, at: 10.1)
        #expect(abs(half - 0.5) < 1e-9)
        #expect(parked.opacity(delta: entry, at: 10.2) == 1)
        #expect(!parked.active)
        #expect(parked.opacity(delta: entry, at: 10.3) == 1)
    }

    @Test("a fold that starts under two degrees needs no entry fade")
    func entryFadeThreshold() {
        var fade = FoldEntryFade()
        fade.begin(delta: 1.5 * .pi / 180, at: 3)
        #expect(!fade.active)
        fade.begin(delta: .nan, at: 3)
        #expect(!fade.active)
        #expect(fade.opacity(delta: 0.5, at: 3) == 1)
    }
}
