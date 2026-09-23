import Foundation
import Testing
@testable import JRBarCore

/// The colour-vision check behind Settings › Lighting: pairs that
/// collapse for a dichromat are named, and the nudge pulls one colour
/// apart by lightness alone until every vision tells them apart.
@Suite("Colour vision check")
struct ColorVisionTests {
    @Test func identicalColoursCollideForEveryone() throws {
        let collision = try #require(ColorVision.collisions([("a", "#336699"), ("b", "#336699")]).first)
        #expect(collision.distance < 0.001)
        #expect(ColorVision.typical.distance("#336699", "#336699") == 0)
    }

    @Test func redAndGreenCollapseForProtanAndDeutanOnly() throws {
        // A classic confusion pair: equal-ish lightness red and green.
        let red = "#C0392B", green = "#6B8E23"
        let typical = try #require(ColorVision.typical.distance(red, green))
        #expect(typical > ColorVision.collisionDistance, "typical vision tells them apart")
        let worst = try #require(ColorVision.worst(red, green))
        #expect(worst.vision == .protan || worst.vision == .deutan)
        #expect(worst.distance < typical / 2)
    }

    @Test func blackAndWhiteNeverCollide() {
        #expect(ColorVision.collisions([("black", "#000000"), ("white", "#FFFFFF")]).isEmpty)
        #expect((ColorVision.worst("#000000", "#FFFFFF")?.distance ?? 0) > 90)
    }

    @Test func theDefaultStateColoursHaveOneTritanWeakPair() {
        // working, done, ask, error — the lights' own defaults. Ask and
        // error stay apart for everyone; the one weak pair is cyan
        // working against green done for a tritanope, which the rhythm
        // still separates (working moves, done holds) — and which the
        // Lighting page now names instead of hiding.
        let states = [("working", "#00E5FF"), ("done", "#00FF66"), ("ask", "#FF3A00"), ("error", "#B00020")]
        let collisions = ColorVision.collisions(states.map { (id: $0.0, hex: $0.1) })
        #expect(collisions.map { "\($0.first)/\($0.second)/\($0.vision)" } == ["working/done/tritan"])
    }

    @Test func aNudgeSeparatesByLightnessAndKeepsTheHue() throws {
        let red = "#C0392B", green = "#6B8E23"
        let nudged = try #require(ColorVision.nudge(green, awayFrom: red))
        let worst = try #require(ColorVision.worst(nudged, red))
        #expect(worst.distance >= ColorVision.collisionDistance)
        #expect(ColorVision.collisions([("red", red), ("green", nudged)]).isEmpty)
        // Hue kept: the a*/b* angle barely moves.
        func hue(_ hex: String) -> Double {
            let c = ColorVision.rgb(hex)!
            let lab = ColorVision.lab(linear: (ColorVision.linear(c.r), ColorVision.linear(c.g), ColorVision.linear(c.b)))
            return atan2(lab.b, lab.a)
        }
        #expect(abs(hue(nudged) - hue(green)) < 0.35)
    }

    @Test func labRoundTripsThroughHex() throws {
        for hex in ["#FF3A00", "#00E5FF", "#8B93A7", "#123456"] {
            let c = try #require(ColorVision.rgb(hex))
            let lab = ColorVision.lab(linear: (ColorVision.linear(c.r), ColorVision.linear(c.g), ColorVision.linear(c.b)))
            #expect(ColorVision.hexFromLab(l: lab.l, a: lab.a, b: lab.b) == hex)
        }
        #expect(ColorVision.rgb("nope") == nil)
    }
}
