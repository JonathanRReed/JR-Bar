import EventKit
import Foundation
import SwiftUI
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

    @Test func theAmbientCurveSaysWhatItHasLearned() throws {
        let ready = try JSONDecoder().decode(AutoDimLearning.self, from: Data("""
        {"mode": "ambient", "votes": 6, "ready": true, "reason": null,
         "suggested": {"brightness": 0.8, "min_fraction": 0.25, "lux_floor": 5.0, "lux_ceiling": 300.0},
         "error_now": 0.21, "error_suggested": 0.04, "samples": []}
        """.utf8))
        #expect(ready.sentence == "From 6 slider moves, a curve that fits you better: never below 25 %, dark below 5.0 lux, bright above 300 lux, at 80 % overall.")
        func waiting(_ votes: Int, _ reason: String) -> String {
            AutoDimLearning(votes: votes, ready: false, reason: reason, suggested: nil).sentence
        }
        #expect(waiting(0, "needs_votes").hasPrefix("Move the panel's brightness slider"))
        #expect(waiting(2, "needs_votes") == "2 slider moves so far; three are needed before the curve can learn from you.")
        #expect(waiting(4, "needs_range").contains("three times brighter or darker"))
        #expect(waiting(5, "already_fits") == "5 slider moves, and the curve set now already fits them.")
        #expect(waiting(1, "no_fit") == "1 slider move that no single curve fits yet.")
    }

    @Test func customFocusesFollowTheFourEveryMacHas() {
        let known = NotificationsPage.knownFocuses
        let merged = FocusRoster<EmptyView>.merge(known: known, reported: [
            ("com.apple.focus.work", "Work"),
            ("com.example.focus.writing", "writing"),
            ("com.example.focus.deep", "Deep Work"),
            ("", "Nameless"),
        ])
        #expect(merged.map(\.id) == known.map(\.id) + ["com.example.focus.deep", "com.example.focus.writing"],
                "the four first, then the rest by name, no Focus twice")
        #expect(FocusRoster<EmptyView>.merge(known: known, reported: []).map(\.id) == known.map(\.id))
    }

    @Test func refusedEventKitGrantsAreNamed() {
        #expect(EventKitAccessNote.isRefused(.denied))
        #expect(EventKitAccessNote.isRefused(.restricted))
        #expect(EventKitAccessNote.isRefused(.writeOnly))
        #expect(!EventKitAccessNote.isRefused(.notDetermined), "the first prompt is still to come")
        #expect(!EventKitAccessNote.isRefused(.fullAccess))
    }
}
