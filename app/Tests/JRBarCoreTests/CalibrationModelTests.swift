import Foundation
import Testing
@testable import JRBarCore

@Suite("Calibration model")
struct CalibrationModelTests {

    @Test("nudges move the channels by the daemon's step, in opposition")
    func nudgeMath() {
        // CALIBRATION_NUDGE_STEP is 0.04 in status_bar_legacy.py.
        #expect(abs(CalibrationModel.nudgeStep - 0.04) < 0.0001)
        var model = CalibrationModel()
        model.nudge(.warmer)   // the light reads too cool
        #expect(abs(model.red - 1.04) < 0.0001)
        #expect(abs(model.blue - 0.96) < 0.0001)
        #expect(abs(model.green - 1.0) < 0.0001)
        model.nudge(.cooler)
        #expect(abs(model.red - 1.0) < 0.0001)
        #expect(abs(model.blue - 1.0) < 0.0001)
        model.nudge(.lessGreen)
        #expect(abs(model.green - 0.96) < 0.0001)
        model.nudge(.greener)
        #expect(abs(model.green - 1.0) < 0.0001)
    }

    @Test("nudges clamp at both ends of the 0.3...1.5 gain range")
    func nudgeClamps() {
        var model = CalibrationModel(red: 1.48, green: 1.49, blue: 0.31)
        model.nudge(.warmer)
        #expect(model.red == 1.5)
        #expect(model.blue == 0.3)
        model.nudge(.greener)
        #expect(model.green == 1.5)
        model.nudge(.cooler)
        #expect(abs(model.red - 1.46) < 0.0001)
        #expect(abs(model.blue - 0.34) < 0.0001)
        model.nudge(.lessGreen)
        #expect(abs(model.green - 1.46) < 0.0001)
    }

    @Test("init clamps to the daemon's bounds and snapshots the clamped values")
    func initClamps() {
        let model = CalibrationModel(red: 9, green: -2, blue: 1.0, glow: 0.9, brightness: 1.4)
        #expect(model.red == 1.5)
        #expect(model.green == 0.3)
        #expect(model.glow == 0.35)
        #expect(model.brightness == 1.0)
        // A stored out-of-range value is not "dirty" the moment the sheet opens.
        #expect(!model.isDirty)
    }

    @Test("dirty tracking and reset; brightness is never a reset default")
    func dirtyAndReset() {
        var model = CalibrationModel(red: 1.0, green: 0.38, blue: 1.0, glow: 0.05, brightness: 0.6)
        #expect(!model.isDirty)
        model.nudge(.lessGreen)
        #expect(model.isDirty)
        model.reset()
        #expect(model.red == 1.0)
        #expect(model.glow == 0.0)
        #expect(model.brightness == 0.6)
        #expect(model.isDirty)  // still differs from the opened profile
        var fresh = CalibrationModel()
        #expect(fresh.isDefault)
        fresh.brightness = 0.6
        fresh.reset()
        #expect(!fresh.isDefault)
    }

    @Test("the patch is preview state, never profile state")
    func patchNotDirty() {
        var model = CalibrationModel()
        model.patch = .grey
        #expect(!model.isDirty)
    }

    @Test("apply arguments carry brightness in the 0...255 domain")
    func profileArguments() {
        let model = CalibrationModel(red: 1.0, green: 0.38, blue: 1.0, glow: 0.05, brightness: 0.6)
        let args = model.profileArguments()
        #expect(args["green_gain"] == .number(0.38))
        #expect(args["resting_glow"] == .number(0.05))
        #expect(args["brightness"] == .number(153))  // 0.6 * 255
        #expect(args["patch"] == nil)
        #expect(args["companion"] == nil)
    }

    @Test("preview arguments send the nominal patch, never a baked hex")
    func previewArguments() {
        var model = CalibrationModel(red: 1.0, green: 0.5, blue: 1.0, brightness: 0.5)
        model.patch = .grey
        let args = model.previewArguments(device: "sidepulse:dot:1", companion: true)
        #expect(args["device"] == .string("sidepulse:dot:1"))
        #expect(args["patch"] == .string("grey"))
        #expect(args["companion"] == .bool(true))
        #expect(args["brightness"] == .number(128))  // rounded 0.5 * 255
        guard case .object(let gains) = args["gains"] else {
            Issue.record("gains must be a mapping")
            return
        }
        #expect(gains["green"] == .number(0.5))
    }

    @Test("patch swatches are the daemon's nominal colours")
    func patchNominals() {
        #expect(CalibrationModel.Patch.white.swatch.r == 1.0)
        #expect(CalibrationModel.Patch.grey.swatch.g == 0.5)
        #expect(CalibrationModel.Patch.allCases.map(\.rawValue)
            == ["white", "red", "green", "blue", "grey"])
    }
}
