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

    @Test("a 10 Hz staircase of a steady 60°/s close is tracked within 3°, without sawtooth")
    func tracksStaircase() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        let truth: (Double) -> Double = { 90 - 60 * $0 }
        var previous = Double.nan
        var maxStep = 0.0
        for i in 0...240 {
            let t = Double(i) * poll
            tracker.feed(sensor(t, truth: truth), at: t)
            tracker.tick(dt: poll, at: t)
            guard t > 0.3 else { previous = tracker.renderAngle; continue }
            #expect(abs(tracker.renderAngle - truth(t)) < 3,
                    "off the lid at t=\(t): \(tracker.renderAngle) vs \(truth(t))")
            if previous.isFinite {
                maxStep = max(maxStep, abs(tracker.renderAngle - previous))
            }
            previous = tracker.renderAngle
        }
        // 60°/s at a 120 Hz render cadence is 0.5° a frame; slack covers
        // the residual the ease would absorb at each edge.
        #expect(maxStep < 1.2, "no frame ever jumps \(maxStep)°")
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

    @Test("a reversal never leads past the clamp and follows the new direction")
    func trackerReversal() {
        var tracker = LidTracker()
        let poll = 1.0 / 120
        // Close at 60°/s for a second, then open at 60°/s.
        let truth: (Double) -> Double = { $0 <= 1 ? 90 - 60 * $0 : 30 + 60 * ($0 - 1) }
        var lastRaw = 90.0
        for i in 0...240 {
            let t = Double(i) * poll
            let raw = sensor(t, truth: truth)
            tracker.feed(raw, at: t)
            tracker.tick(dt: poll, at: t)
            lastRaw = raw
            #expect(abs(tracker.renderAngle - lastRaw) <= LidTracker.leadLimit + 1e-9,
                    "the extrapolation stays inside its clamp at t=\(t)")
            if t > 1.3 {
                // 0.3 s past the turn the tracker is with the new
                // direction and close to the lid again.
                #expect(tracker.velocity > 0, "following the open by t=\(t)")
                #expect(abs(tracker.renderAngle - truth(t)) < 3,
                        "back on the lid at t=\(t): \(tracker.renderAngle) vs \(truth(t))")
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
