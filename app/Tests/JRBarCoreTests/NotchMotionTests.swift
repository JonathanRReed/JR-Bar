import Foundation
import Testing
@testable import JRBarCore

/// The island's motion system as pure numbers: the named springs, the
/// frame spring held to its closed form, a reversal that continues from
/// where the frame visibly was, and the content reveal as a function of
/// the shape's own travel. No clock is read anywhere here; time is an
/// argument.
@Suite("Notch motion")
struct NotchMotionTests {
    private let idle = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    private let card = CGRect(x: 596, y: 560, width: 320, height: 422)

    private func openness(_ spring: NotchFrameSpring, _ morph: NotchMorph) -> CGFloat {
        morph.openness(height: spring.frame.height)
    }

    // MARK: Springs

    @Test("the grow overshoots a hair and settles fast; the fold never bounces")
    func springCharacter() {
        #expect(NotchMotion.open.overshoot > 0.01 && NotchMotion.open.overshoot < 0.03,
                "alive, not wobbly: \(NotchMotion.open.overshoot)")
        #expect(NotchMotion.live.overshoot > 0.005 && NotchMotion.live.overshoot < 0.03)
        #expect(NotchMotion.close.overshoot < 0.005, "a dismissal never bounces")
        #expect(NotchMotion.nudge.overshoot < 0.005)
        #expect(NotchMotion.hover.overshoot > NotchMotion.open.overshoot,
                "the swell is the liveliest thing the island does")
        #expect(NotchMotion.hover.overshoot < 0.05)
        #expect(NotchMotion.open.settlingTime() < 0.6)
        #expect(NotchMotion.close.settlingTime() < NotchMotion.open.settlingTime(),
                "closing is the faster gesture")
        #expect(NotchMotion.hover.settlingTime() < 0.45)
    }

    @Test("the integrator follows the closed form to within two percent of travel")
    func integratorMatchesClosedForm() {
        for motion in [NotchMotion.open, NotchMotion.live, NotchMotion.close, NotchMotion.hover] {
            var spring = NotchFrameSpring(at: idle)
            spring.retarget(card, motion: motion)
            var t = 0.0
            let dt = 1.0 / 120
            for _ in 0..<60 {
                spring.integrate(dt: dt)
                t += dt
                let expected = idle.height + (card.height - idle.height) * motion.step(at: t)
                #expect(abs(spring.frame.height - expected) < (card.height - idle.height) * 0.02,
                        "t=\(t) \(motion): \(spring.frame.height) vs \(expected)")
            }
        }
    }

    @Test("a unit step starts at rest, peaks at the overshoot and ends at one")
    func stepShape() {
        let motion = NotchMotion.open
        #expect(motion.step(at: 0) == 0)
        let peak = (0...400).map { motion.step(at: Double($0) / 400) }.max() ?? 0
        #expect(abs(peak - (1 + motion.overshoot)) < 0.004)
        #expect(abs(motion.step(at: 1.5) - 1) < 1e-4)
        #expect(abs(NotchMotion.close.step(at: 2) - 1) < 1e-6)
        #expect(NotchMotion.close.step(at: 0.05) > 0, "no dead time before it moves")
        let critical = NotchFrameSpring.Motion(response: 0.4, dampingFraction: 1)
        #expect(critical.overshoot == 0)
        #expect(abs(critical.step(at: 2) - 1) < 1e-6)
    }

    @Test("the swell is hover, a short hop is live, the full grow is open, a shrink is the fold")
    func picker() {
        #expect(NotchMotion.frameMotion(from: idle, to: card) == NotchMotion.open.widthScaled(NotchMotion.widthLead))
        let notice = CGRect(x: 640, y: 924, width: 232, height: 58)
        #expect(NotchMotion.frameMotion(from: idle, to: notice) == NotchMotion.live)
        #expect(NotchMotion.frameMotion(from: card, to: idle) == NotchMotion.close.widthScaled(NotchMotion.widthLag))
        #expect(NotchMotion.frameMotion(from: idle, to: idle) == NotchMotion.nudge)
        let swell = CGRect(x: idle.minX - 2, y: idle.minY - 2, width: idle.width + 4, height: idle.height + 2)
        #expect(NotchMotion.frameMotion(from: idle, to: swell) == NotchMotion.hover,
                "a few points of lean is the hover swell")
        #expect(NotchMotion.frameMotion(from: swell, to: idle) == NotchMotion.nudge,
                "and it relaxes without a fold")
    }

    // MARK: Interruption

    @Test("folding to wider shoulders stays quick and calm")
    func widerRestUsesClosingMotion() {
        let wideIdle = CGRect(x: card.midX - 200, y: idle.minY, width: 400, height: idle.height)
        let motion = NotchMotion.frameMotion(from: card, to: wideIdle)
        #expect(motion == NotchMotion.close)
        #expect(NotchMotion.frameMotion(from: wideIdle, to: card) == NotchMotion.open)
        var spring = NotchFrameSpring(at: card, motion: motion, target: wideIdle)
        for _ in 0..<24 { spring.integrate(dt: 1.0 / 120) }
        #expect(spring.frame.height - wideIdle.height < 12)
        #expect(abs(spring.frame.midX - card.midX) < 0.01)
        #expect(spring.frame.width <= wideIdle.width + 0.1)
    }

    @Test("a reversal mid-grow continues from the frame and the speed it had")
    func reversalContinues() {
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.open)
        for _ in 0..<14 { spring.integrate(dt: 1.0 / 120) }
        let before = spring.frame
        let speed = spring.velocity
        #expect(before.height > idle.height + 40 && before.height < card.height - 40)
        #expect(speed.height > 0, "it is still opening")
        spring.retarget(idle, motion: NotchMotion.close)
        #expect(spring.frame == before, "the retarget itself moves nothing")
        #expect(spring.velocity == speed, "and keeps the speed")
        // One tick later the frame has moved on by roughly the old speed,
        // not been thrown to the new target or restarted from rest.
        spring.integrate(dt: 1.0 / 120)
        let step = abs(spring.frame.height - before.height)
        #expect(step < abs(speed.height) / 120 + 4, "continuous: \(step)")
        // And it lands home.
        var ticks = 0
        while spring.integrate(dt: 1.0 / 120), ticks < 600 { ticks += 1 }
        #expect(ticks < 300)
        spring.snap()
        #expect(spring.frame == idle)
    }

    @Test("no tick of a reversal jumps: height moves a bounded amount per frame")
    func reversalNeverJumps() {
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.open)
        var last = spring.frame.height
        var worst: CGFloat = 0
        let reverseAt = [9, 17, 26]
        var tick = 0
        var toCard = true
        while tick < 400 {
            if reverseAt.contains(tick) {
                toCard.toggle()
                spring.retarget(toCard ? card : idle,
                                motion: NotchMotion.frameMotion(from: spring.frame, to: toCard ? card : idle))
            }
            spring.integrate(dt: 1.0 / 120)
            worst = max(worst, abs(spring.frame.height - last))
            last = spring.frame.height
            tick += 1
        }
        // The grow's peak speed is about 3000 pt/s over a 390 pt travel:
        // ~25 pt a tick at 120 Hz. A jump would be a sizeable share of
        // the whole travel in one tick; the bound is 7% of it.
        #expect(worst < (card.height - idle.height) * 0.07, "worst per-tick step \(worst)")
        spring.snap()
        #expect(spring.frame.height == idle.height || spring.frame.height == card.height)
    }

    @Test("a pointer thrashing in and out at 20 Hz leaves a finite frame that still lands")
    func thrashStaysFinite() {
        var spring = NotchFrameSpring(at: idle)
        let swell = CGRect(x: idle.minX - 2, y: idle.minY - 2, width: idle.width + 4, height: idle.height + 2)
        var inside = false
        for beat in 0..<80 {
            inside.toggle()
            let target = inside ? swell : idle
            spring.retarget(target, motion: inside ? NotchMotion.hover : NotchMotion.nudge)
            for _ in 0..<6 { spring.integrate(dt: 1.0 / 120) }
            let f = spring.frame
            #expect(f.height.isFinite && f.width.isFinite, "beat \(beat)")
            #expect(f.height > idle.height - 3 && f.height < idle.height + 5, "beat \(beat): \(f.height)")
            #expect(f.width > idle.width - 5 && f.width < idle.width + 9, "beat \(beat): \(f.width)")
        }
        spring.retarget(idle, motion: NotchMotion.nudge)
        var ticks = 0
        while spring.integrate(dt: 1.0 / 120), ticks < 600 { ticks += 1 }
        spring.snap()
        #expect(spring.frame == idle, "at rest once the pointer is gone")
    }

    // MARK: One clock for the content

    @Test("openness reads the shape's height between its rest and its grown card")
    func opennessMath() {
        let morph = NotchMorph(rest: 32, open: 432)
        #expect(morph.openness(height: 32) == 0)
        #expect(morph.openness(height: 232) == 0.5)
        #expect(morph.openness(height: 432) == 1)
        #expect(morph.openness(height: 440) == 1, "the overshoot is still fully open")
        #expect(morph.openness(height: 20) == 0)
        #expect(NotchMorph(rest: 32, open: 32).openness(height: 32) == 1,
                "a morph with no travel never strands the content dark")
    }

    @Test("the sheet is dark at the notch, in focus when grown, and monotone between")
    func sheetCurve() {
        let closed = NotchReveal.sheet(openness: 0)
        #expect(closed.opacity == 0 && closed.blur == NotchReveal.sheetBlur)
        #expect(closed.scale == NotchReveal.sheetScale && closed.lift == -NotchReveal.sheetLift)
        #expect(NotchReveal.sheet(openness: 1) == .settled)
        #expect(NotchReveal.sheet(openness: 1.4) == .settled, "overshoot never over-reveals")
        var previous = NotchReveal.sheet(openness: 0)
        for i in 1...100 {
            let now = NotchReveal.sheet(openness: CGFloat(i) / 100)
            #expect(now.opacity >= previous.opacity)
            #expect(now.blur <= previous.blur)
            #expect(now.scale >= previous.scale)
            #expect(now.lift >= previous.lift)
            previous = now
        }
    }

    @Test("rows cascade down the card and the last is in before the shape has landed")
    func rowCascade() {
        for step in 0..<NotchReveal.rowSteps {
            for i in 0...50 {
                let p = CGFloat(i) / 50
                #expect(NotchReveal.row(step: step, openness: p)
                        >= NotchReveal.row(step: step + 1, openness: p),
                        "step \(step) leads step \(step + 1) at \(p)")
            }
        }
        #expect(NotchReveal.row(step: 0, openness: 0.4) == 0, "no row before the sheet is coming")
        #expect(NotchReveal.row(step: 99, openness: 1) == 1)
        #expect(NotchReveal.row(step: -3, openness: 1) == 1)
        #expect(NotchReveal.row(step: 99, openness: 0.95) > 0.95, "the last row is nearly there by 95%")
        #expect(NotchReveal.row(step: 99, openness: 1)
                == NotchReveal.row(step: NotchReveal.rowSteps, openness: 1))
    }

    @Test("the edge light arrives late and never at the resting notch")
    func edgeLight() {
        #expect(NotchReveal.edgeLight(openness: 0) == 0)
        #expect(NotchReveal.edgeLight(openness: 0.5) == 0)
        #expect(NotchReveal.edgeLight(openness: 1) == 1)
    }

    @Test("staged: the card stays on stage through the fold until it is out of sight")
    func staging() {
        #expect(NotchReveal.staged(expanded: true, openness: 0))
        #expect(NotchReveal.staged(expanded: false, openness: 0.5))
        #expect(!NotchReveal.staged(expanded: false, openness: 0.01))
        #expect(!NotchReveal.staged(expanded: false, openness: 0))
    }

    @Test("a real grow: nothing legible in the first frames, everything in a quarter second")
    func contentFollowsTheShape() throws {
        let morph = NotchMorph(rest: idle.height, open: card.height)
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.open)
        var t = 0.0
        var firstSeen: Double?
        var allIn: Double?
        var settled: Double?
        while t < 1.5 {
            let moving = spring.integrate(dt: 1.0 / 240)
            t += 1.0 / 240
            let p = openness(spring, morph)
            let sheet = NotchReveal.sheet(openness: p)
            if firstSeen == nil, sheet.opacity > 0.02 { firstSeen = t }
            if allIn == nil, sheet.opacity >= 0.999,
               NotchReveal.row(step: NotchReveal.rowSteps, openness: p) >= 0.999 { allIn = t }
            if settled == nil, !moving { settled = t }
        }
        let first = try #require(firstSeen)
        let all = try #require(allIn)
        let landed = try #require(settled)
        #expect(first > 0.04, "content never arrives with the shape's first frames (\(first))")
        #expect(all < 0.30, "the whole card is in inside 0.3 s (\(all))")
        #expect(all < landed, "content is in before the spring has finished settling")
    }

    @Test("a fold takes the content out while the shape still has half its way to fall")
    func foldClearsContentFirst() throws {
        let morph = NotchMorph(rest: idle.height, open: card.height)
        var spring = NotchFrameSpring(at: card)
        spring.retarget(idle, motion: NotchMotion.close)
        var t = 0.0
        var gone: CGFloat?
        while t < 1, gone == nil {
            spring.integrate(dt: 1.0 / 240)
            t += 1.0 / 240
            let p = openness(spring, morph)
            if NotchReveal.sheet(openness: p).opacity < 0.01 { gone = p }
        }
        let p = try #require(gone)
        #expect(p >= 0.35, "the content is out by the time the shape is at \(p) of its height")
        #expect(t < 0.2, "and that happens in the first fifth of a second (\(t))")
    }

    @Test("a grow reversed halfway sends the content back the way it came, in step with the shape")
    func contentReversesWithTheShape() {
        let morph = NotchMorph(rest: idle.height, open: card.height)
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.open)
        var opacityAtHeight: [Int: CGFloat] = [:]
        var up = true
        for tick in 0..<300 {
            if tick == 14 { up = false; spring.retarget(idle, motion: NotchMotion.close) }
            spring.integrate(dt: 1.0 / 120)
            let p = openness(spring, morph)
            let sheet = NotchReveal.sheet(openness: p)
            // The content is a function of the shape alone: the same
            // height reads the same opacity on the way up and on the way
            // down, so nothing can drift from it.
            let key = Int((spring.frame.height / 4).rounded())
            if let earlier = opacityAtHeight[key], !up {
                #expect(abs(earlier - sheet.opacity) < 0.12, "height \(spring.frame.height)")
            }
            if up { opacityAtHeight[key] = sheet.opacity }
        }
    }

    // MARK: Hover clocks

    @Test("the swell leads the card: at once for a direct arrival, never later than the card")
    func swellLeads() {
        let standard = NotchMotion.hoverDelays(openAfter: 0.12, fromBar: false)
        #expect(standard.peek == NotchMotion.peekDelay && standard.expand == 0.12)
        #expect(standard.peek < standard.expand, "the island leans before it opens")
        let now = NotchMotion.hoverDelays(openAfter: 0, fromBar: false)
        #expect(now.peek == 0 && now.expand == 0)
        let quick = NotchMotion.hoverDelays(openAfter: 0.03, fromBar: false)
        #expect(quick.peek <= 0.03, "never later than the card")
        let fromBar = NotchMotion.hoverDelays(openAfter: 0.12, fromBar: true)
        #expect(fromBar.peek == NotchMotion.hoverDelay, "a pointer from the menu row tells more slowly")
        #expect(fromBar.expand == NotchMotion.barArrivalFloor)
    }

    // MARK: The stage

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test("the stage holds the whole morph and its overshoot, hung from the top edge")
    func stageHoldsTheMorph() {
        let stage = NotchStage.frame(presented: idle, target: card, motion: NotchMotion.open,
                                     within: screen, scale: 2)
        #expect(stage.maxY == screen.maxY, "the island grows down from the screen's top")
        #expect(NotchStage.holds(stage, idle) && NotchStage.holds(stage, card))
        let overshoot = card.height * NotchMotion.open.overshoot
        let grown = CGRect(x: card.minX, y: card.minY - overshoot,
                           width: card.width, height: card.height + overshoot)
        #expect(NotchStage.holds(stage, grown), "the spring's overshoot stays inside")
        #expect(screen.contains(stage))
        #expect(stage.minX * 2 == (stage.minX * 2).rounded() && stage.width * 2 == (stage.width * 2).rounded(),
                "whole device pixels")
        #expect(stage.width < 400 && stage.height < 460, "a stage, not a screen: \(stage)")
    }

    @Test("a fold's stage is the card's own frame and a little air")
    func stageForFold() {
        let stage = NotchStage.frame(presented: card, target: idle, motion: NotchMotion.close,
                                     within: screen, scale: 2)
        #expect(NotchStage.holds(stage, card) && NotchStage.holds(stage, idle))
        #expect(stage.height <= card.height + 12)
    }

    @Test("a stage never leaves the screen")
    func stageStaysOnScreen() {
        let edge = CGRect(x: 4, y: 560, width: 320, height: 422)
        let stage = NotchStage.frame(presented: edge, target: edge.offsetBy(dx: -6, dy: 0),
                                     motion: NotchMotion.open, within: screen, scale: 2)
        #expect(screen.contains(stage))
    }

    @Test("the shape in the stage's own coordinates: top-left origin, y down")
    func localCoordinates() {
        let window = CGRect(x: 580, y: 540, width: 352, height: 442)
        let shape = CGRect(x: 663.5, y: 900, width: 185, height: 82)
        let local = NotchStage.local(shape, in: window)
        #expect(local.minX == 83.5)
        #expect(local.minY == 0, "a shape on the top edge sits at the window's top")
        #expect(local.size == shape.size)
        let low = NotchStage.local(CGRect(x: 600, y: 600, width: 100, height: 50), in: window)
        #expect(low.minY == 332)
    }

    @Test("a retarget past the stage is noticed")
    func holdsDetectsOutgrowth() {
        let stage = CGRect(x: 580, y: 540, width: 352, height: 442)
        #expect(NotchStage.holds(stage, CGRect(x: 600, y: 600, width: 300, height: 382)))
        #expect(!NotchStage.holds(stage, CGRect(x: 570, y: 600, width: 300, height: 382)))
        #expect(!NotchStage.holds(stage, CGRect(x: 600, y: 520, width: 300, height: 400)))
    }
}

// MARK: - The width is on its own clock

@Suite("Notch width lead")
struct NotchWidthLeadTests {
    private let idle = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    private let card = CGRect(x: 596, y: 560, width: 320, height: 422)

    private func fractions(_ spring: NotchFrameSpring, from: CGRect, to: CGRect) -> (w: CGFloat, h: CGFloat) {
        ((spring.frame.width - from.width) / (to.width - from.width),
         (spring.frame.height - from.height) / (to.height - from.height))
    }

    @Test("the grow widens ahead of its depth, so the sides are there before the content is")
    func growWidthLeads() {
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.frameMotion(from: idle, to: card))
        for _ in 0..<12 { spring.integrate(dt: 1.0 / 240) }
        let early = fractions(spring, from: idle, to: card)
        #expect(early.w > early.h + 0.1, "width \(early.w) should lead height \(early.h)")
        for _ in 0..<400 { spring.integrate(dt: 1.0 / 240) }
        spring.snap()
        #expect(spring.frame == card)
    }

    @Test("the fold narrows behind its depth, so the sides never cut lit rows")
    func foldWidthLags() {
        var spring = NotchFrameSpring(at: card)
        spring.retarget(idle, motion: NotchMotion.frameMotion(from: card, to: idle))
        for _ in 0..<12 { spring.integrate(dt: 1.0 / 240) }
        let early = fractions(spring, from: card, to: idle)
        #expect(early.w < early.h - 0.05, "width \(early.w) should trail height \(early.h)")
    }

    @Test("a reversal keeps the width's own position and speed: no tick jumps")
    func reversalKeepsWidthContinuous() {
        var spring = NotchFrameSpring(at: idle)
        spring.retarget(card, motion: NotchMotion.frameMotion(from: idle, to: card))
        var last = spring.frame.width
        var worst: CGFloat = 0
        var toCard = true
        for tick in 0..<400 {
            if [8, 15, 22].contains(tick) {
                toCard.toggle()
                let target = toCard ? card : idle
                spring.retarget(target, motion: NotchMotion.frameMotion(from: spring.frame, to: target))
            }
            spring.integrate(dt: 1.0 / 120)
            worst = max(worst, abs(spring.frame.width - last))
            last = spring.frame.width
        }
        #expect(worst < (card.width - idle.width) * 0.12, "worst per-tick width step \(worst)")
    }

    @Test("content is never more open than the shape is wide")
    func opennessTakesTheLesserAxis() {
        let morph = NotchMorph(rest: 32, open: 432, restWidth: 185, openWidth: 320)
        #expect(morph.openness(size: CGSize(width: 320, height: 232)) == 0.5)
        #expect(morph.openness(size: CGSize(width: 185, height: 432)) == 0,
                "a tall sliver of the notch's width shows nothing")
        #expect(morph.openness(size: CGSize(width: 252.5, height: 432)) == 0.5)
        #expect(morph.openness(size: CGSize(width: 330, height: 440)) == 1)
        let heightOnly = NotchMorph(rest: 32, open: 432)
        #expect(heightOnly.openness(size: CGSize(width: 1, height: 232)) == 0.5,
                "without widths it reads the height alone")
    }
}

// MARK: - A notice follows its own shape

@Suite("Notch notice reveal")
struct NotchNoticeRevealTests {
    @Test("a notice is dark at the notch, whole when landed, and monotone between")
    func curve() {
        let hidden = NotchReveal.notice(openness: 0)
        #expect(hidden.opacity == 0 && hidden.blur == NotchMotion.noticeBlur
                && hidden.lift == -NotchMotion.noticeSlide && hidden.scale == 1)
        #expect(NotchReveal.notice(openness: 1) == .settled)
        #expect(NotchReveal.notice(openness: 1.3) == .settled)
        var previous = hidden
        for i in 1...100 {
            let now = NotchReveal.notice(openness: CGFloat(i) / 100)
            #expect(now.opacity >= previous.opacity && now.blur <= previous.blur && now.lift >= previous.lift)
            previous = now
        }
    }

    @Test("the line waits for the lip: dark until the shape is two fifths down")
    func waitsForTheLip() {
        #expect(NotchReveal.notice(openness: NotchReveal.noticeStart).opacity == 0)
        #expect(NotchReveal.notice(openness: NotchReveal.noticeEnd).opacity == 1)
        #expect(NotchReveal.notice(openness: 0.2).opacity == 0)
    }

    @Test("the track swap is a quiet fade, shorter than the grow it may share the island with")
    func trackSwapIsQuiet() {
        #expect(NotchMotion.trackSwap >= 0.15 && NotchMotion.trackSwap <= 0.3)
        #expect(NotchMotion.trackSwap < NotchMotion.open.settlingTime())
    }

    @Test("a track's words go out before the new ones come in, and never smear into each other")
    func trackSwapSequence() {
        #expect(abs(NotchMotion.trackSwapInDelay + NotchMotion.trackSwapIn - NotchMotion.trackSwap) < 1e-9,
                "the words and the cover end together")
        let start = NotchMotion.trackSwapLevels(since: 0)
        #expect(start.outgoing == 1 && start.incoming == 0)
        let end = NotchMotion.trackSwapLevels(since: NotchMotion.trackSwap)
        #expect(end.outgoing == 0 && end.incoming == 1)
        var previous = start
        var worstOverlap: CGFloat = 0
        for step in 1...220 {
            let now = NotchMotion.trackSwapLevels(since: Double(step) / 1000)
            #expect(now.outgoing <= previous.outgoing, "the old words only ever leave")
            #expect(now.incoming >= previous.incoming, "the new words only ever arrive")
            worstOverlap = max(worstOverlap, min(now.outgoing, now.incoming))
            previous = now
        }
        #expect(worstOverlap < 0.2,
                "two sets of glyphs are never both more than a fifth legible (\(worstOverlap))")
        #expect(NotchMotion.trackSwapLevels(since: -1).outgoing == 1)
        #expect(NotchMotion.trackSwapLevels(since: 5).incoming == 1)
    }
}
