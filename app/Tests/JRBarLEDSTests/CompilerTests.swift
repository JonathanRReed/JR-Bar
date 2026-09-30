import Foundation
import Testing
@testable import JRBarLEDS

@Suite struct CompilerTests {
    @Test func matchesPythonPresentationCompiler() throws {
        let fixtures = try Fixtures.compiler()
        #expect(fixtures.count > 20)
        var failures: [String] = []
        for fixture in fixtures {
            let result = LEDSPresentationCompiler.compile(fixture.program, ledCount: fixture.led_count)
            if result.accepted != fixture.accepted || result.transformed != fixture.transformed
                || result.reasons != fixture.reasons || result.program != fixture.output {
                failures.append("\(fixture.program.debugDescription) (\(fixture.led_count) LED)\n   swift: accepted=\(result.accepted) transformed=\(result.transformed) reasons=\(result.reasons)\n          \(result.program.debugDescription)\n   python: accepted=\(fixture.accepted) transformed=\(fixture.transformed) reasons=\(fixture.reasons)\n          \(fixture.output.debugDescription)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test func strobeIsSlowedNeverRefused() {
        let result = LEDSPresentationCompiler.compile("#ff0000 50ms none\n#000000 50ms none\nrepeat")
        #expect(result.accepted)
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == "#FF0000 500ms none\n#000000 500ms none\nrepeat")
        let program = try? LEDSProgram.parse(result.program)
        #expect(program?.cycleDuration == 1.0)
    }

    @Test func invalidProgramFallsBack() {
        let result = LEDSPresentationCompiler.compile("#fff", fallback: "off")
        #expect(!result.accepted)
        #expect(result.program == "off")
        #expect(result.reasons == ["invalid_program"])
    }

    // MARK: The measured-flash pass and the indexed exemption

    /// `bright`/`#000000` whole-bar lines, `cycles` times, then `repeat`.
    static func alternating(_ bright: String, phaseMs: Int, cycles: Int) -> String {
        var lines: [String] = []
        for _ in 0..<cycles {
            lines.append("\(bright) \(phaseMs)ms none")
            lines.append("#000000 \(phaseMs)ms none")
        }
        lines.append("repeat")
        return lines.joined(separator: "\n")
    }

    @Test func sustainedWholeBarBlinkIsSlowedByMeasurement() {
        // Ten 100 ms lines make a 1000 ms loop: past the 500 ms cycle floor,
        // so only the measured 5 Hz can slow it.
        let text = Self.alternating("#FFFFFF", phaseMs: 100, cycles: 5)
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.accepted)
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == Self.alternating("#FFFFFF", phaseMs: 300, cycles: 5))
    }

    @Test func measuredFlashSlowsAFastLoopLongerThanTheMinimumCycle() {
        // Three 100 ms white/black pairs: a 600 ms loop clears the 500 ms
        // cycle floor while flashing five times a second.
        let text = Self.alternating("#FFFFFF", phaseMs: 100, cycles: 3)
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == Self.alternating("#FFFFFF", phaseMs: 300, cycles: 3))
    }

    @Test func saturatedRedShortBlinksAreSlowedToOneHertz() {
        let text = Self.alternating("#FF0000", phaseMs: 100, cycles: 5)
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == Self.alternating("#FF0000", phaseMs: 500, cycles: 5))
        let slowed = try? LEDSProgram.parse(result.program)
        let measured = slowed.map { LEDSFlashAnalysis.analyse($0.steps, ledCount: 8).hertz } ?? .infinity
        #expect(measured <= 1.0)
    }

    @Test func travellingHeadIsNotSlowed() {
        var lines = ["0:#00CCFF 80ms none"]
        for led in 1..<8 {
            lines.append("\(led - 1):#000000 80ms none; \(led):#00CCFF 80ms none")
        }
        lines.append("7:#000000 80ms none")
        lines.append("repeat")
        let text = lines.joined(separator: "\n")
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.accepted)
        #expect(!result.transformed)
        #expect(result.reasons.isEmpty)
        #expect(result.program == text)
    }

    @Test func untimedIndexedLinesKeepPythonsTiming() {
        // Python exempts a named-LED paint from the phase floor and stretches
        // only the loop, to 336 ms a line. A forced 250 ms floor would differ.
        let result = LEDSPresentationCompiler.compile("0:#FF0000\n1:#FF0000\n2:#000000\nrepeat")
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == "0:#FF0000 336ms\n1:#FF0000 336ms\n2:#000000 336ms\nrepeat")
    }

    @Test func indexedPaintsKeepTheirPhaseInsideALoop() {
        // Untimed named-LED lines inside a loop that already clears the floor
        // come back exactly as written: no phase floor, no reason.
        let result = LEDSPresentationCompiler.compile("0:#FFFFFF\n1:#00FF00\n#000000 500ms\nrepeat")
        #expect(result.accepted)
        #expect(result.reasons.isEmpty)
        #expect(result.program == "0:#FFFFFF\n1:#00FF00\n#000000 500ms\nrepeat")
    }

    @Test func exactlyTwoHertzIsUnchanged() {
        let text = "#FFFFFF 250ms none\n#000000 250ms none\nrepeat"
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.reasons.isEmpty)
        #expect(!result.transformed)
        #expect(result.program == text)
    }

    @Test func exactlyOneHertzOfRedIsUnchanged() {
        let text = "#FF0000 500ms none\n#000000 500ms none\nrepeat"
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.reasons.isEmpty)
        #expect(result.program == text)
    }

    @Test func justOverTwoHertzIsSlowedByTheWholeNumberThatBringsItUnder() {
        // 2.5 Hz: the smallest whole factor that gets under 2 Hz is 2.
        let text = "#FFFFFF 200ms none\n#000000 200ms none\n#FFFFFF 200ms none\n#000000 200ms none\nrepeat"
        let result = LEDSPresentationCompiler.compile(text)
        #expect(result.reasons == ["loop_cadence_clamped"])
        #expect(result.program == "#FFFFFF 400ms none\n#000000 400ms none\n#FFFFFF 400ms none\n#000000 400ms none\nrepeat")
    }

    @Test func compileIsIdempotentOverEveryFixture() throws {
        for fixture in try Fixtures.compiler() where fixture.accepted {
            let once = LEDSPresentationCompiler.compile(fixture.program, ledCount: fixture.led_count)
            let twice = LEDSPresentationCompiler.compile(once.program, ledCount: fixture.led_count)
            #expect(twice.program == once.program, Comment(rawValue: "\(fixture.program.debugDescription) is not stable under a second compile"))
        }
    }
}
