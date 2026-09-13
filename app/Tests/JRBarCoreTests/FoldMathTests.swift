import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): the radians
/// the lid has swung past its anchor, which sensor readings are worth a
/// redraw, and which safety input names the pause. `#expect` cannot hold
/// a mutating call, so the filter's answers are collected first.
@Suite("Fold math")
struct FoldMathTests {
    @Test("at the anchor the delta is zero — the overlay is pixel-identical")
    func atAnchor() {
        #expect(FoldMath.deltaRadians(angle: 110, activation: 110) == 0)
        #expect(FoldMath.foldAmount(angle: 110, activation: 110) == 0)
    }

    @Test("delta is positive past the anchor and grows with the swing")
    func deltaGrows() {
        let ten = FoldMath.deltaRadians(angle: 100, activation: 110)
        let forty = FoldMath.deltaRadians(angle: 70, activation: 110)
        #expect(abs(ten - 10 * .pi / 180) < 1e-9)
        #expect(abs(forty - 40 * .pi / 180) < 1e-9)
        #expect(FoldMath.foldAmount(angle: 100, activation: 110) > 0)
        #expect(FoldMath.foldAmount(angle: 70, activation: 110)
                > FoldMath.foldAmount(angle: 100, activation: 110))
    }

    @Test("the delta saturates past the range and negative swings are allowed a little")
    func deltaClamps() {
        #expect(FoldMath.deltaRadians(angle: 0, activation: 110) == 1.25)
        #expect(FoldMath.deltaRadians(angle: 160, activation: 110) == -0.65)
        #expect(FoldMath.deltaRadians(angle: 115, activation: 110) < 0)
    }

    @Test("a nonsense angle gives a zero delta rather than exploding")
    func nonFinite() {
        #expect(FoldMath.deltaRadians(angle: .nan, activation: 110) == 0)
        #expect(FoldMath.deltaRadians(angle: .infinity, activation: 110) == 0)
        #expect(FoldMath.foldAmount(angle: .nan, activation: 110) == 0)
    }

    @Test("the activation gate reads the raw angle, at or below the limit")
    func activationGate() {
        #expect(FoldMath.allows(rawAngle: 110, activation: 110))
        #expect(FoldMath.allows(rawAngle: 60, activation: 110))
        #expect(!FoldMath.allows(rawAngle: 110.5, activation: 110))
        #expect(!FoldMath.allows(rawAngle: .nan, activation: 110))
    }

    @Test("the overlay only shows with a frame and a visible tilt")
    func overlayGate() {
        #expect(FoldMath.showsOverlay(delta: 0.01, hasFrame: true))
        #expect(!FoldMath.showsOverlay(delta: 0.001, hasFrame: true),
                "aligned paints nothing")
        #expect(!FoldMath.showsOverlay(delta: 0.5, hasFrame: false),
                "no captured frame, no overlay")
    }

    @Test("the eased delta approaches its target and snaps on bad input")
    func smoothing() {
        let stepped = FoldMath.smoothed(current: 0, target: 1, dt: 0.033)
        #expect(stepped > 0 && stepped < 1, "one 30 Hz tick moves partway")
        let more = FoldMath.smoothed(current: stepped, target: 1, dt: 0.5)
        #expect(abs(more - 1) < 0.01, "half a second lands on the target")
        #expect(FoldMath.smoothed(current: .nan, target: 1, dt: 0.1) == 1)
        #expect(FoldMath.smoothed(current: 0, target: 1, dt: 0) == 1)
    }

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
