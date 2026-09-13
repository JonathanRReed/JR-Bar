import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): the real
/// lid delta the held plane counter-rotates by, the α–β predictor that
/// makes the fold lead the finger, which sensor readings are worth a
/// redraw, and which safety input names the pause. `#expect` cannot hold
/// a mutating call, so the predictor's answers are collected first.
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

    // MARK: AlphaBeta

    @Test("the first sample primes the predictor at the measurement")
    func predictorPrime() {
        var p = AlphaBeta()
        p.feed(100, at: 10)
        #expect(p.renderAngle == 100)
        #expect(p.velocity == 0)
    }

    @Test("while the lid swings the render angle leads the measurement, bounded")
    func predictorLeads() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        // Steady closing at ~60°/s, 60 Hz samples.
        for i in 1...20 { p.feed(100 - Double(i), at: Double(i) / 60) }
        #expect(p.renderAngle < 80, "closing leads downward")
        #expect(80 - p.renderAngle <= AlphaBeta.leadLimit + 1e-9,
                "the lead is clamped")
        #expect(p.velocity < -30, "the velocity estimate tracks the swing")
    }

    @Test("a parked lid renders the measurement exactly — no drift, no lead")
    func predictorParks() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        for i in 1...10 { p.feed(100 - Double(i) * 0.5, at: Double(i) / 60) }
        // The lid stops; stillness confirmed after stillConfirm.
        let stopAt = 10.0 / 60
        for i in 1...30 { p.feed(95, at: stopAt + Double(i) / 60) }
        #expect(p.renderAngle == 95, "stillness freezes the prediction")
        #expect(abs(p.velocity) < 1, "the velocity estimate settles to rest")
    }

    @Test("a reversal kills the lead instead of overshooting through it")
    func predictorReversal() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        for i in 1...20 { p.feed(100 - Double(i), at: Double(i) / 60) }
        // The lid turns around and opens — the render angle stays inside
        // the clamp the whole way, then rebuilds its lead in the new
        // direction instead of overshooting backward through the turn.
        for i in 1...10 {
            let raw = 80.0 + Double(i)
            p.feed(raw, at: (20 + Double(i)) / 60)
            #expect(abs(p.renderAngle - raw) <= AlphaBeta.leadLimit + 1e-9)
        }
        #expect(p.renderAngle > 90, "leading the new direction once it settles")
    }

    @Test("a stale feed decays the lead and the blur boost")
    func predictorStale() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        for i in 1...15 { p.feed(100 - Double(i), at: Double(i) / 60) }
        // The sensor goes quiet — two seconds of ticks must settle the
        // velocity estimate to rest.
        let quiet = 15.0 / 60
        for i in 1...120 { p.tick(dt: 1.0 / 60, at: quiet + Double(i) / 60) }
        #expect(abs(p.velocity) < 1, "the boost source dies with the feed")
    }

    @Test("a starved feed cannot leave the render angle led")
    func predictorStaleAngle() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        for i in 1...15 { p.feed(100 - Double(i), at: Double(i) / 60) }
        // The lid settles; the jitter filter now rejects every sample,
        // so `feed` never fires again. Ticks alone must walk the render
        // angle back to the last measurement (85°) — before the fix a
        // standing lead held forever, so a parked lid rendered ajar.
        let quiet = 15.0 / 60
        for i in 1...120 { p.tick(dt: 1.0 / 60, at: quiet + Double(i) / 60) }
        #expect(p.renderAngle == 85)
    }

    @Test("a non-finite sample cannot corrupt the predictor")
    func predictorGarbage() {
        var p = AlphaBeta()
        p.feed(100, at: 0)
        p.feed(.nan, at: 1.0 / 60)
        p.feed(.infinity, at: 2.0 / 60)
        p.feed(98, at: 3.0 / 60)
        #expect(p.renderAngle.isFinite)
        #expect(p.velocity.isFinite)
    }

    // MARK: Jitter

    @Test("the first reading always passes the jitter filter")
    func jitterFirstReading() {
        var filter = JitterFilter(tolerance: 2)
        let first = filter.accept(100)
        #expect(first)
    }

    @Test("readings inside the tolerance are dropped, the edge passes")
    func jitterTolerance() {
        var filter = JitterFilter(tolerance: 2)
        var answers: [Bool] = []
        answers.append(filter.accept(100))
        answers.append(filter.accept(101))
        answers.append(filter.accept(98.5))
        answers.append(filter.accept(102))
        answers.append(filter.accept(100))
        #expect(answers[0])
        #expect(!answers[1], "one degree of wobble is not a move")
        #expect(!answers[2])
        #expect(answers[3], "exactly the tolerance counts")
        #expect(answers[4], "two degrees from the new baseline")
    }

    @Test("rejected readings do not move the baseline")
    func jitterBaseline() {
        var filter = JitterFilter(tolerance: 2)
        var answers: [Bool] = []
        answers.append(filter.accept(100))
        answers.append(filter.accept(101))
        answers.append(filter.accept(101.5))
        answers.append(filter.accept(102))
        #expect(answers == [true, false, false, true],
                "still measured against 100, not 101")
    }

    @Test("a zero tolerance accepts every reading")
    func jitterZero() {
        var filter = JitterFilter(tolerance: 0)
        var answers: [Bool] = []
        answers.append(filter.accept(100))
        answers.append(filter.accept(100))
        answers.append(filter.accept(100.001))
        answers.append(filter.accept(99.999))
        #expect(answers == [true, true, true, true])
    }

    @Test("reset makes the next reading a fresh baseline")
    func jitterReset() {
        var filter = JitterFilter(tolerance: 5)
        let first = filter.accept(100)
        filter.reset()
        let afterReset = filter.accept(100.5)
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
