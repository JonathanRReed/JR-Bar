import Foundation
import Testing
@testable import JRBarCore

/// FoldMath is the pure half of the Fold toy (docs/TOYS.md): the real
/// lid delta the held plane counter-rotates by, which sensor readings
/// are worth a redraw, and which safety input names the pause. The
/// motion pipeline itself — `FoldMotion` — lives app-side and is
/// covered in FoldMotionTests.
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
