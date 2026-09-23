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

    @Test func everyBlendModesFleetPreviewIsAPlayableProgram() throws {
        for mode in LightingPage.blendModes.map(\.value) {
            for cycle in [0.5, 2.2, 8.0] {
                let text = LightingPreviewPrograms.fleet(blendMode: mode, working: ("#D97757", "#2B8FFF"),
                                                         askHex: "#FF3A00", cycleSeconds: cycle)
                #expect(text.utf8.count <= LEDSLimits.maxProgramBytes, "\(mode) at \(cycle) s")
                let program = try LEDSProgram.parse(text, ledCount: 8)
                #expect(LEDSPresentationCompiler.compile(text, ledCount: 8).accepted, "\(mode) at \(cycle) s")
                // Every mode shows the ask somewhere: its colour is on the strip.
                let sampler = LEDSSampler(program: program, ledCount: 8)
                let span = sampler.cycleDuration ?? 1
                let seen = stride(from: 0.0, to: span, by: span / 24).flatMap { sampler.codes(atMilliseconds: Int($0 * 1000)) }
                #expect(seen.contains { $0.r > 150 && $0.g < 120 && $0.b < 60 }, "\(mode) should show the ask")
            }
        }
    }

    @Test func aScenePacksOverridesReadAsWords() {
        #expect(ScenePackPicker.sceneList(["focus"]) == "Focus")
        #expect(ScenePackPicker.sceneList(["focus", "night"]) == "Focus and Night")
        #expect(ScenePackPicker.sceneList(["calm", "dnd", "travel"]) == "Calm, Do Not Disturb and Travel")
        #expect(ScenePackPicker.sceneList(["gallery"]) == "Gallery", "an unknown scene keeps its own name")
        #expect(ScenePackPicker.sceneList([]) == "")
    }

    @Test func refusedEventKitGrantsAreNamed() {
        #expect(EventKitAccessNote.isRefused(.denied))
        #expect(EventKitAccessNote.isRefused(.restricted))
        #expect(EventKitAccessNote.isRefused(.writeOnly))
        #expect(!EventKitAccessNote.isRefused(.notDetermined), "the first prompt is still to come")
        #expect(!EventKitAccessNote.isRefused(.fullAccess))
    }
}
