import Foundation
import Testing
import JRBarCore
import JRBarLEDS
@testable import JRBarApp

/// Effect Studio's Program and Moments rooms: everything they offer to
/// play is a program the firmware parses and the compiler accepts, the
/// shelf writes the daemon's shape, and a burn a monitor cannot do says
/// so instead of claiming a write.
@Suite("Effect Studio rooms")
@MainActor
struct EffectStudioRoomsTests {
    @Test func everyExampleIsPlayableOnBothDevices() {
        for example in LEDSStudioModel.examples {
            let analysis = LEDSStudioAnalysis(example.program)
            #expect(analysis.playable, "\(example.name): \(String(describing: analysis.firstError))")
            #expect(analysis.dot.accepted, "\(example.name)")
        }
    }

    @Test func everyMomentSketchFitsTheFirmwareAndTheClamp() {
        #expect(LightMoment.all.count == 12)
        #expect(LightMoment.all.map(\.priority) == LightMoment.all.map(\.priority).sorted(by: >),
                "loudest first, the order the daemon layers them")
        #expect(Set(LightMoment.all.map(\.id)).count == LightMoment.all.count)
        for moment in LightMoment.all {
            let parsed = try? LEDSProgram.parse(moment.sketch, ledCount: moment.sketchLedCount)
            #expect(parsed != nil, "\(moment.name) must parse")
            #expect(moment.sketch.utf8.count <= LEDSLimits.maxProgramBytes, "\(moment.name)")
            #expect(LEDSPresentationCompiler.compile(moment.sketch, ledCount: moment.sketchLedCount).accepted, "\(moment.name)")
        }
        // Only the opt-in cues carry a switch, and it is a real key.
        let switched = LightMoment.all.compactMap(\.setting)
        #expect(Set(switched) == ["rainstick_idle_enabled", "milestone_odometer_enabled"])
    }

    @Test func shelfWritesTheDaemonsPairsAndReplacesByName() {
        let shelf = LEDSStudioModel.shelf(from: [
            .array([.string("Glow"), .string("#FF7A00")]),
            .array([.string("  "), .string("#000000")]),
            .string("junk"),
            .array([.string("Wave"), .string("roll 2s")]),
        ])
        #expect(shelf.map(\.name) == ["Glow", "Wave"])
        let saved = LEDSStudioModel.shelf(shelf, saving: " Glow ", program: "#00FF66")
        #expect(saved == .array([
            .array([.string("Wave"), .string("roll 2s")]),
            .array([.string("Glow"), .string("#00FF66")]),
        ]))
        let removed = LEDSStudioModel.shelf(shelf, removing: "Wave")
        #expect(removed == .array([.array([.string("Glow"), .string("#FF7A00")])]))
    }

    @Test func aMonitorWithoutBurnInitSaysNothingWasWritten() {
        let unknown = LEDSStudioModel.burnFailure(CoreReplyError(code: "unknown_command", message: "no such command: burn_init"))
        #expect(unknown.contains("nothing was written"))
        let refused = LEDSStudioModel.burnFailure(CoreReplyError(code: "not_found", message: "no strip connected"))
        #expect(refused == "Burn refused: no strip connected")
    }

    @Test func onlyAWrittenDeviceIsCalledBurned() {
        let written: JSONValue = ["confirmed": true, "written": true,
                                  "devices": [["device": "pro-1", "written": true]]]
        #expect(LEDSStudioModel.burnOutcome(written, device: "pro-1", name: "SidePulse").burned)

        // The daemon answers an unconfirmed burn with the plan alone.
        let plan: JSONValue = ["confirmed": false, "written": false,
                               "devices": [["device": "pro-1", "written": false]]]
        let planned = LEDSStudioModel.burnOutcome(plan, device: "pro-1", name: "SidePulse")
        #expect(!planned.burned)
        #expect(planned.message == "Nothing was written to SidePulse.")

        let refused: JSONValue = ["written": false, "devices": [[
            "device": "dot-1", "written": false, "error": "invalid_program",
            "problems": [["severity": "error", "code": "too-long", "message": "Over 512 bytes."]],
        ]]]
        let check = LEDSStudioModel.burnOutcome(refused, device: "dot-1", name: "PulseDot")
        #expect(!check.burned)
        #expect(check.message == "The firmware check refused it for PulseDot: Over 512 bytes. Nothing was written.")

        let failed: JSONValue = ["devices": [["device": "pro-1", "written": false, "error": "write_failed"]]]
        #expect(LEDSStudioModel.burnOutcome(failed, device: "pro-1", name: "SidePulse").message
                == "Nothing was written to SidePulse: write failed.")

        // A reply that says nothing of the write is taken at its word.
        #expect(LEDSStudioModel.burnOutcome(nil, device: "pro-1", name: "SidePulse").burned)
        #expect(!LEDSStudioModel.burnOutcome(["written": false], device: "pro-1", name: "SidePulse").burned)
    }

    @Test func theScreenBarNeedsNoHardwareConsent() {
        #expect(!EffectStudioStore.needsConsent(surface: "screen_bar"))
        #expect(EffectStudioStore.needsConsent(surface: "hardware"))
        #expect(EffectStudioStore.needsConsent(surface: "dot"))
        let store = EffectStudioStore(core: CoreModel())
        #expect(!store.hasHardware)
        #expect(store.playSurface.surface == "screen_bar", "with nothing plugged in, previews play on the band")
    }

    @Test func theEditorJudgesEveryKeystroke() {
        let model = LEDSStudioModel(core: CoreModel(), defaults: nil)
        #expect(model.analysis.isBlank)
        model.text = "#FF00FF 1s pulse\nrepeat"
        #expect(model.analysis.playable)
        model.text = "#FF00F"
        #expect(model.analysis.strip.error?.kind == .badColor)
        #expect(!model.canBurn(on: CoreDevice(id: "pro", kind: "pro", connected: true)))
    }
}
