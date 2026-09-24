import CoreGraphics
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Duo look's pure model (`FoldDuoModel`, FoldPortal.swift): the
/// held picture, the eased motion, the blur and darkening curves, the
/// end fade — plus the Duo's ends (`FirstFrameCatchUp`, `FoldBlackout`)
/// and the capture's bar-window rule. No Metal: every number the shader
/// draws is pinned here first.
@Suite("Fold Duo model")
struct FoldDuoModelTests {
    private let eye = FoldDuoModel.baseEye
    private let aspect = 1.54

    private func source(x: Double, h: Double, theta: Double, reference: Double = 110,
                        hold: Double = 1) -> FoldDuoModel.Source {
        FoldDuoModel.source(x: x, h: h, theta: theta, reference: reference, hold: hold,
                            eye: eye, aspect: aspect)
    }

    /// Where the eye sees a physical glass point, worked out on its own:
    /// the ray from the eye through the point, solved against the resting
    /// plane as a 2×2 system in the plane's own basis (not the renderer's
    /// dot-product form), returned as picture uv.
    private func observed(x: Double, h: Double, theta: Double, reference: Double) -> (u: Double, v: Double)? {
        let th = theta * .pi / 180, th0 = reference * .pi / 180
        // The glass point in the side view, and its lateral offset.
        let wx = h * cos(th), wy = h * sin(th)
        // Solve eye + s·(w − eye) = r·u0 for (s, r).
        let dx = wx - eye.x, dy = wy - eye.y
        let ux = cos(th0), uy = sin(th0)
        // s·dx − r·ux = −eye.x ; s·dy − r·uy = −eye.y
        let det = dx * (-uy) - (-ux) * dy
        guard abs(det) > 1e-12 else { return nil }
        let s = ((-eye.x) * (-uy) - (-ux) * (-eye.y)) / det
        let r = (dx * (-eye.y) - dy * (-eye.x)) / det
        guard s > 0 else { return nil }
        return (u: s * x / aspect + 0.5, v: 1 - r)
    }

    @Test("at the resting angle every pixel is the desktop itself")
    func identityAtReference() {
        for x in stride(from: -0.75, through: 0.75, by: 0.25) {
            for h in stride(from: 0.0, through: 1.0, by: 0.125) {
                let src = source(x: x, h: h, theta: 110)
                #expect(src.valid)
                #expect(abs(src.u - (x / aspect + 0.5)) < 1e-6)
                #expect(abs(src.v - (1 - h)) < 1e-6)
            }
        }
    }

    @Test("the hinge row is pinned at every angle")
    func hingePinned() {
        for theta in stride(from: 40.0, through: 110, by: 5) {
            for x in [-0.7, -0.2, 0, 0.3, 0.7] {
                let src = source(x: x, h: 0, theta: theta)
                #expect(src.valid)
                #expect(abs(src.v - 1) < 1e-9, "hinge row moved at \(theta)°")
                #expect(abs(src.u - (x / aspect + 0.5)) < 1e-9)
            }
        }
    }

    @Test("at a full hold each glass pixel shows what the seated eye sees behind it")
    func observerRoundTrip() {
        // Pseudo-random panel points, fixed seed: the picture must be
        // exactly where the eye would find it on the resting lid.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for theta in [100.0, 90, 75, 60] {
            for _ in 0..<40 {
                let x = (next() - 0.5) * aspect
                let h = next()
                let src = source(x: x, h: h, theta: theta)
                let seen = observed(x: x, h: h, theta: theta, reference: 110)
                #expect(src.valid)
                guard let seen else { Issue.record("no observer hit at \(theta)°"); continue }
                #expect(abs(src.u - seen.u) < 1e-4, "u at \(theta)°: \(src.u) vs \(seen.u)")
                #expect(abs(src.v - seen.v) < 1e-4, "v at \(theta)°: \(src.v) vs \(seen.v)")
            }
        }
    }

    @Test("at lid 70° the picture spans 79.4 % of the glass's top row")
    func topRowWidth() {
        // The picture's right edge on the top row: the panel x where the
        // sampled u crosses 1, found by bisection.
        var lo = 0.0, hi = aspect / 2
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if source(x: mid, h: 1, theta: 70).u < 1 { lo = mid } else { hi = mid }
        }
        let share = 2 * lo / aspect
        #expect(abs(share - 0.794) <= 0.005, "top-row width \(share)")
    }

    @Test("below edge-on the eye is behind the glass: invalid, drawn black")
    func invalidBelowEdgeOn() {
        let edge = FoldDuoModel.edgeOn(eye: eye)
        #expect(abs(edge - 37.57) < 0.05, "edge-on for the seated eye")
        #expect(source(x: 0, h: 0.5, theta: edge + 1).valid)
        #expect(!source(x: 0, h: 0.5, theta: edge - 1).valid)
        #expect(!source(x: 0.3, h: 1, theta: 20).valid)
    }

    @Test("a hold of 0 is the identity at every angle: the picture rides the glass")
    func holdZeroIsIdentity() {
        for theta in [100.0, 80, 60, 40] {
            let src = source(x: 0.4, h: 0.7, theta: theta, hold: 0)
            #expect(src.valid)
            #expect(abs(src.u - (0.4 / aspect + 0.5)) < 1e-9)
            #expect(abs(src.v - 0.3) < 1e-9)
        }
        #expect(FoldDuoModel.heldAngle(theta: 60, reference: 110, hold: 0) == 110)
        #expect(FoldDuoModel.heldAngle(theta: 60, reference: 110, hold: 1) == 60)
        #expect(FoldDuoModel.heldAngle(theta: 60, reference: 110, hold: 0.5) == 85)
    }

    @Test("motion starts with zero slope and saturates at the fade length")
    func motionCurve() {
        let span = 0.55 * (110 - FoldPause.closedAngle)
        #expect(FoldDuoModel.motion(delta: 0, reference: 110, fadeLength: 0.55) == 0)
        let eps = 1e-4
        let slope = FoldDuoModel.motion(delta: eps, reference: 110, fadeLength: 0.55) / eps
        #expect(slope < 1e-3, "an invisible start: slope \(slope)")
        #expect(FoldDuoModel.motion(delta: span, reference: 110, fadeLength: 0.55) == 1)
        #expect(FoldDuoModel.motion(delta: span * 2, reference: 110, fadeLength: 0.55) == 1)
        #expect(abs(FoldDuoModel.motion(delta: span / 2, reference: 110, fadeLength: 0.55) - 0.5) < 1e-9)
        // A shorter fade gets there sooner.
        #expect(FoldDuoModel.motion(delta: 20, reference: 110, fadeLength: 0.3)
                > FoldDuoModel.motion(delta: 20, reference: 110, fadeLength: 0.55))
        #expect(FoldDuoModel.motion(delta: -5, reference: 110, fadeLength: 0.55) == 0)
    }

    @Test("the hinge-side fifth never darkens; the far edge is black by half motion")
    func darkeningCurve() {
        // Shade 2/3 is gain 2, the Duo's own.
        let shade = 2.0 / 3
        for e in stride(from: 0.0, through: 0.19, by: 0.01) {
            #expect(FoldDuoModel.darkening(e: e, motion: 1, shade: shade) == 0)
        }
        #expect(FoldDuoModel.darkening(e: 1, motion: 0.5, shade: shade) >= 1 - 1e-9)
        #expect(FoldDuoModel.darkening(e: 1, motion: 0.8, shade: shade) == 1)
        #expect(FoldDuoModel.darkening(e: 1, motion: 0.25, shade: shade) < 1)
        #expect(FoldDuoModel.darkening(e: 0.6, motion: 1, shade: 0) == 0, "shade 0 never darkens")
        // Monotone toward the far edge.
        var last = 0.0
        for e in stride(from: 0.0, through: 1.0, by: 0.05) {
            let d = FoldDuoModel.darkening(e: e, motion: 0.4, shade: shade)
            #expect(d >= last - 1e-12)
            last = d
        }
    }

    @Test("blur grows from a sharp hinge to 0.10 H at Blur 1")
    func blurCurve() {
        #expect(FoldDuoModel.sigma(e: 0, motion: 1, blur: 1) == 0)
        #expect(abs(FoldDuoModel.sigma(e: 1, motion: 1, blur: 1) - 0.10) < 1e-12)
        #expect(abs(FoldDuoModel.sigma(e: 1, motion: 1, blur: 0.6) - 0.06) < 1e-12)
        #expect(FoldDuoModel.sigma(e: 1, motion: 0, blur: 1) == 0)
        #expect(FoldDuoModel.sigma(e: 0.5, motion: 1, blur: 1) < 0.05, "e^1.35 keeps the middle crisper")
    }

    @Test("the end fade is black at edge-on + 2° and clear from edge-on + 22°")
    func endFadeCurve() {
        let edge = FoldDuoModel.edgeOn(eye: eye)
        #expect(FoldDuoModel.endFade(theta: edge + 2, eye: eye) == 1)
        #expect(FoldDuoModel.endFade(theta: edge, eye: eye) == 1)
        #expect(FoldDuoModel.endFade(theta: 10, eye: eye) == 1)
        #expect(FoldDuoModel.endFade(theta: edge + 22, eye: eye) == 0)
        #expect(FoldDuoModel.endFade(theta: 110, eye: eye) == 0)
        let mid = FoldDuoModel.endFade(theta: edge + 12, eye: eye)
        #expect(mid > 0.4 && mid < 0.6)
    }

    @Test("Perspective moves the eye along its line: 0.6 is the seated eye")
    func eyeFromPerspective() {
        #expect(FoldDuoModel.eye(perspective: 0.6) == SIMD2<Double>(2.6, 2.0))
        let far = FoldDuoModel.eye(perspective: 0)
        let near = FoldDuoModel.eye(perspective: 1)
        #expect(far.x > near.x && far.y > near.y)
        #expect(abs(FoldDuoModel.edgeOn(eye: far) - FoldDuoModel.edgeOn(eye: near)) < 1e-9,
                "the edge-on angle depends on the eye's direction, not its distance")
    }

    @Test("apply writes the Duo's uniforms and leaves the upload's alone")
    func applyUniforms() {
        var p = FoldRenderer.Params()
        p.imageSize = .init(2560, 1662)
        p.lodCount = 8
        FoldDuoModel.apply(to: &p, reference: 110, theta: 80, hold: 1, perspective: 0.6,
                           blur: 0.6, shade: 2.0 / 3, fadeLength: 0.55, reduceMotion: false)
        #expect(abs(p.thetaRef - Float(110 * Double.pi / 180)) < 1e-6)
        #expect(abs(p.theta - Float(80 * Double.pi / 180)) < 1e-6)
        #expect(p.eyeF == 2.6 && p.eyeU == 2.0)
        #expect(p.hold == 1)
        #expect(abs(p.blurMax - 0.06) < 1e-6)
        #expect(abs(p.darkGain - 2) < 1e-5)
        #expect(p.motion > 0.4 && p.motion < 0.7)
        #expect(p.endFade == 0)
        #expect(p.opacity == 1)
        #expect(p.blackout == 0)
        #expect(p.imageSize == SIMD2<Float>(2560, 1662), "the upload's size survives the tick")
        #expect(p.lodCount == 8)
        // Reduce Motion: no warp and no blur, darkening only.
        FoldDuoModel.apply(to: &p, reference: 110, theta: 80, hold: 1, perspective: 0.6,
                           blur: 0.6, shade: 2.0 / 3, fadeLength: 0.55, reduceMotion: true)
        #expect(p.hold == 0)
        #expect(p.blurMax == 0)
        #expect(p.darkGain > 0 && p.motion > 0)
        // The first degrees fade the overlay in.
        FoldDuoModel.apply(to: &p, reference: 110, theta: 109, hold: 1, perspective: 0.6,
                           blur: 0.6, shade: 2.0 / 3, fadeLength: 0.55, reduceMotion: false)
        #expect(abs(p.opacity - 0.5) < 1e-6)
        FoldDuoModel.applyBlackout(to: &p)
        #expect(p.blackout == 1 && p.opacity == 1)
    }

    @Test("the Swift uniforms keep the shader's layout: Room first, Duo appended")
    func paramsLayout() {
        // FoldParams in the shader lists the same fields in the same
        // order; the Duo's scalars sit after the Room's `hold`.
        typealias P = FoldRenderer.Params
        #expect(MemoryLayout<P>.offset(of: \P.hold) == 96)
        #expect(MemoryLayout<P>.offset(of: \P.thetaRef) == 100)
        #expect(MemoryLayout<P>.offset(of: \P.blackout) == 132)
        #expect(MemoryLayout<P>.offset(of: \P.lodCount) == 136)
        #expect(MemoryLayout<P>.offset(of: \P.pyramidShift) == 140)
        #expect(MemoryLayout<P>.stride == 144)
    }

    @Test("the pyramid level carries the asked-for blur, clamped to the levels built")
    func lodMapping() {
        #expect(FoldDuoModel.lod(sigmaPixels: 0) == 0)
        #expect(abs(FoldDuoModel.lod(sigmaPixels: 0.82 * 8) - 3) < 1e-9)
        #expect(FoldDuoModel.lod(sigmaPixels: 1e6) == 7)
        #expect(FoldDuoModel.lod(sigmaPixels: 1e6, levels: 4) == 3)
    }

    @Test("the order-in ramp fades the overlay in over 120 ms")
    func orderInRamp() {
        #expect(FoldDuoModel.orderInRamp(elapsed: 0) == 0)
        #expect(FoldDuoModel.orderInRamp(elapsed: 0.12) == 1)
        #expect(FoldDuoModel.orderInRamp(elapsed: 5) == 1)
        let mid = FoldDuoModel.orderInRamp(elapsed: 0.06)
        #expect(abs(mid - 0.5) < 1e-9)
    }

    // MARK: First-frame catch-up

    @Test("a late first frame eases the delta up over 150 ms, then steps aside")
    func catchUpEases() {
        var catchUp = FirstFrameCatchUp()
        #expect(catchUp.scale(at: 1) == 1, "nothing to catch up: the live delta")
        catchUp.begin(liveDelta: 0.3, at: 10)
        #expect(catchUp.active)
        #expect(catchUp.scale(at: 10) == 0, "the first frame shows the desktop, not a jump")
        var last = 0.0
        for i in 1...14 {
            let s = catchUp.scale(at: 10 + Double(i) * 0.01)
            #expect(s >= last)
            last = s
        }
        #expect(catchUp.scale(at: 10.15) == 1)
        #expect(!catchUp.active, "done means gone")
        #expect(catchUp.scale(at: 10.16) == 1)
    }

    @Test("a first frame with almost no travel needs no catch-up")
    func catchUpThreshold() {
        var catchUp = FirstFrameCatchUp()
        catchUp.begin(liveDelta: 1.5 * .pi / 180, at: 3)
        #expect(!catchUp.active)
        catchUp.begin(liveDelta: .nan, at: 3)
        #expect(!catchUp.active)
    }

    // MARK: Blackout

    @Test("the black hold lets go on its watchdog if the lid stays shut")
    func blackoutWatchdog() {
        var hold = FoldBlackout()
        hold.hold(at: 100)
        #expect(hold.active)
        #expect(!hold.expired(at: 102.9))
        #expect(hold.expired(at: 103))
        // Holding again while held never pushes the deadline out.
        hold.hold(at: 102)
        #expect(hold.deadline == 103)
    }

    @Test("a reopen restarts the watchdog once and releases past 15° with a fresh frame")
    func blackoutReopen() {
        var hold = FoldBlackout()
        hold.hold(at: 0)
        hold.note(angle: 3, at: 1)
        #expect(hold.deadline == 3, "still shut: no restart")
        hold.note(angle: 8, at: 2.5)
        #expect(hold.deadline == 5.5, "the reopen gets its own three seconds")
        hold.note(angle: 12, at: 4)
        #expect(hold.deadline == 5.5, "only once")
        #expect(!hold.releases(angle: 12, freshFrame: true), "not open enough yet")
        #expect(!hold.releases(angle: 20, freshFrame: false), "no frame since the close")
        #expect(hold.releases(angle: 15, freshFrame: true))
        hold.end()
        #expect(!hold.active)
        #expect(!hold.releases(angle: 40, freshFrame: true), "nothing to release once let go")
    }

    @Test("a reopen from black unfolds: the first frame is still black and the picture comes up over frames")
    func reopenUnfoldsFromBlack() {
        let reference = 110.0
        let seed = FoldDuoModel.reopenDelta(reference: reference, perspective: 0.6)
        let seedTheta = reference - seed * 180 / .pi
        #expect(abs(seedTheta - FoldDuoModel.blackAngle(eye: eye)) < 1e-9)
        #expect(FoldDuoModel.endFade(theta: seedTheta, eye: eye) == 1, "the first frame matches the hold")
        // The lid is already at 60° (a quick reopen) or back at its rest
        // by the time a frame lands; the chase unwinds from the seed.
        for liveLid in [60.0, reference] {
            var chase = DeltaChase()
            chase.reset(to: seed)
            let live = (reference - liveLid) * .pi / 180
            var lastFade = 1.0
            var biggestStep = 0.0
            var frames = 0
            while frames < 120 {
                let delta = chase.tick(target: live, dt: 1.0 / 60)
                frames += 1
                let fade = FoldDuoModel.endFade(theta: reference - delta * 180 / .pi, eye: eye)
                #expect(fade <= lastFade, "the picture only ever comes up")
                biggestStep = max(biggestStep, lastFade - fade)
                lastFade = fade
                if chase.atRest { break }
            }
            #expect(chase.value == live, "the unfold lands on the lid")
            #expect(Double(frames) / 60 < 0.5, "and is done within half a second")
            #expect(lastFade == 0, "clear once it lands above edge-on + 22°")
            #expect(biggestStep < 0.25, "no frame cuts from black to lit (\(biggestStep))")
        }
        // A lid still under the black angle when the frame lands simply
        // follows the lid: the chase takes the larger delta.
        var low = DeltaChase()
        low.reset(to: seed)
        let under = (reference - 20) * .pi / 180
        #expect(low.tick(target: under, dt: 1.0 / 60) == under)
        #expect(FoldDuoModel.reopenDelta(reference: 30, perspective: 0.6) == 0)
        #expect(FoldDuoModel.reopenDelta(reference: .nan, perspective: 0.6) == 0)
    }

    @Test("one gesture draws from one reference, so a dwell re-seat never flashes black")
    func drawnReferenceHoldsPerGesture() {
        // The overlay orders in: the current reference is taken.
        #expect(FoldDuoModel.drawnReference(held: nil, current: 110, overlayVisible: false) == 110)
        #expect(FoldDuoModel.drawnReference(held: 95, current: 110, overlayVisible: false) == 110)
        // On screen, the held one stays even as the anchor moves under it.
        #expect(FoldDuoModel.drawnReference(held: 110, current: 70, overlayVisible: true) == 110)
        #expect(FoldDuoModel.drawnReference(held: nil, current: 70, overlayVisible: true) == 70)
        #expect(FoldDuoModel.drawnReference(held: 110, current: nil, overlayVisible: false) == 110)
        // Release when parked at 70° with the fold 40° in: the unwind
        // drawn from the parked angle would start at 30°, under edge-on
        // (black); from the held 110° it starts at 70°, clear.
        #expect(FoldDuoModel.endFade(theta: 70 - 40, eye: eye) == 1, "the re-seated anchor would flash black")
        let held = FoldDuoModel.drawnReference(held: 110, current: 70, overlayVisible: true) ?? 0
        #expect(FoldDuoModel.endFade(theta: held - 40, eye: eye) == 0)
    }

    // MARK: Bar windows

    @Test("the Duo keeps JR-Bar's own menu-bar windows and nothing else of ours")
    func barWindows() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let windows: [FoldCapture.BarWindowFacts] = [
            .init(id: 1, frame: CGRect(x: 1200, y: 0, width: 30, height: 37), layer: status + 1),   // icon mirror
            .init(id: 2, frame: CGRect(x: 0, y: 0, width: 1512, height: 37), layer: status + 2),    // Screen Bar
            .init(id: 3, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 1000),         // the fold itself
            .init(id: 4, frame: CGRect(x: 600, y: 0, width: 300, height: 200), layer: status + 1),  // a card under the bar
            .init(id: 5, frame: CGRect(x: 100, y: 300, width: 400, height: 300), layer: 0),         // a normal window
            .init(id: 6, frame: CGRect(x: 1600, y: 0, width: 30, height: 37), layer: status + 1),   // another display
            .init(id: 7, frame: CGRect(x: 900, y: 0, width: 40, height: 37), layer: status - 1),    // main-menu level
        ]
        let kept = FoldCapture.barWindowIDs(windows, displayFrame: display, barHeight: 37)
        #expect(kept == [1, 2, 7])
    }
}
