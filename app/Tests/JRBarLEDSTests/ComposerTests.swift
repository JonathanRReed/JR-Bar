import Foundation
import Testing
@testable import JRBarLEDS

/// The layer composer: whatever the layers, the text it writes parses on
/// the strip and the Dot, fits the budget, and plays exactly as written —
/// the presentation compiler has nothing left to slow.
@Suite("LEDS composer")
struct ComposerTests {
    private static let amber = RGB8(hex: "#FF9F0A")!
    private static let blue = RGB8(hex: "#0A84FF")!
    private static let white = RGB8(hex: "#FFFFFF")!
    private static let red = RGB8(hex: "#FF0000")!

    private static func sampler(_ text: String, leds: Int = 8) throws -> LEDSSampler {
        LEDSSampler(program: try LEDSProgram.parse(text, ledCount: leds), ledCount: leds)
    }

    @Test func everyCombinationIsAFirmwareProgramTheCompilerLeavesAlone() {
        let bases: [LEDSComposition.Base] = [.solid(Self.amber), .gradient(Self.amber, Self.blue), .solid(.black)]
        let motions: [LEDSComposition.Motion] = [.steady, .breathe(periodMs: 1400), .breathe(periodMs: 100),
                                                 .roll(periodMs: 2000, leftward: false), .roll(periodMs: 300, leftward: true)]
        let accents: [LEDSComposition.Accent?] = [nil, .init(color: Self.white, stepMs: 150),
                                                  .init(color: Self.red, stepMs: 60, leftward: true)]
        let overrides: [[Int: RGB8]] = [[:], [0: Self.red, 7: Self.white], [9: Self.white]]
        for base in bases {
            for motion in motions {
                for accent in accents {
                    for held in overrides {
                        for brightness in [255, 96] {
                            let composed = LEDSComposer.compose(LEDSComposition(base: base, motion: motion, accent: accent,
                                                                                overrides: held, brightness: brightness))
                            let analysis = LEDSStudioAnalysis(composed.text)
                            let label = "\(base) \(motion) \(String(describing: accent)) \(held) \(brightness)"
                            #expect(analysis.strip.accepted, "\(label)\n\(composed.text)")
                            #expect(analysis.dot.accepted, "\(label)")
                            #expect(analysis.bytes <= LEDSLimits.maxProgramBytes, "\(label)")
                            #expect(analysis.lines <= LEDSLimits.maxProgramLines, "\(label)")
                            #expect(analysis.compiled.accepted, "\(label)")
                            #expect(!analysis.compiled.transformed, "\(label): the compiler rewrote\n\(composed.text)\nas\n\(analysis.compiled.program)")
                        }
                    }
                }
            }
        }
    }

    @Test func aSteadyBaseIsOneLine() {
        #expect(LEDSComposer.compose(LEDSComposition(base: .solid(Self.amber))).text == "#FF9F0A")
        #expect(LEDSComposer.compose(LEDSComposition(base: .solid(Self.amber), brightness: 128)).text == "brightness 128\n#FF9F0A")
        #expect(LEDSComposer.compose(LEDSComposition(base: .solid(.black))).text == "off")
        let gradient = LEDSComposer.compose(LEDSComposition(base: .gradient(Self.amber, Self.blue))).text
        #expect(gradient.hasPrefix("#FF9F0A ") && gradient.hasSuffix(" #0A84FF"))
        #expect(gradient.split(separator: " ").count == 8)
    }

    @Test func theAccentVisitsEachLEDOverTheHeldBase() throws {
        let composed = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue),
                                                            accent: .init(color: Self.white, stepMs: 300),
                                                            overrides: [5: Self.amber]))
        #expect(composed.dropped.isEmpty && composed.adjusted.isEmpty)
        let sampler = try Self.sampler(composed.text)
        for step in 0..<8 {
            let codes = sampler.codes(atMilliseconds: step * 300 + 150)
            #expect(codes[step] == Self.white, "step \(step): the accent is on LED \(step)")
            for other in 0..<8 where other != step {
                #expect(codes[other] == (other == 5 ? Self.amber : Self.blue), "step \(step), LED \(other)")
            }
        }
    }

    @Test func aLeftwardAccentStartsAtTheFarEnd() throws {
        let composed = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue),
                                                            accent: .init(color: Self.white, stepMs: 300, leftward: true)))
        let sampler = try Self.sampler(composed.text)
        #expect(sampler.codes(atMilliseconds: 150)[7] == Self.white)
        #expect(sampler.codes(atMilliseconds: 450)[6] == Self.white)
    }

    @Test func aTooQuickAccentIsSlowedToALapTheCompilerAllows() {
        let quick = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), accent: .init(color: Self.white, stepMs: 20)))
        #expect(quick.text.contains("63ms none"), "eight steps of 63 ms make the 500 ms lap")
        #expect(quick.adjusted.count == 1)
        let red = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), accent: .init(color: Self.red, stepMs: 20)))
        #expect(red.text.contains("125ms none"), "saturated red laps no quicker than 1 s")
        #expect(red.adjusted.first?.contains("saturated red") == true)
    }

    @Test func aHeldLEDStaysStillThroughABreath() throws {
        let composed = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), motion: .breathe(periodMs: 2000),
                                                            overrides: [0: Self.amber]))
        let sampler = try Self.sampler(composed.text)
        var seen = Set<RGB8>()
        var breathing = Set<RGB8>()
        for ms in stride(from: 0, to: 2500, by: 50) {
            let codes = sampler.codes(atMilliseconds: ms)
            seen.insert(codes[0])
            breathing.insert(codes[3])
        }
        #expect(seen == [Self.amber], "the held LED never moves")
        #expect(breathing.count > 5, "the rest of the base breathes")
    }

    @Test func whatCannotPlayTogetherIsLeftOutAndSaid() {
        let breathe = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), motion: .breathe(periodMs: 2000),
                                                           accent: .init(color: Self.white, stepMs: 300)))
        #expect(breathe.dropped.count == 1)
        #expect(!breathe.text.contains(Self.white.hex))

        let roll = LEDSComposer.compose(LEDSComposition(base: .gradient(Self.amber, Self.blue),
                                                        motion: .roll(periodMs: 2000, leftward: false),
                                                        overrides: [3: Self.white]))
        #expect(roll.dropped.first?.contains("held LEDs") == true)
        #expect(!roll.text.contains(Self.white.hex))

        let flat = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), motion: .roll(periodMs: 2000, leftward: false)))
        #expect(flat.dropped.first?.contains("single colour") == true)
        #expect(flat.text == "#0A84FF")
    }

    @Test func theAccentRidesARoll() throws {
        let composed = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), motion: .roll(periodMs: 1600, leftward: false),
                                                            accent: .init(color: Self.white, stepMs: 400)))
        #expect(composed.dropped.isEmpty)
        #expect(composed.text.contains("roll-right 1600ms linear"))
        let sampler = try Self.sampler(composed.text)
        // After the 250 ms settle, a quarter of the loop moves the accent two LEDs on.
        let quarter = sampler.codes(atMilliseconds: 250 + 400)
        #expect(quarter.firstIndex(of: Self.white) == 2)
    }

    @Test func theDotPlaysTheFirstTwoLEDsOfTheSameText() throws {
        let composed = LEDSComposer.compose(LEDSComposition(base: .solid(Self.blue), accent: .init(color: Self.white, stepMs: 300)))
        let dot = try Self.sampler(composed.text, leds: 2)
        #expect(dot.codes(atMilliseconds: 150) == [Self.white, Self.blue])
        #expect(dot.codes(atMilliseconds: 450) == [Self.blue, Self.white])
    }
}
