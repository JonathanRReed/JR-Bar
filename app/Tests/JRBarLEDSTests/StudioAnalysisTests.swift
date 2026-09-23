import Foundation
import Testing
@testable import JRBarLEDS

/// The LEDS Studio's verdicts: the firmware's own errors at line and
/// column for both device shapes, the 512-byte / 20-line budget, and what
/// the presentation compiler changes before anything plays.
@Suite("LEDS Studio analysis")
struct StudioAnalysisTests {
    @Test func aCleanProgramIsPlayableOnBothDevices() {
        let analysis = LEDSStudioAnalysis("#404040 1.4s pulse\noff 400ms none\nrepeat\n")
        #expect(analysis.strip.accepted)
        #expect(analysis.dot.accepted)
        #expect(analysis.playable)
        #expect(analysis.firstError == nil)
        #expect(analysis.bytes == "#404040 1.4s pulse\noff 400ms none\nrepeat\n".utf8.count)
        #expect(analysis.lines == 3, "one trailing break does not start a line")
        #expect(analysis.compilerNote == nil, "a 1.8 s breathe plays as written")
    }

    @Test func errorsCarryTheFirmwaresLineAndColumn() {
        let analysis = LEDSStudioAnalysis("off\n#FF00FF 1s\n0:#FF00FF 1:#fff")
        let error = analysis.strip.error
        #expect(error?.kind == .badIndex)
        #expect(error?.line == 3)
        #expect(error?.column == 11)
        #expect(!analysis.playable)
        #expect(analysis.firstError == error)
    }

    @Test func budgetCountsBytesAndPhysicalLines() {
        let long = String(repeating: "#FF00FF 1s\n", count: 50)
        let tooLong = LEDSStudioAnalysis(long)
        #expect(tooLong.bytes > LEDSLimits.maxProgramBytes)
        #expect(tooLong.byteFraction > 1)
        #expect(tooLong.strip.error?.kind == .tooLong)
        let manyLines = LEDSStudioAnalysis(String(repeating: "off\n", count: 21))
        #expect(manyLines.lines == 21)
        #expect(manyLines.lineFraction > 1)
        #expect(manyLines.strip.error?.kind == .tooManyLines)
        // Carriage returns break lines too.
        #expect(LEDSStudioAnalysis("off\r\n#FF00FF\roff").lines == 3)
        #expect(LEDSStudioAnalysis("").lines == 0)
    }

    @Test func theDotSkipsLinesForLEDsItDoesNotHave() {
        let analysis = LEDSStudioAnalysis("0:#FF0000 200ms none\n5:#00FF00 200ms none\n1:#0000FF 7:#FFFFFF 200ms none\nrepeat")
        #expect(analysis.dot.accepted)
        #expect(analysis.dot.ignoredLines == [2], "line 3 still reaches LED 1")
        #expect(analysis.strip.ignoredLines.isEmpty)
    }

    @Test func compilerChangesAreNamedInOneSentence() {
        let fast = LEDSStudioAnalysis("#FF0000 100ms none\noff 100ms none\nrepeat")
        #expect(fast.playable)
        #expect(fast.compiled.transformed)
        #expect(fast.compilerNote?.hasPrefix("Slowed to stay under 2 Hz") == true)
        #expect(fast.compiled.program != fast.text)
    }

    @Test func blankTextIsNotPlayable() {
        #expect(!LEDSStudioAnalysis("  \n").playable)
        #expect(LEDSStudioAnalysis("// only a note").strip.accepted)
    }

    @Test func everyFirmwareErrorHasAnExplanation() {
        for kind in LEDSParseError.Kind.allCases {
            #expect(!kind.explanation.isEmpty, "\(kind.rawValue)")
        }
    }
}
