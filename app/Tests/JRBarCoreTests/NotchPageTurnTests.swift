import Foundation
import Testing
@testable import JRBarCore

/// The card's page turn as pure numbers: which side a page arrives from,
/// how readable it is at each moment of the spring, how far it travels,
/// what Reduce Motion keeps, and when the island taps a trackpad. Time is
/// only ever an argument.
@Suite("Notch page turn")
struct NotchPageTurnTests {
    private typealias Turn = NotchPageTurn

    @Test("a later page arrives from the right, an earlier one from the left")
    func directions() {
        #expect(Turn.Direction(from: 0, to: 1) == .fromRight)
        #expect(Turn.Direction(from: 1, to: 0) == .fromLeft)
    }

    @Test("the arriving page starts a short way off, on its own side, and lands home")
    func offsetEnds() {
        #expect(Turn.offset(level: 0, direction: .fromRight) == Turn.travel)
        #expect(Turn.offset(level: 0, direction: .fromLeft) == -Turn.travel)
        #expect(Turn.offset(level: 1, direction: .fromRight) == 0)
        #expect(Turn.offset(level: 1, direction: .fromLeft) == 0)
        #expect(Turn.travel <= 24, "a frequent gesture must not move the whole 320 pt card")
        // Past the ends the spring's overshoot never moves the page the other way.
        #expect(Turn.offset(level: 1.004, direction: .fromRight) == 0)
        #expect(Turn.offset(level: -0.1, direction: .fromRight) == Turn.travel)
    }

    @Test("opacity and blur never step: each moves a little at every thousandth of the level")
    func smooth() {
        var lastOpacity: CGFloat = 0
        var lastBlur = Turn.blurRadius(level: 0)
        #expect(Turn.opacity(level: 0) == 0)
        #expect(lastBlur == Turn.blur)
        for i in 1...1000 {
            let level = CGFloat(i) / 1000
            let opacity = Turn.opacity(level: level)
            let blur = Turn.blurRadius(level: level)
            #expect(opacity >= lastOpacity, "opacity only rises")
            #expect(opacity - lastOpacity < 0.01)
            #expect(blur <= lastBlur, "blur only clears")
            lastOpacity = opacity
            lastBlur = blur
        }
        #expect(lastOpacity == 1)
        #expect(lastBlur == 0)
    }

    @Test("the page is fully opaque before it has stopped moving")
    func opaqueEarly() {
        #expect(Turn.opacity(level: Turn.opaqueBy) == 1)
        #expect(Turn.offset(level: Turn.opaqueBy, direction: .fromRight) > 0,
                "still travelling when it is already readable")
    }

    @Test("the turn rides a spring that is readable within 90 ms and home within 0.25 s, with no bounce")
    func springNumbers() {
        let spring = NotchMotion.pageTurn
        // Opaque at about 70 ms: the rows can be read before they stop.
        #expect(spring.step(at: 0.09) >= Turn.opaqueBy)
        #expect(spring.step(at: 0.016) > 0.05, "the first frame already moves")
        #expect(spring.step(at: 0.25) > 0.97)
        #expect(spring.overshoot < 0.002)
        // Quicker than the grow it happens inside, calmer than a fold.
        #expect(spring.step(at: 0.1) > NotchMotion.open.step(at: 0.1))
        #expect(spring.settlingTime() < 0.35)
    }

    @Test("Reduce Motion keeps the fade and drops the slide and the blur")
    func reducedKeepsOnlyTheFade() {
        for i in 0...100 {
            let level = CGFloat(i) / 100
            let fade = Turn.reducedOpacity(level: level)
            #expect(fade == level)
        }
        #expect(Turn.reducedOpacity(level: 1.004) == 1)
        #expect(Turn.reducedOpacity(level: -0.2) == 0)
    }

    @Test("the edge nudge is a small push, quick out and slower back, under half a second")
    func edgeNudge() {
        #expect(Turn.edgePeak > 0 && Turn.edgePeak <= 8)
        #expect(Turn.edgeOut < Turn.edgeBack, "friction: out quickly, back slowly")
        #expect(Turn.edgeDuration < 0.5)
        #expect(Turn.edgePeak < Turn.travel, "less than a turn's own slide")
    }
}
