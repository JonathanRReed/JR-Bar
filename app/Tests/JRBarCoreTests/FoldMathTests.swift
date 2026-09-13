import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): how far the
/// desktop is folded for a lid angle, which sensor readings are worth a
/// redraw, and which safety input names the pause. `#expect` cannot hold
/// a mutating call, so the filter's answers are collected first.
@Suite("Fold math")
struct FoldMathTests {
    @Test("at or above the activation angle nothing is folded")
    func atActivation() {
        #expect(FoldMath.foldAmount(angle: 110, activation: 110) == 0)
        #expect(FoldMath.foldAmount(angle: 130, activation: 110) == 0)
    }

    @Test("the ramp is linear: twenty degrees below activation is half folded")
    func ramp() {
        #expect(FoldMath.foldAmount(angle: 90, activation: 110) == 0.5)
        #expect(FoldMath.foldAmount(angle: 100, activation: 110) == 0.25)
    }

    @Test("forty degrees below activation is fully folded, and further clamps")
    func fullFold() {
        #expect(FoldMath.foldAmount(angle: 70, activation: 110) == 1)
        #expect(FoldMath.foldAmount(angle: 0, activation: 110) == 1)
    }

    @Test("the activation angle moves the whole ramp")
    func movedActivation() {
        #expect(FoldMath.foldAmount(angle: 120, activation: 160) == 1)
        #expect(FoldMath.foldAmount(angle: 140, activation: 160) == 0.5)
        #expect(FoldMath.foldAmount(angle: 55, activation: 60) == 0.125)
    }

    @Test("a nonsense angle folds nothing rather than exploding")
    func nonFinite() {
        #expect(FoldMath.foldAmount(angle: .nan, activation: 110) == 0)
        #expect(FoldMath.foldAmount(angle: .infinity, activation: 110) == 0)
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
