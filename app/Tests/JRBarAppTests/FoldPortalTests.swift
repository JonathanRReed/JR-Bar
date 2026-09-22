import CoreGraphics
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Portal fold's pure model (FoldPortal.swift): the slew-limited
/// tracker that turns the 10 Hz integer-degree hinge sensor into a
/// glide, the arming machine that owns the capture streams' lifecycle,
/// the unwind chase that turns a gate-close snap into a counter-
/// rotation, the window-card depth bucketing, and the delta →
/// shader-params map. No Metal, no HID, no timers — every rule the
/// renderer and toy follow is testable here.
@Suite("Fold portal model")
struct FoldPortalTests {

    // MARK: SlewTracker

    @Test("the first sample primes the tracker at the measurement")
    func trackerPrime() {
        var tracker = SlewTracker()
        tracker.feed(100)
        #expect(tracker.primed)
        #expect(tracker.angle == 100)
        #expect(tracker.velocity == 0)
        #expect(tracker.atRest, "primed at the measurement is already parked")
    }

    @Test("a slammed lid glides shut at the rate cap and never overshoots")
    func trackerSlam() {
        var tracker = SlewTracker()
        tracker.feed(90)
        tracker.feed(30)   // a 60° slam between samples
        let dt = 1.0 / 120
        var t = 0.0
        var previous = tracker.angle
        var maxStep = 0.0
        while t < 1.0 {
            tracker.tick(dt: dt)
            #expect(tracker.angle >= 30, "overshot the target at t=\(t): \(tracker.angle)")
            #expect(tracker.angle <= previous + 1e-9, "moved the wrong way at t=\(t)")
            maxStep = max(maxStep, previous - tracker.angle)
            previous = tracker.angle
            t += dt
        }
        // The cap — 150°/s — owns the visible pace: sub-degree steps,
        // and 60° of travel settles well under a second.
        #expect(maxStep <= tracker.maxRate * dt + 1e-9,
                "a frame stepped \(maxStep)° — over the slew cap")
        #expect(tracker.atRest)
        #expect(tracker.angle == 30)
    }

    @Test("the tracker holds sub-degree increments on a slow close")
    func trackerGlide() {
        var tracker = SlewTracker()
        tracker.feed(90)
        let dt = 1.0 / 120
        // A 10 Hz staircase: whole-degree edges every ~100 ms.
        var angle = 90.0
        var maxStep = 0.0
        var previous = tracker.angle
        for edge in 0..<20 {
            angle -= 1
            tracker.feed(angle)
            for _ in 0..<12 {
                tracker.tick(dt: dt)
                maxStep = max(maxStep, abs(tracker.angle - previous))
                previous = tracker.angle
            }
            _ = edge
        }
        #expect(maxStep < 1.0, "render stepped \(maxStep)° in one frame")
        #expect(abs(tracker.angle - angle) < 0.5)
    }

    @Test("a huge dt is a stall, not a teleport past the target")
    func trackerDtClamp() {
        var tracker = SlewTracker()
        tracker.feed(90)
        tracker.feed(30)
        tracker.tick(dt: 5)   // a slept display, not a frame
        #expect(tracker.angle > 30, "one step may not cross the target")
        #expect(tracker.angle <= 90 - tracker.maxRate * tracker.maxDt + 1e-6)
    }

    @Test("a non-finite sample cannot corrupt the tracker")
    func trackerGarbage() {
        var tracker = SlewTracker()
        tracker.feed(90)
        tracker.feed(.nan)
        tracker.feed(.infinity)
        tracker.tick(dt: 1.0 / 60)
        #expect(tracker.angle.isFinite)
        #expect(tracker.velocity.isFinite)
    }

    // MARK: DeltaChase

    @Test("a growing target is followed in the same tick — closing never waits")
    func chaseClosingIsInstant() {
        var chase = DeltaChase()
        // The old behaviour was a direct assignment; closing must stay
        // that responsive, bit for bit.
        var shown = chase.tick(target: 0.4, dt: 1.0 / 60)
        #expect(shown == 0.4)
        shown = chase.tick(target: 0.9, dt: 1.0 / 60)
        #expect(shown == 0.9)
        #expect(chase.atRest)
        // Even mid-unwind, a re-close snaps to the target at once —
        // the slew unwind sits higher than the old damped one did at
        // this point, so the re-close target is chosen above it.
        _ = chase.tick(target: 0, dt: 1.0 / 60)
        _ = chase.tick(target: 0, dt: 0.2)
        #expect(chase.value < 0.9 && !chase.atRest, "mid-unwind now")
        shown = chase.tick(target: 0.8, dt: 1.0 / 60)
        #expect(shown == 0.8)
        #expect(chase.atRest)
    }

    @Test("a gate-close snap unwinds smoothly and settles exactly on zero")
    func chaseUnwind() throws {
        var chase = DeltaChase()
        _ = chase.tick(target: 0.5, dt: 1.0 / 60)   // a fold in flight
        let dt = 1.0 / 120
        var t = 0.0
        var previous = chase.value
        var settledAt: Double?
        while t < 1.5 {
            let v = chase.tick(target: 0, dt: dt)
            #expect(v >= 0, "overshot below the floor at t=\(t): \(v)")
            #expect(v <= previous + 1e-9, "moved the wrong way at t=\(t): \(v) after \(previous)")
            if settledAt == nil, chase.atRest { settledAt = t }
            previous = v
            t += dt
        }
        #expect(chase.value == 0, "must settle exactly, not asymptote")
        #expect(chase.atRest, "rest is what lets the display link stand down")
        let settle = try #require(settledAt)
        #expect(settle > 0.1, "a snap would be the bug this fixes (\(settle)s)")
        #expect(settle < 0.9, "the unwind should land inside ~half a second (\(settle)s)")
        // The visible bulk should move in the first ~350 ms.
        var probe = DeltaChase()
        _ = probe.tick(target: 0.5, dt: dt)
        for _ in 0..<42 { probe.tick(target: 0, dt: dt) }   // 350 ms
        #expect(probe.value < 0.5 * 0.1,
                "90% of the unwind should be done in 350 ms, still at \(probe.value)")
    }

    @Test("an unwind can land on a non-zero target and re-close from there")
    func chaseUnwindPartial() {
        var chase = DeltaChase()
        _ = chase.tick(target: 0.8, dt: 1.0 / 60)
        let dt = 1.0 / 60
        var previous = chase.value
        for _ in 0..<120 {
            let v = chase.tick(target: 0.3, dt: dt)
            #expect(v >= 0.3 - 1e-9, "overshot the partial target: \(v)")
            #expect(v <= previous + 1e-9)
            previous = v
        }
        #expect(chase.value == 0.3)
        #expect(chase.atRest)
        // A target between the value and 0 unwinds; one above snaps.
        _ = chase.tick(target: 0.2, dt: dt)
        #expect(chase.value < 0.3 && chase.value > 0.2)
        let snap = chase.tick(target: 0.6, dt: dt)
        #expect(snap == 0.6)
    }

    @Test("stalled and garbage ticks can't corrupt the chase")
    func chaseGarbage() {
        var chase = DeltaChase()
        _ = chase.tick(target: 0.5, dt: 1.0 / 60)
        let v0 = chase.value
        #expect(chase.tick(target: .nan, dt: 1.0 / 60) == v0)
        let stalled = chase.tick(target: 0, dt: 0)
        #expect(stalled == v0, "a zero dt is not a frame")
        let negative = chase.tick(target: 0, dt: -1)
        #expect(negative == v0)
        // A slept-display dt clamps instead of teleporting home.
        let v1 = chase.tick(target: 0, dt: 5)
        #expect(v1 < v0 && v1 > 0)
        #expect(chase.value.isFinite && chase.velocity.isFinite)
    }

    @Test("reset plants the chase so a stale unwind can't resurrect")
    func chaseReset() {
        var chase = DeltaChase()
        _ = chase.tick(target: 0.5, dt: 1.0 / 60)
        _ = chase.tick(target: 0, dt: 1.0 / 60)
        #expect(!chase.atRest)
        chase.reset()
        #expect(chase.atRest && chase.value == 0)
        chase.reset(to: 0.4)
        #expect(chase.atRest && chase.value == 0.4, "a parked chase holds its plant")
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
        // The toy's own chain: sensor angle → tracker glide → delta →
        // chase → the shader's image params (opacity and dissolve ride
        // the displayed delta). Feed the symmetric 110 → 60 → 110 path
        // and let each held angle settle; the image at each angle must
        // be a palindrome — the same angle, the same picture.
        var tracker = SlewTracker()
        var chase = DeltaChase()
        let dt = 1.0 / 120
        tracker.feed(110)
        func image(at angle: Double) -> (Double, Double, Double) {
            tracker.feed(angle)
            var shown = 0.0
            for _ in 0..<600 {
                tracker.tick(dt: dt)
                let target = FoldMath.deltaRadians(
                    angle: tracker.angle, reference: 110)
                shown = chase.tick(target: target, dt: dt)
                if tracker.atRest && chase.atRest { break }
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
        // The transient the old damped unwind lost: during a real
        // opening the displayed delta sits on the target every frame —
        // the slew outruns the fastest lid the tracker can draw, so
        // mid-flight angles draw the same image too.
        var tracker2 = SlewTracker()
        var chase2 = DeltaChase()
        tracker2.feed(110)
        tracker2.feed(60)
        for _ in 0..<300 { tracker2.tick(dt: dt) }
        _ = chase2.tick(target: FoldMath.deltaRadians(
            angle: tracker2.angle, reference: 110), dt: dt)
        tracker2.feed(110)
        for _ in 0..<600 {
            tracker2.tick(dt: dt)
            let target = FoldMath.deltaRadians(
                angle: tracker2.angle, reference: 110)
            _ = chase2.tick(target: target, dt: dt)
            #expect(abs(chase2.value - target) < 1e-3,
                    "the opening path must retrace the closing one")
            if tracker2.atRest && chase2.atRest { break }
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
}
