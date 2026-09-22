import EventKit
import Foundation
import Testing
import JRBarLEDS
@testable import JRBarApp

/// The Settings rows brought over from the legacy window: the previews
/// they draw must be programs the firmware and the compiler accept.
@Suite("Light settings rows")
@MainActor
struct LightsSettingsRowsTests {
    @Test func rainstickPreviewIsAFirmwareProgramThatWalksTheStrip() throws {
        let text = LightingPreviewPrograms.rainstick()
        let program = try LEDSProgram.parse(text, ledCount: 8)
        #expect(text.utf8.count <= LEDSLimits.maxProgramBytes)
        #expect(program.loopsForever)
        let compiled = LEDSPresentationCompiler.compile(text, ledCount: 8)
        #expect(compiled.accepted)
        // One lit pixel at a time: every step lights exactly one LED.
        let sampler = LEDSSampler(program: program, ledCount: 8)
        for step in 0..<8 {
            let colors = sampler.colors(at: 0.6 + Double(step) * 1.2)
            #expect(colors.filter { $0.maxChannel > 0.01 }.count == 1, "step \(step)")
        }
    }

    @Test func refusedEventKitGrantsAreNamed() {
        #expect(EventKitAccessNote.isRefused(.denied))
        #expect(EventKitAccessNote.isRefused(.restricted))
        #expect(EventKitAccessNote.isRefused(.writeOnly))
        #expect(!EventKitAccessNote.isRefused(.notDetermined), "the first prompt is still to come")
        #expect(!EventKitAccessNote.isRefused(.fullAccess))
    }
}
