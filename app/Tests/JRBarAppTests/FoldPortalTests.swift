import CoreGraphics
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Portal fold's pure model (FoldPortal.swift): the movement anchor,
/// the arming machine that owns the capture streams' lifecycle, the
/// window-card depth bucketing, and the delta → shader-params map. (The
/// lid's motion has its own suite: FoldMotionTests.) No Metal, no HID,
/// no timers — every rule the renderer and toy follow is testable here.
@Suite("Fold portal model")
struct FoldPortalTests {

    // MARK: MoveAnchor — resting angle

    @Test("resting angle relearns a stationary lid with the parking timer off")
    func automaticRestWorksWithoutParkingTimer() {
        var anchor = MoveAnchor()
        anchor.parkAfter = 1
        _ = anchor.select(.movement, angle: 110, at: 0)
        anchor.feed(100, at: 0.1)
        anchor.feed(90, at: 0.2)
        anchor.feed(80, at: 0.3)
        for step in 1...9 {
            let angle = 80 + Double(step % 3) - 1
            let released = anchor.feed(angle, at: 0.3 + Double(step) * 0.1)
            #expect(!released)
        }
        let released = anchor.feed(80, at: 1.4)
        #expect(released)
        #expect(anchor.anchor == 80)
        #expect(!anchor.moving(80))
        anchor.feed(70, at: 1.5)
        #expect(anchor.moving(70))
        #expect(anchor.anchor == 80)
    }

    @Test("a parked lid's flicker never arms the capture; the second whole degree of a close does")
    func armsOnTheFirstMoveThatIsNotFlicker() {
        var anchor = MoveAnchor()
        anchor.armThreshold = 0.5
        _ = anchor.select(.movement, angle: 110, at: 0)
        var t = 0.0
        var armedByFlicker = false
        // Three seconds of 110/109 flicker: once the rest has settled, the
        // anchor follows it and nothing is "moving".
        for step in 1...30 {
            t = Double(step) * 0.1
            anchor.feed(step % 2 == 0 ? 110 : 109, at: t)
            if t > 0.5, anchor.moving(step % 2 == 0 ? 110 : 109) { armedByFlicker = true }
        }
        #expect(!armedByFlicker)
        // A close begins: the first degree is absorbed like any flicker,
        // the second is a move.
        t += 0.1
        anchor.feed(109, at: t)
        #expect(!anchor.moving(109), "one degree is flicker")
        t += 0.2
        anchor.feed(108, at: t)
        #expect(anchor.moving(108), "two degrees of travel arm the capture")
        // A fast close arms on its first reading.
        var fast = MoveAnchor()
        fast.armThreshold = 0.5
        _ = fast.select(.movement, angle: 110, at: 0)
        for step in 1...10 { fast.feed(110, at: Double(step) * 0.1) }
        fast.feed(101, at: 1.2)
        #expect(fast.moving(101))
        // Tilting the screen back arms nothing.
        var back = MoveAnchor()
        back.armThreshold = 0.5
        _ = back.select(.movement, angle: 110, at: 0)
        for step in 1...10 { back.feed(110, at: Double(step) * 0.1) }
        back.feed(120, at: 1.2)
        #expect(!back.moving(120))
    }

    @Test("a moving lid never starts a new resting fold halfway down")
    func automaticRestWaitsForStillness() {
        var anchor = MoveAnchor()
        anchor.parkAfter = 1
        _ = anchor.select(.movement, angle: 110, at: 0)
        for step in 1...30 {
            let released = anchor.feed(110 - Double(step) * 2, at: Double(step) * 0.1)
            #expect(!released)
        }
        #expect(anchor.anchor == 110)
    }

    @Test("a slow closing lid is motion rather than a new rest")
    func slowCloseDoesNotReseat() {
        var anchor = MoveAnchor()
        anchor.parkAfter = 1
        _ = anchor.select(.movement, angle: 110, at: 0)
        anchor.feed(100, at: 0.1)
        for step in 1...80 {
            let angle = 100 - floor(Double(step) * 0.2)
            let released = anchor.feed(angle, at: 0.1 + Double(step) * 0.1)
            #expect(!released)
        }
        #expect(anchor.anchor == 110)
    }

    @Test("one-degree sensor flicker does not keep a stationary lid folded")
    func automaticRestAcceptsUnevenSensorFlicker() {
        var anchor = MoveAnchor()
        anchor.tolerance = 1
        anchor.parkAfter = 1
        _ = anchor.select(.movement, angle: 110, at: 0)
        var released = false
        for step in 0...10 {
            let angle = step < 5 ? 80.0 : 79.0
            released = anchor.feed(angle, at: 0.1 + Double(step) * 0.1) || released
        }
        #expect(released)
        #expect(anchor.anchor == 79)
    }

    @Test("deep folds start their rest release gently too", arguments: [0.89, 0.91, 1.25])
    func deepRestReleaseEasesOut(delta: Double) {
        var ease = FoldGateEase()
        _ = ease.tick(target: delta, dt: 1.0 / 60)
        let first = ease.tick(target: 0, dt: 1.0 / 60)
        #expect(first > delta * 0.98)
        for _ in 0..<40 { ease.tick(target: 0, dt: 1.0 / 60) }
        #expect(ease.atRest)
        #expect(ease.value == 0)
    }

    @Test("sensor and display callbacks share elapsed time while the fold stays armed")
    func frameTimeSurvivesSensorReconciles() {
        var clock = FoldFrameClock()
        var spring = FoldAngleSpring()
        spring.seat(110)
        _ = clock.tick(at: 0)
        var elapsed = 0.0
        for step in 1...120 {
            let displayTime = Double(step) / 120
            let sampleTime = displayTime - 0.002
            let sensorStep = clock.tick(at: sampleTime)
            spring.tick(target: 80, rate: 0, dt: sensorStep)
            let displayStep = clock.tick(at: displayTime)
            spring.tick(target: 80, rate: 0, dt: displayStep)
            elapsed += sensorStep + displayStep
        }
        #expect(abs(elapsed - 1) < 1e-9)
        #expect(spring.position == 80 && spring.velocity == 0)
        clock.reset()
        let restarted = clock.tick(at: 20)
        #expect(restarted == 0)
    }

    @Test("a small rest release eases out instead of disappearing in two frames")
    func smallReleaseEasesOut() {
        var ease = FoldGateEase()
        _ = ease.tick(target: 6 * .pi / 180, dt: 1.0 / 60)
        let initial = ease.value
        let dt = 1.0 / 60
        let first = ease.tick(target: 0, dt: dt)
        #expect(first > initial * 0.98)
        for _ in 0..<4 { ease.tick(target: 0, dt: dt) }
        #expect(ease.value > initial * 0.7)
        for _ in 0..<30 { ease.tick(target: 0, dt: dt) }
        #expect(ease.value == 0)
        #expect(ease.atRest)
    }

    @Test("changing to movement mode folds from the parked reading on the first close")
    func movementModeUsesTheExistingRest() {
        var anchor = MoveAnchor()
        _ = anchor.select(.angle, angle: 110, at: 0)
        let changed = anchor.select(.movement, angle: 110, at: 1)
        #expect(changed)
        anchor.feed(100, at: 1.1)
        anchor.armThreshold = 3
        #expect(anchor.anchor == 110)
        #expect(anchor.moving(100))
        var arming = FoldArming()
        let result = arming.updateMovement(moving: anchor.moving(100), closed: false, now: 1.1)
        #expect(result.capture)
        #expect(result.foldGate)
        let unchanged = anchor.select(.movement, angle: 100, at: 1.2)
        #expect(!unchanged)
        #expect(anchor.anchor == 110, "a reconcile during the close keeps its reference")
    }

    @Test("returning to movement mode forgets its old reference")
    func movementModeReturnsToTheCurrentRest() {
        var anchor = MoveAnchor()
        _ = anchor.select(.movement, angle: 110, at: 0)
        anchor.feed(80, at: 0.1)
        _ = anchor.select(.angle, angle: 80, at: 0.2)
        _ = anchor.select(.movement, angle: 95, at: 2)
        #expect(anchor.anchor == 95)
        #expect(!anchor.moving(95))
        anchor.feed(85, at: 2.1)
        #expect(anchor.anchor == 95)
        #expect(anchor.moving(85))
    }

    // MARK: MoveAnchor

    @Test("the first sample seats the anchor; moving is the deviation off it")
    func anchorPrime() {
        var anchor = MoveAnchor()
        #expect(anchor.anchor == nil)
        #expect(!anchor.moving(90), "unanchored is not a move")
        anchor.feed(110, at: 0)
        #expect(anchor.anchor == 110)
        #expect(!anchor.moving(110.5), "inside the deadband is still")
        #expect(anchor.moving(108), "closing past it is the first move")
        #expect(anchor.moving(113), "opening counts too — the gate stays armed")
    }

    @Test("still in the flat zone for the settle window re-seats the anchor")
    func anchorSettles() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        // The lid opens past the anchor and rests at 130: inside the
        // settle window the anchor holds, past it the rest spot wins.
        anchor.feed(130, at: 0.1)
        #expect(anchor.anchor == 110, "moving — the anchor holds")
        anchor.feed(130, at: 0.45)
        #expect(anchor.anchor == 110, "0.35 s of stillness is not yet settled")
        anchor.feed(130, at: 0.55)
        #expect(anchor.anchor == 130, "0.4 s parked is the new rest")
        // Sensor wobble inside the tolerance doesn't reset the clock.
        anchor.feed(130.8, at: 0.6)
        anchor.feed(130.4, at: 0.7)
        #expect(anchor.anchor == 130 || anchor.anchor == 130.8
                || anchor.anchor == 130.4,
                "wobble stays in the flat zone: \(String(describing: anchor.anchor))")
    }

    @Test("a live fold freezes the anchor — parked mid-fold never re-seats")
    func anchorFrozenInFlight() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        // Close 20° and hold for seconds: the anchor stays at 110 —
        // re-anchoring here would collapse a held fold.
        for i in 1...20 {
            anchor.feed(90, at: Double(i) * 0.1)
            #expect(anchor.anchor == 110, "parked mid-fold at t=\(Double(i) * 0.1)")
        }
        #expect(anchor.moving(90), "a held fold counts as moving — the streams stay")
        // Open back through the anchor and rest at 120: after the
        // settle window the new rest spot becomes the reference.
        anchor.feed(120, at: 2.1)
        anchor.feed(120, at: 2.6)
        #expect(anchor.anchor == 120, "the opened rest spot re-seats")
    }

    @Test("the dwell pause re-seats the anchor at the parked angle")
    func anchorReseat() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        anchor.feed(80, at: 0.1)
        anchor.reseat(80, at: 2.0)
        #expect(anchor.anchor == 80)
        #expect(!anchor.moving(80.5), "the parked angle is the new rest")
    }

    @Test("a reopen that stops short of the old rest settles there after a second")
    func anchorReopenSettles() {
        var anchor = MoveAnchor()
        anchor.armThreshold = 3
        anchor.feed(110, at: 0)
        // Down to 60 and back up to 104, 6° short of where it rested.
        let gesture: [Double] = [100, 90, 80, 70, 60, 70, 80, 90, 100, 104]
        for (i, angle) in gesture.enumerated() {
            anchor.feed(angle, at: Double(i + 1) * 0.1)
        }
        #expect(anchor.anchor == 110, "still on the way up")
        #expect(anchor.moving(104), "the fold is still live")
        // Parked at 104 with the sensor's ±1° wobble.
        let stoppedAt = 1.0
        for i in 1...9 {
            let wobble = i % 2 == 0 ? 1.0 : -1.0
            anchor.feed(104 + wobble, at: stoppedAt + Double(i) * 0.1)
        }
        #expect(anchor.anchor == 110, "under a second parked is not yet a rest")
        for i in 10...12 {
            anchor.feed(104, at: stoppedAt + Double(i) * 0.1)
        }
        #expect(anchor.anchor == 104, "a second still is the new rest")
        #expect(!anchor.moving(104), "nothing left to fold, so the capture can stand down")
        #expect(anchor.moving(100.5), "and the next close folds from here")
    }

    @Test("a lid parked mid-close with no rise keeps its fold")
    func anchorParkedMidCloseHolds() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        anchor.feed(95, at: 0.1)
        // Parked at 80 for five seconds, wobbling a degree either way.
        for i in 0..<50 {
            anchor.feed(80 + Double(i % 3) - 1, at: 0.2 + Double(i) * 0.1)
        }
        #expect(anchor.anchor == 110, "wobble on a parked lid is not a reopen")
        #expect(anchor.moving(80))
    }

    @Test("part way up and back down to park is a new close, not a reopen")
    func anchorReopenThenCloseHolds() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        // Down to 70, back up to 95, down again to 85 and parked there
        // for three seconds.
        let close: [Double] = [90, 70, 80, 95, 90, 85] + Array(repeating: 85, count: 30)
        for (i, angle) in close.enumerated() {
            anchor.feed(angle, at: Double(i + 1) * 0.1)
        }
        #expect(anchor.anchor == 110, "parked at the bottom of the second close")
        // A real reopen from there still settles.
        let reopen: [Double] = [92] + Array(repeating: 100, count: 13)
        for (i, angle) in reopen.enumerated() {
            anchor.feed(angle, at: 4 + Double(i) * 0.1)
        }
        #expect(anchor.anchor == 100)
    }

    @Test("a reopen out of the closed hold settles short of the old rest too")
    func anchorReopenFromShut() {
        var anchor = MoveAnchor()
        anchor.feed(110, at: 0)
        let gesture: [Double] = [80, 40, 10, 3, 3, 3, 30, 70] + Array(repeating: 100, count: 13)
        for (i, angle) in gesture.enumerated() {
            anchor.feed(angle, at: Double(i + 1) * 0.1)
        }
        #expect(anchor.anchor == 100)
        #expect(!anchor.moving(100))
    }

    // MARK: FoldArming

    @Test("streams exist only inside the arming band and its cooldown")
    func armingBandLifecycle() {
        var arming = FoldArming()
        // Way above the band: nothing captured.
        var out = arming.update(angle: 120, activation: 82, closed: false, now: 0)
        #expect(!out.capture && arming.phase == .idle)
        // Inside the band (activation + 12° margin): both streams live.
        out = arming.update(angle: 90, activation: 82, closed: false, now: 1)
        #expect(out.capture && arming.phase == .armed)
        // Leaving the band upward starts the cooldown, not a cut.
        out = arming.update(angle: 120, activation: 82, closed: false, now: 2)
        #expect(out.capture && out.cooldownEndsAt == 4)
        // Re-entering cancels the cooldown — no restart, no flap.
        out = arming.update(angle: 90, activation: 82, closed: false, now: 3)
        #expect(out.capture && out.cooldownEndsAt == nil)
        // Back out; once the cooldown expires the streams die.
        _ = arming.update(angle: 120, activation: 82, closed: false, now: 4)
        out = arming.update(angle: 120, activation: 82, closed: false, now: 6.5)
        #expect(!out.capture && arming.phase == .idle)
    }

    @Test("a full close or the clamshell truth kills the streams at once")
    func armingLidShut() {
        var arming = FoldArming()
        _ = arming.update(angle: 90, activation: 82, closed: false, now: 0)
        var out = arming.update(angle: 4, activation: 82, closed: false, now: 0.1)
        #expect(!out.capture && arming.phase == .idle && !out.foldGate)
        _ = arming.update(angle: 90, activation: 82, closed: false, now: 1)
        out = arming.update(angle: 90, activation: 82, closed: true, now: 1.1)
        #expect(!out.capture && arming.phase == .idle)
        // A sensor with nothing to say is also idle.
        out = arming.update(angle: nil, activation: 82, closed: false, now: 2)
        #expect(!out.capture)
    }

    @Test("the fold gate opens at activation and closes a degree past it")
    func armingHysteresis() {
        var arming = FoldArming()
        var out = arming.update(angle: 82.5, activation: 82, closed: false, now: 0)
        #expect(!out.foldGate)
        out = arming.update(angle: 82, activation: 82, closed: false, now: 0.1)
        #expect(out.foldGate)
        // Inside the hysteresis band a wobble cannot flick the gate.
        out = arming.update(angle: 82.7, activation: 82, closed: false, now: 0.2)
        #expect(out.foldGate, "still inside hysteresis")
        out = arming.update(angle: 83.2, activation: 82, closed: false, now: 0.3)
        #expect(!out.foldGate, "past activation + 1° the gate shuts")
    }

    @Test("movement mode: still → armed on move → disarmed after cooldown → re-arm")
    func armingMovement() {
        var arming = FoldArming()
        // Parked at the anchor: nothing runs — the idle-power floor.
        var out = arming.updateMovement(moving: false, closed: false, now: 0)
        #expect(!out.capture && !out.foldGate && arming.phase == .idle)
        // The first move off the anchor arms both streams and opens
        // the gate in the same pass — the capture warm-up starts here.
        out = arming.updateMovement(moving: true, closed: false, now: 0.1)
        #expect(out.capture && out.foldGate && arming.phase == .armed)
        // A held fold keeps reporting "moving" (the deviation from the
        // anchor persists), so parking mid-fold never cools the streams.
        out = arming.updateMovement(moving: true, closed: false, now: 1.0)
        #expect(out.capture && arming.phase == .armed)
        // Back at rest (unfolded home, anchor re-seated): the cooldown
        // starts, the gate stays open through it.
        out = arming.updateMovement(moving: false, closed: false, now: 1.1)
        #expect(out.capture && arming.phase == .cooling(until: 1.1 + arming.cooldown))
        #expect(out.cooldownEndsAt == 1.1 + arming.cooldown)
        #expect(out.foldGate, "a cooling fold stays drawable")
        // A move during cooldown re-arms without a restart.
        out = arming.updateMovement(moving: true, closed: false, now: 1.4)
        #expect(out.capture && arming.phase == .armed)
        // Still past the cooldown's end: the streams die — both
        // SCStreams stop and the poll idles at 10 Hz.
        _ = arming.updateMovement(moving: false, closed: false, now: 1.5)
        out = arming.updateMovement(moving: false, closed: false, now: 4.0)
        #expect(!out.capture && !out.foldGate && arming.phase == .idle)
        // The next move re-arms from scratch.
        out = arming.updateMovement(moving: true, closed: false, now: 4.1)
        #expect(out.capture && arming.phase == .armed)
        // And a full close kills it at once, mid-move or not.
        out = arming.updateMovement(moving: true, closed: true, now: 4.2)
        #expect(!out.capture && !out.foldGate && arming.phase == .idle)
    }

    @Test("the same angle draws the same image — opening retraces closing exactly")
    func retracePalindrome() {
        // The toy's own chain: angle → spring → delta → gate ease → the
        // shader's image params (opacity and dissolve ride the displayed
        // delta). Feed the symmetric 110 → 60 → 110 path and let each
        // held angle settle; the image at each angle must be a
        // palindrome — the same angle, the same picture.
        var motion = FoldMotion()
        var ease = FoldGateEase()
        let dt = 1.0 / 120
        var now = 0.0
        motion.feedDirect(110)
        motion.tick(at: now, dt: dt)
        func image(at angle: Double) -> (Double, Double, Double) {
            motion.feedDirect(angle)
            var shown = 0.0
            for _ in 0..<600 {
                now += dt
                let drawn = motion.tick(at: now, dt: dt) ?? angle
                let target = FoldMath.deltaRadians(angle: drawn, reference: 110)
                shown = ease.tick(target: target, dt: dt)
                if motion.atRest(at: now) && ease.atRest { break }
            }
            return (shown, FoldPortalModel.opacity(delta: shown),
                    FoldPortalModel.dissolve(delta: shown))
        }
        var series: [(Double, Double, Double)] = []
        for a in stride(from: 110.0, through: 60, by: -10) {
            series.append(image(at: a))
        }
        for a in stride(from: 70.0, through: 110, by: 10) {
            series.append(image(at: a))
        }
        for i in 0..<series.count {
            let j = series.count - 1 - i
            #expect(abs(series[i].0 - series[j].0) < 1e-3,
                    "delta at index \(i) vs \(j): \(series[i].0) vs \(series[j].0)")
            #expect(abs(series[i].1 - series[j].1) < 1e-3,
                    "opacity differs at the mirrored angle")
            #expect(abs(series[i].2 - series[j].2) < 1e-3,
                    "dissolve differs at the mirrored angle")
        }
        // The transient a rate-limited unwind would lose: during a real
        // opening the displayed delta sits on the target every frame —
        // the spring's own cap is under the ease's follow rate, so
        // mid-flight angles draw the same image too.
        var opening = FoldMotion()
        var follow = FoldGateEase()
        var clock = 0.0
        opening.feedDirect(60)
        opening.tick(at: clock, dt: dt)
        _ = follow.tick(target: FoldMath.deltaRadians(angle: 60, reference: 110), dt: dt)
        opening.feedDirect(110)
        for _ in 0..<600 {
            clock += dt
            let drawn = opening.tick(at: clock, dt: dt) ?? 110
            let target = FoldMath.deltaRadians(angle: drawn, reference: 110)
            _ = follow.tick(target: target, dt: dt)
            #expect(abs(follow.value - target) < 1e-3,
                    "the opening path must retrace the closing one")
            if opening.atRest(at: clock) && follow.atRest { break }
        }
    }

    // MARK: PortalDepth

    private func window(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                        layer: Int = 0, pid: Int32 = 42, alpha: Double = 1)
        -> PortalDepth.WindowInfo {
        PortalDepth.WindowInfo(rect: CGRect(x: x, y: y, width: w, height: h),
                               layer: layer, ownerPID: pid, alpha: alpha)
    }

    @Test("only normal, visible, other people's windows become cards")
    func cardFiltering() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rects = PortalDepth.cardRects(from: [
            window(100, 100, 400, 300),                    // a real window
            window(0, 0, 1000, 24, layer: 25),             // menu bar — chrome
            window(50, 50, 200, 200, pid: 7),              // us — fold can't see itself
            window(50, 50, 200, 200, alpha: 0),            // hidden
            window(10, 10, 10, 10),                        // too small to matter
        ], displayFrame: display, ownPID: 7)
        #expect(rects.count == 1)
        #expect(rects[0] == CGRect(x: 0.1, y: 0.125, width: 0.4, height: 0.375))
    }

    @Test("cards clip to the display and cap at maxWindows")
    func cardClipping() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var windows: [PortalDepth.WindowInfo] = [
            window(900, 700, 400, 300),   // half off the bottom-right
        ]
        for i in 0..<20 { windows.append(window(10 + Double(i), 10, 100, 100)) }
        let rects = PortalDepth.cardRects(from: windows, displayFrame: display, ownPID: 7)
        #expect(rects.count == PortalDepth.maxWindows)
        let clipped = rects[0]
        #expect(clipped.maxX <= 1.0 && clipped.maxY <= 1.0)
        #expect(abs(clipped.minX - 0.9) < 1e-9 && abs(clipped.minY - 0.875) < 1e-9)
    }

    @Test("the frontmost windows take the nearest buckets")
    func cardBuckets() {
        let rects = (0..<9).map { CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
            .offsetBy(dx: Double($0) * 0.01, dy: 0) }
        let cards = PortalDepth.cards(for: rects)
        #expect(cards.count == 9)
        #expect(cards[0].bucket == 0, "frontmost sits nearest the glass")
        #expect(cards.last!.bucket == PortalDepth.bucketCount - 1)
        // Buckets are non-decreasing in z-order.
        for pair in zip(cards, cards.dropFirst()) {
            #expect(pair.1.bucket >= pair.0.bucket)
        }
    }

    // MARK: FoldPortalModel

    @Test("the activation fade ramps over fadeSpan of delta")
    func opacityRamp() {
        #expect(FoldPortalModel.opacity(delta: 0) == 0)
        #expect(FoldPortalModel.opacity(delta: FoldPortalModel.fadeSpan) == 1)
        #expect(FoldPortalModel.opacity(delta: 1) == 1)
        let mid = FoldPortalModel.opacity(delta: FoldPortalModel.fadeSpan / 2)
        #expect(mid > 0 && mid < 1)
    }

    @Test("the dissolve to black owns the last stretch of travel")
    func dissolve() {
        let start = FoldPortalModel.dissolveStart * FoldPortalModel.maxDelta
        #expect(FoldPortalModel.dissolve(delta: start) == 0)
        #expect(FoldPortalModel.dissolve(delta: FoldPortalModel.maxDelta) == 1)
        #expect(FoldPortalModel.dissolve(delta: 0) == 0)
        // Monotone through the dissolve band — the gesture reverses exactly.
        var last = 0.0
        for i in 0...20 {
            let d = FoldPortalModel.dissolve(delta: start
                + Double(i) / 20 * (FoldPortalModel.maxDelta - start))
            #expect(d >= last)
            last = d
        }
    }

    @Test("params map the knobs, the room and the reduce-motion mode")
    func params() {
        let p = FoldPortalModel.params(delta: 0.5, perspective: 0.8, blur: 0.4,
                                       shade: 0.6, frost: 0.65, usedBuckets: 2,
                                       reduceMotion: false)
        #expect(p.delta == 0.5)
        #expect(abs(p.persp - 0.8) < 1e-6)
        #expect(abs(p.blurStrength - 0.4) < 1e-6)
        #expect(abs(p.frost - 0.65) < 1e-6)
        #expect(p.bucketCount == 2)
        #expect(p.mode == 0)
        #expect(abs(p.depths[0] - Float(PortalDepth.bucketFractions[0] * FoldPortalModel.roomDepth)) < 1e-6)
        let rm = FoldPortalModel.params(delta: 0.5, perspective: 0.8, blur: 0.4,
                                        shade: 0.6, frost: 0.65, usedBuckets: 99,
                                        reduceMotion: true)
        #expect(rm.mode == 1, "Reduce Motion is the flat-dim crossfade")
        #expect(rm.bucketCount == Float(PortalDepth.bucketCount), "bucket count clamps")
    }

    @Test("the Blur slider maps straight into the shader's blurStrength")
    func blurUniformMapping() {
        // The portal has one style — blur is a knob, not a preset — so
        // the settings value must reach `blurStrength` un-gated, just
        // clamped to the 0...1 the shader expects.
        let half = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                          shade: 0.7, frost: 0.65, usedBuckets: 0,
                                          reduceMotion: false)
        #expect(abs(half.blurStrength - 0.5) < 1e-6)
        let over = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 2.0,
                                          shade: 0.7, frost: 0.65, usedBuckets: 0,
                                          reduceMotion: false)
        #expect(over.blurStrength == 1.0, "blur clamps at full defocus")
        let under = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: -0.5,
                                           shade: 0.7, frost: 0.65, usedBuckets: 0,
                                           reduceMotion: false)
        #expect(under.blurStrength == 0, "blur never goes negative")
    }

    @Test("the Frost slider maps straight into the shader's frost uniform")
    func frostUniformMapping() {
        // Frost is a knob like the others — the settings value must
        // reach `frost` un-gated, just clamped to the 0...1 the shader
        // expects.
        let half = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                          shade: 0.7, frost: 0.5, usedBuckets: 0,
                                          reduceMotion: false)
        #expect(abs(half.frost - 0.5) < 1e-6)
        let over = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                          shade: 0.7, frost: 2.0, usedBuckets: 0,
                                          reduceMotion: false)
        #expect(over.frost == 1.0, "frost clamps at fully milky")
        let under = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                           shade: 0.7, frost: -0.5, usedBuckets: 0,
                                           reduceMotion: false)
        #expect(under.frost == 0, "frost never goes negative")
    }

    @Test("Reduce Motion still carries the frost lift")
    func frostUnderReduceMotion() {
        // The flat-dim path applies the same diffusion — the cover is
        // frosted plastic whether or not the room tilts.
        let rm = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                        shade: 0.7, frost: 0.8, usedBuckets: 0,
                                        reduceMotion: true)
        #expect(rm.mode == 1)
        #expect(abs(rm.frost - 0.8) < 1e-6, "frost reaches the flat-dim shader path")
    }

    @Test("apply rewrites only the animatable fields, not the upload's")
    func applyPreservesRendererFields() {
        // The toy calls apply every vsync; the capture upload's
        // imageSize/texAspect and the encoder's cover/aspect must
        // survive — a wholesale params swap reset them every frame.
        var p = FoldRenderer.Params()
        p.imageSize = .init(2560, 1600)
        p.texAspect = 1.6
        p.cover = .init(1.25, 1.0)
        p.aspect = 1.7
        FoldPortalModel.apply(to: &p, delta: 0.5, perspective: 0.8, blur: 0.4,
                              shade: 0.6, frost: 0.65, usedBuckets: 2,
                              reduceMotion: false)
        #expect(p.imageSize == SIMD2<Float>(2560, 1600), "the upload's size survives the tick")
        #expect(p.texAspect == 1.6)
        #expect(p.cover == SIMD2<Float>(1.25, 1.0))
        #expect(p.aspect == 1.7)
        #expect(abs(p.blurStrength - 0.4) < 1e-6)
        #expect(p.delta == 0.5)
    }

    @Test("the Hold slider reaches the Room shader as it reads, not tied to Perspective")
    func holdMapping() {
        // 1 is the front-view hold, 0 the picture glued to the glass; the
        // old switch sent `perspective` when on, so a 40 % Perspective
        // quietly held the picture only 40 % of the way.
        let held = FoldPortalModel.params(delta: 0.5, perspective: 0.4, blur: 0.5,
                                          shade: 0.7, frost: 0, hold: 1,
                                          usedBuckets: 0, reduceMotion: false)
        #expect(held.hold == 1)
        let riding = FoldPortalModel.params(delta: 0.5, perspective: 0.4, blur: 0.5,
                                            shade: 0.7, frost: 0, hold: 0,
                                            usedBuckets: 0, reduceMotion: false)
        #expect(riding.hold == 0)
        let part = FoldPortalModel.params(delta: 0.5, perspective: 0.9, blur: 0.5,
                                          shade: 0.7, frost: 0, hold: 0.8,
                                          usedBuckets: 0, reduceMotion: false)
        #expect(abs(part.hold - 0.8) < 1e-6, "the hold no longer follows Perspective")
        let wild = FoldPortalModel.params(delta: 0.5, perspective: 0.6, blur: 0.5,
                                          shade: 0.7, frost: 0, hold: 3,
                                          usedBuckets: 0, reduceMotion: false)
        #expect(wild.hold == 1, "the hold clamps")
    }

    @Test("the Duo arms on 3° of travel down, so a nudge or a wider tilt never starts the capture")
    func anchorArmThreshold() {
        var anchor = MoveAnchor()
        anchor.feed(105, at: 0)
        anchor.armThreshold = 3
        #expect(!anchor.moving(103), "a 2° nudge is not a fold")
        #expect(!anchor.moving(102.5))
        #expect(anchor.moving(101.5))
        #expect(!anchor.moving(108.5), "opening wider never records")
        #expect(!anchor.moving(140), "nor does tilting the screen right back")
        anchor.armThreshold = nil
        #expect(anchor.moving(103), "without it the stillness deadband arms, as before")
        #expect(anchor.moving(108.5), "and the Room still arms either way off the anchor")
    }
}
