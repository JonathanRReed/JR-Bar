import Foundation
import Testing
@testable import JRBarCore

/// The card's content clock as pure numbers: it starts with the shape and
/// leaves ahead of it, it is the same curve at 60 Hz and 120 Hz, and a
/// change of aim at any moment bends it without a step. Time is only ever
/// an argument.
@Suite("Notch content clock")
struct NotchContentClockTests {
    private let idle = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    private let card = CGRect(x: 596, y: 560, width: 320, height: 422)
    private var morph: NotchMorph {
        NotchMorph(rest: idle.height, open: card.height, restWidth: idle.width, openWidth: card.width)
    }

    /// Plays a grow (or a fold) of the shape and the clock together, one
    /// `dt` at a time, and hands each moment to `body`.
    private func play(opening: Bool, seconds: Double = 0.6, dt: Double = 1.0 / 240,
                      _ body: (_ t: Double, _ openness: CGFloat, _ level: CGFloat) -> Void) {
        var spring = NotchFrameSpring(at: opening ? idle : card)
        let to = opening ? card : idle
        spring.retarget(to, motion: NotchMotion.frameMotion(from: spring.frame, to: to))
        var clock = NotchContentClock(level: opening ? 0 : 1)
        clock.aim(open: opening)
        var t = 0.0
        while t < seconds {
            spring.integrate(dt: dt)
            clock.advance(dt: dt)
            t += dt
            body(t, morph.openness(size: spring.frame.size), clock.level)
        }
    }

    // MARK: Arriving with the shape

    @Test("on a grow the content is already coming in while the shape has barely moved")
    func contentStartsWithTheShape() throws {
        var firstSeen: Double?
        var atForty: CGFloat = 0
        var opennessAtFirst: CGFloat = 1
        play(opening: true) { t, openness, level in
            if firstSeen == nil, level > 0.05 { firstSeen = t; opennessAtFirst = openness }
            if atForty == 0, t >= 0.04 { atForty = level }
        }
        let first = try #require(firstSeen)
        #expect(first < 0.025, "content is visible within the first frames of the move (\(first))")
        #expect(opennessAtFirst < 0.1, "while the shape is still under a tenth open (\(opennessAtFirst))")
        #expect(atForty > 0.3, "a third resolved at 40 ms (\(atForty)); the old rule had \(NotchReveal.sheet(openness: 0.13).opacity)")
    }

    @Test("the old rule left an empty black shape for its first 90 ms; this one does not")
    func noEmptyBlob() {
        var worstGap: Double = 0
        var lastDark = 0.0
        play(opening: true) { t, openness, level in
            // Dark = the shape is out of the notch's bezel (5% open) yet the content is under a tenth.
            if openness > 0.05, level < 0.1 { lastDark = t }
        }
        worstGap = lastDark
        // The old rule's own dark time, for the record.
        var oldDark = 0.0
        play(opening: true) { t, openness, _ in
            if openness > 0.05, NotchReveal.sheet(openness: openness).opacity < 0.1 { oldDark = t }
        }
        #expect(oldDark > 0.08, "the rule before this one: dark until \(oldDark)")
        #expect(worstGap < 0.045, "the shape is dark for at most 45 ms (\(worstGap))")
    }

    @Test("the content is sharp well before the shape has finished")
    func resolvedEarly() throws {
        var ninety: Double?
        var settled: Double?
        var shapeNinety: Double?
        play(opening: true) { t, openness, level in
            if ninety == nil, level >= 0.9 { ninety = t }
            if settled == nil, level >= 0.995 { settled = t }
            if shapeNinety == nil, openness >= 0.9 { shapeNinety = t }
        }
        let sharp = try #require(ninety)
        let whole = try #require(settled)
        let shape = try #require(shapeNinety)
        #expect(sharp < 0.13, "90% resolved by 130 ms (\(sharp))")
        #expect(whole < 0.22, "whole inside 220 ms (\(whole))")
        #expect(sharp < shape, "the content resolves before the shape is 90% open (\(sharp) vs \(shape))")
    }

    // MARK: Leaving first

    @Test("fold content stays through the early frames and leaves before the shape lands")
    func contentLeavesFirst() throws {
        var gone: (t: Double, openness: CGFloat)?
        var tenth: (t: Double, openness: CGFloat)?
        play(opening: false) { t, openness, level in
            if tenth == nil, level <= 0.1 { tenth = (t, openness) }
            if gone == nil, level < 0.01 { gone = (t, openness) }
        }
        let nine = try #require(tenth)
        #expect(nine.openness > 0.25 && nine.openness < 0.5,
                "the shape has already folded substantially before the content goes dark")
        #expect(nine.t < 0.10, "ninety percent gone inside 100 ms")
        let out = try #require(gone)
        #expect(out.openness > 0 && out.openness < 0.15,
                "the last content clears while a small part of the fold remains")
        #expect(out.t < 0.15, "content clears inside 150 ms")
    }

    @Test("leaving is quicker than arriving, the way the fold is quicker than the grow")
    func directionAware() {
        #expect(NotchMotion.contentOut.response < NotchMotion.contentIn.response)
        #expect(NotchMotion.contentIn.overshoot < 0.005 && NotchMotion.contentOut.overshoot < 0.005,
                "content never bounces")
        #expect(NotchMotion.contentIn.settlingTime(tolerance: 0.02)
                < NotchMotion.open.settlingTime(tolerance: 0.02),
                "the content is in before the grow has settled")
        var clock = NotchContentClock(level: 0)
        #expect(clock.motion == NotchMotion.contentOut, "at rest and aimed at gone")
        clock.aim(open: true)
        #expect(clock.motion == NotchMotion.contentIn)
    }

    // MARK: One curve at any tick length

    @Test("60 Hz and 120 Hz draw the same curve")
    func tickLengthDoesNotMatter() {
        for open in [true, false] {
            var slow = NotchContentClock(level: open ? 0 : 1)
            var fast = slow
            slow.aim(open: open)
            fast.aim(open: open)
            for _ in 0..<12 { slow.advance(dt: 1.0 / 60) }
            for _ in 0..<24 { fast.advance(dt: 1.0 / 120) }
            #expect(abs(slow.level - fast.level) < 1e-5, "\(open ? "in" : "out"): \(slow.level) vs \(fast.level)")
        }
    }

    @Test("a late tick cannot wind the clock up, and a zero tick does nothing")
    func lateTicks() {
        var clock = NotchContentClock(level: 0)
        clock.aim(open: true)
        clock.advance(dt: 0)
        #expect(clock.level == 0)
        clock.advance(dt: 30)
        #expect(clock.level == 1 && clock.settled, "a slept display link lands it, never explodes it")
    }

    // MARK: Interrupting

    @Test("turning around at any moment keeps the level and the speed it had: no pop")
    func reversalIsContinuous() {
        for opening in [true, false] {
            for k in 1...120 {
                var clock = NotchContentClock(level: opening ? 0 : 1)
                clock.aim(open: opening)
                clock.advance(dt: Double(k) * 0.002)
                let level = clock.level
                let speed = clock.velocity
                clock.aim(open: !opening)
                #expect(clock.level == level, "level jumped at \(k * 2) ms")
                #expect(clock.velocity == speed, "speed jumped at \(k * 2) ms")
            }
        }
    }

    @Test("a reversal at any moment of a grow or a fold never steps the content more than a frame's worth")
    func noStepAnywhere() {
        for opening in [true, false] {
            for k in 1...100 {
                let turnAt = Double(k) * 0.004
                var spring = NotchFrameSpring(at: opening ? idle : card)
                let first = opening ? card : idle
                spring.retarget(first, motion: NotchMotion.frameMotion(from: spring.frame, to: first))
                var clock = NotchContentClock(level: opening ? 0 : 1)
                clock.aim(open: opening)
                var t = 0.0
                var turned = false
                var previous = clock.level
                var worst: CGFloat = 0
                var peak = clock.level
                while t < 0.7 {
                    if !turned, t >= turnAt {
                        turned = true
                        let back = opening ? idle : card
                        spring.retarget(back, motion: NotchMotion.frameMotion(from: spring.frame, to: back))
                        clock.aim(open: !opening)
                    }
                    spring.integrate(dt: 1.0 / 240)
                    clock.advance(dt: 1.0 / 240)
                    t += 1.0 / 240
                    worst = max(worst, abs(clock.level - previous))
                    previous = clock.level
                    peak = max(peak, clock.level)
                    #expect(clock.level >= 0 && clock.level <= 1)
                }
                // At 240 Hz the fastest the content may move is a sixth of its range a frame.
                #expect(worst < 0.17, "\(opening ? "grow" : "fold") reversed at \(turnAt): stepped \(worst)")
                // Whichever way it ends, it ends there, whole or gone.
                #expect(clock.level == (opening ? 0 : 1), "ended at \(clock.level)")
            }
        }
    }

    @Test("a half-resolved sheet turned around leaves from where it was, not from the top")
    func leavesFromWhereItWas() {
        var clock = NotchContentClock(level: 0)
        clock.aim(open: true)
        clock.advance(dt: 0.05)
        let mid = clock.level
        #expect(mid > 0.2 && mid < 0.9)
        clock.aim(open: false)
        clock.advance(dt: 1.0 / 240)
        #expect(clock.level < mid + 0.05, "it does not carry on up for more than the momentum it had")
        for _ in 0..<60 { clock.advance(dt: 1.0 / 240) }
        #expect(clock.level == 0 && clock.settled)
    }

    // MARK: What it draws

    @Test("the sheet by level runs from dark, soft and small to whole, with no step at either end")
    func sheetByLevel() {
        let closed = NotchReveal.sheet(level: 0)
        #expect(closed.opacity == 0 && closed.blur == NotchReveal.sheetBlur)
        #expect(closed.scale == NotchReveal.sheetScale && closed.lift == -NotchReveal.sheetLift)
        #expect(NotchReveal.sheet(level: 1) == .settled)
        #expect(NotchReveal.sheet(level: 1.3) == .settled)
        #expect(NotchReveal.sheet(level: -0.2) == NotchReveal.sheet(level: 0))
        var previous = NotchReveal.sheet(level: 0)
        for i in 1...100 {
            let now = NotchReveal.sheet(level: CGFloat(i) / 100)
            #expect(now.opacity >= previous.opacity && now.blur <= previous.blur
                    && now.scale >= previous.scale && now.lift >= previous.lift)
            previous = now
        }
    }

    @Test("a notice by level is dark, soft and a few points up at 0, and whole at 1")
    func noticeByLevel() {
        let closed = NotchReveal.notice(level: 0)
        #expect(closed.opacity == 0 && closed.blur == NotchMotion.noticeBlur && closed.lift == -NotchMotion.noticeSlide)
        #expect(NotchReveal.notice(level: 1) == .settled)
        #expect(NotchReveal.notice(level: 2) == .settled && NotchReveal.notice(level: -1) == closed)
        var previous = closed
        for i in 1...50 {
            let now = NotchReveal.notice(level: CGFloat(i) / 50)
            #expect(now.opacity >= previous.opacity && now.blur <= previous.blur && now.lift >= previous.lift)
            previous = now
        }
    }

    @Test("a notice waits for its lip: nothing until a fifth down, all of it from three fifths")
    func noticeGate() {
        #expect(NotchReveal.noticeGate(openness: 0) == 0)
        #expect(NotchReveal.noticeGate(openness: NotchReveal.noticeGateStart) == 0)
        #expect(NotchReveal.noticeGate(openness: NotchReveal.noticeGateEnd) == 1)
        #expect(NotchReveal.noticeGate(openness: 1.2) == 1)
        #expect(NotchReveal.noticeGateStart < NotchReveal.noticeStart && NotchReveal.noticeGateEnd < NotchReveal.noticeEnd,
                "sooner than the rule it replaces")
        var previous: CGFloat = 0
        for i in 0...100 {
            let now = NotchReveal.noticeGate(openness: CGFloat(i) / 100)
            #expect(now >= previous)
            previous = now
        }
    }

    @Test("the rows cascade by level, the last whole before the sheet is, and leave in reverse")
    func rowsByLevel() {
        for step in 0..<NotchReveal.rowSteps {
            for i in 0...20 {
                let level = CGFloat(i) / 20
                #expect(NotchReveal.row(step: step, level: level) >= NotchReveal.row(step: step + 1, level: level),
                        "step \(step) is never behind the one below it at level \(level)")
            }
        }
        #expect(NotchReveal.row(step: 0, level: 0) == 0)
        #expect(NotchReveal.row(step: 99, level: 1) == 1)
        #expect(NotchReveal.row(step: 99, level: 0.9) >= 0.99, "the last row is whole by nine tenths")
        #expect(NotchReveal.row(step: -3, level: 1) == 1)
        #expect(NotchReveal.row(step: 99, level: 1) == NotchReveal.row(step: NotchReveal.rowSteps, level: 1))
        #expect(NotchReveal.row(step: NotchReveal.rowSteps, level: 0.9) < NotchReveal.row(step: 0, level: 0.9)
                || NotchReveal.row(step: NotchReveal.rowSteps, level: 0.9) == 1)
    }

    @Test("the sheet stands as wide as the shape, grows with it, and is whole at the card's width")
    func fitFollowsTheWidth() {
        #expect(NotchReveal.fit(shapeWidth: 320, cardWidth: 320) == 1)
        #expect(NotchReveal.fit(shapeWidth: 345, cardWidth: 320) == 1, "overshoot never enlarges it")
        #expect(NotchReveal.fit(shapeWidth: 185, cardWidth: 320) < 0.6)
        #expect(NotchReveal.fit(shapeWidth: 0, cardWidth: 320) == NotchReveal.fitFloor)
        // Scaled, the sheet is never wider than the shape that uncovers it.
        for width in stride(from: CGFloat(185), through: 320, by: 5) {
            #expect(320 * NotchReveal.fit(shapeWidth: width, cardWidth: 320) <= width)
        }
        var previous = NotchReveal.fit(shapeWidth: 185, cardWidth: 320)
        for width in stride(from: CGFloat(186), through: 320, by: 1) {
            let now = NotchReveal.fit(shapeWidth: width, cardWidth: 320)
            #expect(now >= previous)
            previous = now
        }
        #expect(NotchReveal.fit(shapeWidth: 100, cardWidth: 10) == 1, "a degenerate card is left alone")
    }
}
