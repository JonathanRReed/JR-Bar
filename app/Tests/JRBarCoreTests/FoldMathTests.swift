import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): the real
/// lid delta the held plane counter-rotates by, which sensor readings
/// are worth a redraw, and which safety input names the pause. The
/// motion pipeline itself — `SlewTracker`/`DeltaChase` — lives app-side
/// and is covered in FoldPortalTests.
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
