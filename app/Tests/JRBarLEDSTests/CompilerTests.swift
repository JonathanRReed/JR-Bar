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
}
