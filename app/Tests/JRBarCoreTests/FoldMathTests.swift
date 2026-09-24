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

    @Test("a lid parked on a steady 10 Hz 100↔101 flicker re-arms after a real move")
    func jitterReArmsOnSteadyFlicker() {
        // The live pump publishes every 100 ms whether the angle moved
        // or not — rest is never a gap in the samples. After a real
        // move the lid parks on the sensor's whole-degree flicker; that
        // must stop at the deadband again, not stream into the tracker
        // (and wake the fold's display link) for as long as it sits.
        var filter = JitterFilter(tolerance: 1.5)
        var t = 0.0
        var move: [Bool] = []
        for angle in stride(from: 110, through: 100, by: -1) {
            move.append(filter.accept(Double(angle), at: t))
            t += 0.1
        }
        #expect(move[0])
        #expect(!move[1], "one degree is inside the deadband")
        #expect(move[2...].allSatisfy { $0 }, "the move streams every edge")

        var parked: [Bool] = []
        for i in 0..<30 {
            parked.append(filter.accept(i % 2 == 0 ? 101 : 100, at: t))
            t += 0.1
        }
        #expect(parked[0...1].allSatisfy { $0 },
                "rest has to hold a third of a second before it counts")
        #expect(parked[4...].allSatisfy { !$0 },
                "parked: the flicker is noise again, three seconds of it")

        let next = filter.accept(98, at: t)
        #expect(next, "a real move still breaks the re-armed deadband")
    }

    /// A close at `degreesPerSecond` as the live pump sees it: the sensor
    /// drops a whole degree at a time and every 100 ms poll publishes
    /// whatever it reads, changed or not. Returns each reading and
    /// whether the filter let it through.
    private func polledClose(degreesPerSecond: Int, tolerance: Double)
        -> [(angle: Double, accepted: Bool)] {
        var filter = JitterFilter(tolerance: tolerance)
        return (0..<80).map { poll in
            // Integer maths for the angle so no float floor can shift
            // an edge by a poll.
            let angle = Double(91 - poll * degreesPerSecond / 10)
            return (angle, filter.accept(angle, at: Double(poll) / 10))
        }
    }

    @Test("a close slower than ~6.7°/s re-arms partway and steps by the tolerance")
    func jitterSlowCloseSteps() throws {
        // The known trade `restAfter` documents: R and R−1 both sit in
        // the rest window, and at 4°/s the lid reads them for half a
        // second — past restAfter — so the filter calls it parked
        // mid-close. What reaches the tracker after that is a
        // tolerance-sized jump, not the next degree.
        let tolerance = 5.0
        let close = polledClose(degreesPerSecond: 4, tolerance: tolerance)
        let moved = try #require(close.indices.dropFirst().first { close[$0].accepted },
                                 "the close leaves the deadband")
        let rejected = try #require(close.indices.first { $0 > moved && !close[$0].accepted },
                                    "a reading mid-close is dropped: the filter re-armed")
        // Everything from the deadband exit to here streamed, so the
        // reading just before the first rejection is the one it re-armed
        // on — the new anchor.
        let anchor = close[rejected - 1].angle
        let next = try #require(close.indices.first { $0 > rejected && close[$0].accepted },
                                "the re-armed deadband breaks again further down")
        #expect(anchor - close[next].angle >= tolerance,
                "the first reading through is a full tolerance on — a stair-step")
        #expect(close[rejected..<next].allSatisfy { anchor - $0.angle < tolerance })

        // Just over the line the same close streams every edge: the lid
        // leaves the two-degree window before restAfter runs out.
        let brisk = polledClose(degreesPerSecond: 7, tolerance: tolerance)
        let briskMoved = try #require(brisk.indices.dropFirst().first { brisk[$0].accepted })
        #expect(brisk[briskMoved...].allSatisfy { $0.accepted },
                "at 7°/s nothing mid-close is mistaken for rest")
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

    @Test("a locked screen and a switched-away session pause the fold")
    func pauseLockAndSession() {
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false,
                                 screenLocked: true) == "screen locked")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false,
                                 sessionInactive: true) == "another user is signed in")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false,
                                 screenLocked: false, sessionInactive: false) == nil)
    }

    @Test("a sleeping screen names itself before the lock behind it")
    func pauseLockPrecedence() {
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: true,
                                 screenLocked: true, sessionInactive: true) == "screen asleep")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false,
                                 screenLocked: true, sessionInactive: true) == "screen locked")
        #expect(FoldPause.reason(angle: 4, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false,
                                 screenLocked: true) == "lid closed")
    }

    // MARK: Try it

    @Test("the demo folds below the reference and comes back to where it started")
    func tryItScript() {
        let start = FoldTryIt.startAngle(current: 110, reference: 65)
        #expect(start == 110)
        #expect(FoldTryIt.angle(at: 0, start: start, reference: 65) == 110)
        let bottom = FoldTryIt.angle(at: FoldTryIt.closeDuration + 0.1, start: start, reference: 65)
        #expect(bottom == 65 - FoldTryIt.depth)
        #expect(FoldMath.deltaRadians(angle: bottom ?? 0, reference: 65) > 0.5, "a real fold")
        let end = FoldTryIt.angle(at: FoldTryIt.totalDuration, start: start, reference: 65)
        #expect(abs((end ?? 0) - 110) < 1e-9)
        #expect(FoldTryIt.angle(at: FoldTryIt.totalDuration + 0.01, start: start, reference: 65) == nil)
        #expect(FoldTryIt.angle(at: -0.1, start: start, reference: 65) == nil)
    }

    @Test("from a resting lid the demo starts where the lid rests and folds 50° below it")
    func tryItFromRest() {
        // The Duo's default: the reference is where the lid rests, not the
        // stored activation angle — a 105° rest folds to 55°, not 27°.
        let start = FoldTryIt.startAngle(current: 105, reference: 105, lead: 0)
        #expect(start == 105, "no lead: the resting fold starts with the first move")
        let bottom = FoldTryIt.angle(at: FoldTryIt.closeDuration, start: start, reference: 105)
        #expect(bottom == 55)
        #expect(FoldTryIt.bottomAngle(reference: 105) == 105 - FoldTryIt.depth)
        // A lid a hair below its anchor still starts from the anchor.
        #expect(FoldTryIt.startAngle(current: 103, reference: 105, lead: 0) == 105)
        #expect(FoldTryIt.startAngle(current: 103, reference: 105, lead: -4) == 105, "a lead never goes negative")
    }

    @Test("the demo's close only ever goes down, and its reopen only up")
    func tryItIsMonotonic() {
        var last = Double.infinity
        for step in 0...60 {
            let t = FoldTryIt.closeDuration * Double(step) / 60
            let a = FoldTryIt.angle(at: t, start: 120, reference: 90) ?? .nan
            #expect(a <= last + 1e-9)
            last = a
        }
        let reopenStart = FoldTryIt.closeDuration + FoldTryIt.holdDuration
        last = -.infinity
        for step in 0...60 {
            let t = reopenStart + FoldTryIt.openDuration * Double(step) / 60
            let a = FoldTryIt.angle(at: t, start: 120, reference: 90) ?? .nan
            #expect(a >= last - 1e-9)
            last = a
        }
    }

    @Test("the demo starts above the fold and never reaches the shut-lid pause")
    func tryItBounds() {
        #expect(FoldTryIt.startAngle(current: nil, reference: 65) == 110)
        #expect(FoldTryIt.startAngle(current: 60, reference: 65) == 73, "a lid already folding starts just above")
        #expect(FoldTryIt.startAngle(current: .nan, reference: 150) == 158)
        #expect(FoldTryIt.bottomAngle(reference: 30) > FoldPause.closedAngle)
        let lowest = FoldTryIt.angle(at: FoldTryIt.closeDuration, start: 80, reference: 30)
        #expect(FoldPause.reason(angle: lowest, closedLid: false, builtInPresent: true,
                                 mirrored: false, screenAsleep: false) == nil)
    }

    @Test("the lid wins over the display reasons")
    func pausePrecedence() {
        #expect(FoldPause.reason(angle: 3, closedLid: false, builtInPresent: false,
                                 mirrored: true, screenAsleep: true) == "lid closed")
        #expect(FoldPause.reason(angle: 90, closedLid: false, builtInPresent: false,
                                 mirrored: true, screenAsleep: true) == "no built-in display")
    }
}
