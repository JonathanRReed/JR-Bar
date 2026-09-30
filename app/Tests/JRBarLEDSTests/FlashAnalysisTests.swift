import Foundation
import Testing
@testable import JRBarLEDS

/// The Swift measured-flash pass must report the numbers Python's
/// `flash_analysis.analyse` reports for the same program, because the
/// presentation compiler decides how much to slow a loop from them.
/// `flash.json` is written by `app/scripts/gen_leds_fixtures.py`.
@Suite struct FlashAnalysisTests {
    @Test func matchesPythonFlashAnalysis() throws {
        let fixtures = try Fixtures.flash()
        #expect(fixtures.count > 40)
        var failures: [String] = []
        for fixture in fixtures {
            let program = try LEDSProgram.parse(fixture.program, ledCount: fixture.led_count)
            let measured = LEDSFlashAnalysis.analyse(program.steps, ledCount: fixture.led_count)
            let hertzMatches = abs(measured.hertz - fixture.hertz) <= 1e-9
            let areaMatches = abs(measured.peakArea - fixture.peak_area) <= 1e-12
            let countsMatch = measured.flashes == fixture.flashes && measured.spanMs == fixture.span_ms
            if !(hertzMatches && areaMatches && countsMatch) {
                failures.append("\(fixture.program.debugDescription) (\(fixture.led_count) LED)\n   swift: hertz=\(measured.hertz) flashes=\(measured.flashes) span=\(measured.spanMs) area=\(measured.peakArea)\n   python: hertz=\(fixture.hertz) flashes=\(fixture.flashes) span=\(fixture.span_ms) area=\(fixture.peak_area)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test func aWholeBarBlinkMeasuresItsRate() throws {
        let program = try LEDSProgram.parse("#FFFFFF 100ms none\n#000000 100ms none\nrepeat", ledCount: 8)
        let measured = LEDSFlashAnalysis.analyse(program.steps, ledCount: 8)
        #expect(measured.flashing)
        #expect(abs(measured.hertz - 5.0) < 1e-9)
        #expect(measured.peakArea == 1.0)
    }

    @Test func aTravellingHeadNeverFlashes() throws {
        var lines = ["0:#00CCFF 80ms none"]
        for led in 1..<8 {
            lines.append("\(led - 1):#000000 80ms none; \(led):#00CCFF 80ms none")
        }
        lines.append("7:#000000 80ms none")
        lines.append("repeat")
        let program = try LEDSProgram.parse(lines.joined(separator: "\n"), ledCount: 8)
        let measured = LEDSFlashAnalysis.analyse(program.steps, ledCount: 8)
        #expect(!measured.flashing)
        #expect(measured.hertz == 0)
        #expect(measured.peakArea < LEDSFlashAnalysis.areaFraction)
    }

    @Test func aRollIsHeldAndOnlyCostsItsTime() throws {
        let program = try LEDSProgram.parse("#FFFFFF #000000 #FFFFFF #000000 #FFFFFF #000000 #FFFFFF #000000 400ms none\nroll-right 400ms linear\nrepeat", ledCount: 8)
        let measured = LEDSFlashAnalysis.analyse(program.steps, ledCount: 8)
        #expect(!measured.flashing)
    }

    @Test func aTwoLEDBlinkIsExactlyTheAreaThreshold() throws {
        let program = try LEDSProgram.parse("0:#FFFFFF 100ms none; 1:#FFFFFF 100ms none\n0:#000000 100ms none; 1:#000000 100ms none\nrepeat", ledCount: 8)
        let measured = LEDSFlashAnalysis.analyse(program.steps, ledCount: 8)
        #expect(measured.peakArea == LEDSFlashAnalysis.areaFraction)
        #expect(measured.flashing, "two of eight LEDs is a quarter of the field, which counts")
    }

    @Test func relativeLuminanceFollowsTheStandard() {
        #expect(LEDSFlashAnalysis.relativeLuminance(.black) == 0)
        #expect(abs(LEDSFlashAnalysis.relativeLuminance(RGB8(r: 255, g: 255, b: 255)) - 1.0) < 1e-12)
        // Pure green carries 0.7152 of the light, red 0.2126, blue 0.0722.
        #expect(abs(LEDSFlashAnalysis.relativeLuminance(RGB8(r: 0, g: 255, b: 0)) - 0.7152) < 1e-12)
        #expect(abs(LEDSFlashAnalysis.relativeLuminance(RGB8(r: 255, g: 0, b: 0)) - 0.2126) < 1e-12)
        #expect(abs(LEDSFlashAnalysis.relativeLuminance(RGB8(r: 0, g: 0, b: 255)) - 0.0722) < 1e-12)
    }

    @Test func halfWaysRoundToEvenLikePython() {
        // 253 / 2 = 126.5: Python's round() gives 126, the default Swift
        // rounding 127. The port has to agree with Python.
        let transition = LEDSFlashAnalysis.Transition(
            delayMs: 0, durationMs: 100, easing: .linear,
            start: .black, target: RGB8(r: 253, g: 0, b: 0), returns: false
        )
        #expect(transition.at(50).r == 126)
        let other = LEDSFlashAnalysis.Transition(
            delayMs: 0, durationMs: 100, easing: .linear,
            start: .black, target: RGB8(r: 255, g: 0, b: 0), returns: false
        )
        #expect(other.at(50).r == 128, "127.5 rounds to the even 128")
    }

    @Test func aPulseReturnsToWhereItStarted() {
        let transition = LEDSFlashAnalysis.Transition(
            delayMs: 0, durationMs: 100, easing: .pulse,
            start: RGB8(r: 10, g: 20, b: 30), target: RGB8(r: 200, g: 200, b: 200), returns: true
        )
        #expect(transition.resting == RGB8(r: 10, g: 20, b: 30))
        #expect(transition.at(100) == RGB8(r: 10, g: 20, b: 30))
        #expect(transition.at(50).g > 190)
    }

    @Test func framesAreMeanedTheWayPythonSumsFloats() {
        // CPython 3.12 sums floats with compensation: 0.6, not 0.6000000000000001.
        #expect(LEDSFlashAnalysis.pythonSum([0.1, 0.2, 0.3]) == 0.6)
        #expect(LEDSFlashAnalysis.pythonSum([]) == 0)
        #expect(LEDSFlashAnalysis.pythonSum([0.25]) == 0.25)
    }

    @Test func aVeryLongLoopStopsAtTheSampleBudget() throws {
        let program = try LEDSProgram.parse("#FFFFFF 20s none\n#000000 20s none\nrepeat", ledCount: 8)
        let rendered = LEDSFlashAnalysis.renderLuminance(program.steps, ledCount: 8, passes: 2)
        #expect(rendered.frames.count <= LEDSFlashAnalysis.maxSamples)
    }
}
