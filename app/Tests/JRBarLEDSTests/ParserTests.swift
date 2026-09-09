import Foundation
import Testing
@testable import JRBarLEDS

@Suite struct ParserTests {
    /// The firmware's verdict (accept, or which error) must be reproduced for
    /// every recorded edge case, at both LED counts.
    @Test func parseVerdictsMatchFirmware() throws {
        let verdicts = try Fixtures.parseVerdicts()
        #expect(verdicts.count > 100)
        var failures: [String] = []
        var lineMatches = 0
        var errors = 0
        for verdict in verdicts {
            do {
                _ = try LEDSProgram.parse(verdict.program, ledCount: verdict.led_count)
                if !verdict.ok {
                    failures.append("\(verdict.led_count) LED: accepted \(verdict.program.debugDescription) but firmware says \(verdict.error_name ?? "?")")
                }
            } catch {
                errors += 1
                if verdict.ok {
                    failures.append("\(verdict.led_count) LED: rejected \(verdict.program.debugDescription) with \(error.kind.rawValue) but firmware accepts")
                } else if error.kind.rawValue != verdict.error_name {
                    failures.append("\(verdict.led_count) LED: \(verdict.program.debugDescription) -> \(error.kind.rawValue), firmware says \(verdict.error_name ?? "?")")
                } else if error.line == verdict.line {
                    lineMatches += 1
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
        // Error positions are advisory; most should still agree on the line.
        #expect(lineMatches * 10 >= errors * 8, Comment(rawValue: "only \(lineMatches)/\(errors) error lines match the firmware"))
    }

    @Test func modelShapes() throws {
        let program = try LEDSProgram.parse("brightness 128\n# note\n0:#ff0000 1s ease-in 0s; 1:#00ff00 0.33s linear 250ms\n#FF00FF #00ff00\noff 400ms none\nroll-left 2s ease\nrepeat 4")
        #expect(program.brightness == 128)
        #expect(program.steps.count == 7)
        guard case .paint(let segments) = program.steps[2] else { Issue.record("expected paint"); return }
        #expect(segments.count == 2)
        #expect(segments[0].kind == .indexed([LEDSAssignment(index: 0, color: RGB8(r: 255, g: 0, b: 0))]))
        #expect(segments[0].timing == LEDSTiming(durationMs: 1000, easing: .easeIn, delayMs: 0))
        #expect(segments[1].timing == LEDSTiming(durationMs: 330, easing: .linear, delayMs: 250))
        guard case .paint(let list) = program.steps[3], case .colorList(let colors) = list[0].kind else { Issue.record("expected list"); return }
        #expect(colors == [RGB8(r: 255, g: 0, b: 255), RGB8(r: 0, g: 255, b: 0)])
        guard case .paint(let off) = program.steps[4], case .wholeBar(nil) = off[0].kind else { Issue.record("expected off"); return }
        guard case .roll(let roll) = program.steps[5] else { Issue.record("expected roll"); return }
        #expect(roll == LEDSRoll(durationMs: 2000, direction: .left, easing: .ease))
        #expect(program.repeatCount == .some(4))
        #expect(program.loopsForever == false)
    }

    @Test func renderIsCanonicalAndStable() throws {
        let text = "brightness 128\n// note\n0:#FF0000 1s ease-in 0ms; 1:#00FF00 330ms linear 250ms\n#FF00FF #00FF00\noff 400ms none\nroll-left 2s ease\nrepeat 4"
        let program = try LEDSProgram.parse(text)
        #expect(program.render() == text)
        let lower = try LEDSProgram.parse("0:#ff0000 1000ms ease-in 0s;1:#00ff00 0.33s linear 250ms\nroll 2000ms\nrepeat")
        #expect(lower.render() == "0:#FF0000 1s ease-in 0ms; 1:#00FF00 330ms linear 250ms\nroll-right 2s\nrepeat")
        #expect(try LEDSProgram.parse(lower.render()).render() == lower.render())
    }

    @Test func limitsAreEnforced() {
        let long = "#ffffff\n# " + String(repeating: "x", count: 510)
        #expect(throws: LEDSParseError(.tooLong, line: 0, column: 0)) { try LEDSProgram.parse(long) }
        let manyLines = Array(repeating: "#ffffff", count: 21).joined(separator: "\n")
        #expect(throws: LEDSParseError(.tooManyLines, line: 21, column: 1)) { try LEDSProgram.parse(manyLines) }
        #expect(throws: LEDSParseError.self) { try LEDSProgram.parse("#fff") }
        #expect(throws: LEDSParseError.self) { try LEDSProgram.parse("repeat") }
    }

    @Test func parseErrorNamesMatchFirmwareVocabulary() {
        let names = Set(LEDSParseError.Kind.allCases.map(\.rawValue))
        for expected in ["null-input", "too-long", "too-many-lines", "too-many-animation-lines", "syntax", "bad-color", "bad-index", "bad-time", "bad-brightness", "bad-repeat", "trailing-input"] {
            #expect(names.contains(expected))
        }
    }
}
