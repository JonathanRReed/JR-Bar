import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): the real
/// lid delta the held plane counter-rotates by, the edge tracker that
/// dead-reckons the 10 Hz hinge sensor, which sensor readings are worth
/// a redraw, and which safety input names the pause. `#expect` cannot
/// hold a mutating call, so the tracker's answers are collected first.
@Suite("Fold math")
struct FoldMathTests {
    @Test("at the reference angle the delta is zero — the overlay is pixel-identical")
    func atAnchor() {
        #expect(FoldMath.deltaRadians(angle: 82, reference: 82) == 0)
        #expect(FoldMath.deltaRadians(angle: 100, reference: 82) == 0,
                "above the reference there is no fold at all")
    }

    @Test("the delta is the real lid travel in radians, clamped at the stable arc")
    func deltaRange() {
        let ten = FoldMath.deltaRadians(angle: 72, reference: 82)
        #expect(abs(ten - 10 * .pi / 180) < 1e-9, "10° of travel is 10° of delta")
        #expect(abs(FoldMath.deltaRadians(angle: 60, reference: 82)
                    - 22 * .pi / 180) < 1e-9)
        // The clamp lands past ~71.6° of travel — 82° worth is over it.
        #expect(FoldMath.deltaRadians(angle: 0, reference: 82) == 1.25)
        #expect(FoldMath.deltaRadians(angle: 5, reference: 82) == 1.25)
        #expect(FoldMath.deltaRadians(angle: 20, reference: 82)
                > FoldMath.deltaRadians(angle: 70, reference: 82))
    }

    @Test("a nonsense angle or reference gives a zero delta rather than exploding")
    func nonFinite() {
        #expect(FoldMath.deltaRadians(angle: .nan, reference: 82) == 0)
        #expect(FoldMath.deltaRadians(angle: .infinity, reference: 82) == 0)
        #expect(FoldMath.deltaRadians(angle: 50, reference: .nan) == 0)
    }

    @Test("the activation gate reads the raw angle, at or below the limit")
    func activationGate() {
        #expect(FoldMath.allows(rawAngle: 82, activation: 82))
        #expect(FoldMath.allows(rawAngle: 60, activation: 82))
        #expect(!FoldMath.allows(rawAngle: 82.5, activation: 82))
        #expect(!FoldMath.allows(rawAngle: .nan, activation: 82))
    }

    @Test("the overlay only shows with a frame and a visible delta")
    func overlayGate() {
        #expect(FoldMath.showsOverlay(delta: 0.01, hasFrame: true))
        #expect(!FoldMath.showsOverlay(delta: 0.001, hasFrame: true),
                "aligned paints nothing")
        #expect(!FoldMath.showsOverlay(delta: 0.5, hasFrame: false),
                "no captured frame, no overlay")
    }

    @Test("the eased delta closes ~63% of the gap per 80 ms and snaps on bad input")
    func smoothing() {
        // The 80 ms time constant is the reference cadence: one τ in,
        // 1 − 1/e of the way there.
        let oneTau = FoldMath.smoothed(current: 0, target: 1, dt: 0.08)
        #expect(abs(oneTau - (1 - exp(-1))) < 1e-9)
        let stepped = FoldMath.smoothed(current: 0, target: 1, dt: 0.033)
        #expect(stepped > 0 && stepped < 1, "one tick moves partway")
        let more = FoldMath.smoothed(current: stepped, target: 1, dt: 0.5)
        #expect(abs(more - 1) < 0.01, "half a second lands on the target")
        #expect(FoldMath.smoothed(current: .nan, target: 1, dt: 0.1) == 1)
        #expect(FoldMath.smoothed(current: 0, target: 1, dt: 0) == 1)
    }

    // MARK: LidTracker

    /// The measured HID truth, synthetic: the lid-angle report is a
    /// 10 Hz integer-degree sensor — its value steps every ~100 ms and
    /// holds dead steady between steps. `truth` is where the lid really
    /// is; `sensor` is what the report says at poll time t. The sensor's
    /// refresh runs at its own 3 ms phase — a real report's cadence is
    /// never aligned to the poll timer.
    private func sensor(_ t: Double, truth: (Double) -> Double) -> Double {
        let phase = 0.003
        let tick = ((t - phase) / LidTracker.samplePeriod).rounded(.down)
        return truth(max(0, phase + tick * LidTracker.samplePeriod)).rounded()
    }

    @Test("the first sample primes the tracker at the measurement")
    func trackerPrime() {
        var tracker = LidTracker()
        tracker.feed(100, at: 10)
        #expect(tracker.renderAngle == 100)
        #expect(tracker.velocity == 0)
    }

    @Test("a 10 Hz staircase of a 60°/s close renders each edge and never leads the sensor")
    func tracksStaircase() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        let truth: (Double) -> Double = { 90 - 60 * $0 }
        for i in 0...240 {
            let t = Double(i) * poll
            let raw = sensor(t, truth: truth)
            tracker.feed(raw, at: t)
            tracker.tick(dt: poll, at: t)
            guard t > 0.3 else { continue }
            // The contract: the render angle IS the newest edge — never
            // ahead of the sensor (the old extrapolation's overshoot was
            // the fast-close judder), never behind it by more than the
            // sensor's own ~100 ms report latency plus a degree of
            // quantization.
            #expect(tracker.renderAngle == raw,
                    "render must be the last edge at t=\(t)")
            #expect(tracker.renderAngle >= truth(t) - 0.5,
                    "never ahead of the lid at t=\(t)")
            #expect(tracker.renderAngle - truth(t) < 8,
                    "lag stays inside the sensor's own latency at t=\(t)")
        }
    }

    @Test("0.3 s after the last edge the lid reads parked: velocity zero, render is the last raw")
    func trackerParks() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        let truth: (Double) -> Double = { 90 - 60 * $0 }
        for i in 0...60 {
            let t = Double(i) * poll
            tracker.feed(sensor(t, truth: truth), at: t)
            tracker.tick(dt: poll, at: t)
        }
        // The lid stops moving; the report holds at the last step and
        // every poll carries it unchanged for another 0.4 s.
        let parked = sensor(0.5, truth: truth)
        for i in 1...48 {
            let t = 0.5 + Double(i) * poll
            tracker.feed(parked, at: t)
            tracker.tick(dt: poll, at: t)
        }
        #expect(tracker.velocity == 0)
        #expect(tracker.renderAngle == parked, "parked renders the measurement exactly")
    }

    @Test("a reversal follows the new direction, still rendering only real edges")
    func trackerReversal() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        // Close at 60°/s for a second, then open at 60°/s.
        let truth: (Double) -> Double = { $0 <= 1 ? 90 - 60 * $0 : 30 + 60 * ($0 - 1) }
        for i in 0...240 {
            let t = Double(i) * poll
            let raw = sensor(t, truth: truth)
            tracker.feed(raw, at: t)
            tracker.tick(dt: poll, at: t)
            #expect(tracker.renderAngle == raw, "every render is an edge at t=\(t)")
            if t > 1.3 {
                // 0.3 s past the turn the estimate is with the new
                // direction.
                #expect(tracker.velocity > 0, "following the open by t=\(t)")
            }
        }
    }

    @Test("a one-degree-step crawl tracks within a degree and a half")
    func trackerSlowClose() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        let truth: (Double) -> Double = { 90 - 10 * $0 }
        for i in 0...240 {
            let t = Double(i) * poll
            tracker.feed(sensor(t, truth: truth), at: t)
            tracker.tick(dt: poll, at: t)
            guard t > 0.3 else { continue }
            #expect(abs(tracker.renderAngle - truth(t)) < 1.5,
                    "off the lid at t=\(t): \(tracker.renderAngle) vs \(truth(t))")
        }
    }

    @Test("a non-finite sample cannot corrupt the tracker")
    func trackerGarbage() {
        var tracker = LidTracker()
        tracker.feed(100, at: 0)
        tracker.feed(.nan, at: 1.0 / 60)
        tracker.feed(.infinity, at: 2.0 / 60)
        tracker.tick(dt: 1.0 / 60, at: 3.0 / 60)
        #expect(tracker.renderAngle.isFinite)
        #expect(tracker.velocity.isFinite)
    }

    @Test("an edge measured across a tiny dt cannot claim a slam")
    func trackerEdgeRateCap() {
        var tracker = LidTracker()
        tracker.feed(90, at: 0)
        // Two report values 30 ms apart: a real edge would carry ~2° of
        // travel, 11° is the timestamp's noise — the cap, not the
        // arithmetic, sets the velocity.
        tracker.feed(79, at: 0.03)
        #expect(abs(tracker.velocity) <= LidTracker.maxLidSpeed + 1e-9)
    }

    @Test("a wobble edge against the travel cannot flip the velocity's sign")
    func trackerWobbleReversal() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        let truth: (Double) -> Double = { 90 - 60 * $0 }
        for i in 0...60 {
            let t = Double(i) * poll
            tracker.feed(sensor(t, truth: truth), at: t)
            tracker.tick(dt: poll, at: t)
        }
        #expect(tracker.velocity < -LidTracker.reversalFloor,
                "a real close is moving at \(tracker.velocity)°/s")
        // A 1° upward wobble mid-close: slow enough to be noise.
        tracker.feed(sensor(0.5, truth: truth) + 1, at: 0.51)
        #expect(tracker.velocity < 0,
                "wobble does not reverse the estimate: \(tracker.velocity)")
        // A fast counter-edge is a real reversal — 60°/s the other way.
        tracker.feed(sensor(0.5, truth: truth) + 3, at: 0.56)
        #expect(tracker.velocity > 0, "a genuine lift reverses: \(tracker.velocity)")
    }

    // MARK: DeltaSpring

    @Test("the spring lands on the target and stays through it")
    func springSettles() {
        var spring = DeltaSpring()
        let dt = 1.0 / 120
        for _ in 0...240 { spring.tick(target: 0.8, dt: dt) }
        #expect(abs(spring.value - 0.8) < 0.01)
        #expect(abs(spring.velocity) < 0.01)
    }

    @Test("the spring never reports a negative delta")
    func springNoRingBelowZero() {
        var spring = DeltaSpring()
        let dt = 1.0 / 120
        for _ in 0...30 { spring.tick(target: 0.8, dt: dt) }
        // Gate shuts: the spring decays to zero and must not ring
        // through it — a negative delta would flick the overlay off
        // mid-exit.
        for _ in 0...240 {
            spring.tick(target: 0, dt: dt)
            #expect(spring.value >= 0, "delta went negative")
        }
        #expect(spring.atRest)
    }

    @Test("a slope step becomes acceleration, not a jump")
    func springAbsorbsEdgeStep() {
        var spring = DeltaSpring()
        let dt = 1.0 / 120
        // Ride a steadily rising target, then stop it dead — the
        // tracker's edge cadence, abstracted. The first-order ease
        // would lurch; the spring's largest single-frame move stays
        // under the rate a 60°/s close already shows.
        for _ in 0...60 { spring.tick(target: 0, dt: dt) }
        var t = 0.5
        var maxStep = 0.0
        var previous = spring.value
        for _ in 0...120 {
            t += dt
            spring.tick(target: t, dt: dt)
            maxStep = max(maxStep, abs(spring.value - previous))
            previous = spring.value
        }
        spring.tick(target: t, dt: dt)
        for _ in 0...60 {
            spring.tick(target: t, dt: dt)
            maxStep = max(maxStep, abs(spring.value - previous))
            previous = spring.value
        }
        #expect(maxStep < dt * 3,
                "no frame jumps after the target stalls: \(maxStep)")
        #expect(abs(spring.value - t) < 0.05, "and it catches up")
    }

    // MARK: Jitter

    @Test("the first reading always passes the jitter filter")
    func jitterFirstReading() {
        var filter = JitterFilter(tolerance: 2)
        let first = filter.accept(100, at: 0)
        #expect(first)
    }

    @Test("readings inside the tolerance are dropped, the edge passes")
    func jitterTolerance() {
        var filter = JitterFilter(tolerance: 2)
        var answers: [Bool] = []
        answers.append(filter.accept(100, at: 0))
        answers.append(filter.accept(101, at: 0.1))
        answers.append(filter.accept(98.5, at: 0.2))
        answers.append(filter.accept(102, at: 0.3))
        answers.append(filter.accept(100, at: 0.4))
        #expect(answers[0])
        #expect(!answers[1], "one degree of wobble is not a move")
        #expect(!answers[2])
        #expect(answers[3], "exactly the tolerance counts")
        #expect(answers[4], "mid-move every reading streams")
    }

    @Test("rejected readings do not move the anchor")
    func jitterBaseline() {
        var filter = JitterFilter(tolerance: 2)
        var answers: [Bool] = []
        answers.append(filter.accept(100, at: 0))
        answers.append(filter.accept(101, at: 0.1))
        answers.append(filter.accept(101.5, at: 0.2))
        answers.append(filter.accept(102, at: 0.3))
        #expect(answers == [true, false, false, true],
                "still measured against 100, not 101")
    }

    @Test("once moving, every degree streams until the lid rests")
    func jitterStreamsDuringMotion() {
        var filter = JitterFilter(tolerance: 5)
        var t = 0.0
        var answers: [Bool] = []
        // A real close on the probed sensor: whole degrees at ~10 Hz.
        for angle in stride(from: 91, through: 57, by: -1) {
            answers.append(filter.accept(Double(angle), at: t))
            t += 0.1
        }
        // First sample anchors; 90–87 sit inside the 5° deadband; 86
        // leaves it — and then EVERY step streams: no 5° stair-steps.
        #expect(answers[0])
        #expect(answers[1...4].allSatisfy { !$0 })
        #expect(answers[5...].allSatisfy { $0 },
                "after the deadband breaks, the close streams every edge")
    }

    @Test("the deadband re-arms after the lid rests")
    func jitterReArmsAtRest() {
        var filter = JitterFilter(tolerance: 5)
        var t = 0.0
        for angle in stride(from: 91, through: 60, by: -1) {
            _ = filter.accept(Double(angle), at: t)
            t += 0.1
        }
        // Lid parks at 60 for a beat; the settle reading lands (it is
        // the true rest angle) and the wobble after is noise again.
        t += 0.5
        let settle = filter.accept(61, at: t)
        let wobbleA = filter.accept(61.4, at: t + 0.1)
        let wobbleB = filter.accept(60.7, at: t + 0.2)
        #expect(settle, "the settle reading is real")
        #expect(!wobbleA, "re-anchored: sub-tolerance is noise")
        #expect(!wobbleB)
    }

    @Test("a zero tolerance accepts every reading")
    func jitterZero() {
        var filter = JitterFilter(tolerance: 0)
        var answers: [Bool] = []
        answers.append(filter.accept(100, at: 0))
        answers.append(filter.accept(100, at: 0.1))
        answers.append(filter.accept(100.001, at: 0.2))
        answers.append(filter.accept(99.999, at: 0.3))
        #expect(answers == [true, true, true, true])
    }

    @Test("reset makes the next reading a fresh baseline")
    func jitterReset() {
        var filter = JitterFilter(tolerance: 5)
        let first = filter.accept(100, at: 0)
        filter.reset()
        let afterReset = filter.accept(100.5, at: 0.1)
        #expect(first)
        #expect(afterReset, "after reset the first reading passes")
    }

    // MARK: Pause

    @Test("a clear machine gives no reason")
    func pauseNone() {
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == nil)
    }

    @Test("a lid reading at or under five degrees is closed")
    func pauseLidAngle() {
        #expect(FoldPause.reason(angle: 5, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == "lid closed")
        #expect(FoldPause.reason(angle: 0, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == "lid closed")
        #expect(FoldPause.reason(angle: 5.5, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == nil)
    }

    @Test("the daemon's closed-lid hold also means closed")
    func pauseClosedLid() {
        #expect(FoldPause.reason(angle: nil, closedLid: true, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == "lid closed")
    }

    @Test("no sensor reading means no lid-angle pause")
    func pauseNoAngle() {
        #expect(FoldPause.reason(angle: nil, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == nil)
    }

    @Test("each safety input names its own reason")
    func pauseEachReason() {
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: false,
                                 mirrored: false, screenAsleep: false) == "no built-in display")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: true, screenAsleep: false) == "display is mirrored")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: true) == "screen asleep")
    }

    @Test("the lid wins over the display reasons")
    func pausePrecedence() {
        #expect(FoldPause.reason(angle: 3, closedLid: false, builtInPresent: false,
                                 mirrored: true, screenAsleep: true) == "lid closed")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: false,
                                 mirrored: true, screenAsleep: true) == "no built-in display")
    }
}
