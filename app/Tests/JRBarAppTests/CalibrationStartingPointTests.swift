import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// "Start from": a calibration can begin from a look this Mac already
/// has — another strip's or Dot's white balance, or this device's saved
/// profile — instead of from the die as shipped.
@Suite("Calibration starting points")
@MainActor
struct CalibrationStartingPointTests {
    private static let document = SettingsDocument(.object([
        "calibration_profiles": .object([
            "Night": .object([
                "pro-1": .object(["brightness": 102, "red_gain": 1.0, "green_gain": 0.9, "blue_gain": 0.7, "resting_glow": 0.05]),
            ]),
            "Day": .object(["dot-1": .object(["red_gain": 0.95])]),
        ]),
    ]))

    private static let devices: [(id: String, name: String, kind: String, fields: [String: JSONValue])] = [
        ("pro-1", "SidePulse Pro", "pro", ["red_gain": 1.0, "green_gain": 1.0, "blue_gain": 1.0]),
        ("dot-1", "PulseDot", "dot", ["red_gain": 0.92, "green_gain": 1.0, "blue_gain": 0.85, "brightness": 90]),
        ("virtual:status-bar", "Screen Bar", "screen_bar", ["red_gain": 0.8]),
    ]

    @Test func aStripCanStartFromTheDotsWhiteBalanceAndItsOwnProfile() {
        let options = CalibrationStartingPoint.options(for: "pro-1", devices: Self.devices, document: Self.document)
        #expect(options.map(\.title) == ["PulseDot's white balance", "The Night profile"])
        let dot = options[0]
        #expect(dot.red == 0.92 && dot.green == 1.0 && dot.blue == 0.85)
        #expect(dot.brightness == nil && dot.glow == nil, "another device's level and glow are its own")
        let night = options[1]
        #expect(night.blue == 0.7)
        #expect(night.brightness == 102.0 / 255)
        #expect(night.glow == 0.05)
    }

    @Test func uncalibratedDevicesAndTheScreenBarOfferNothing() {
        // The Pro is at the die as shipped; the Screen Bar is a display.
        let options = CalibrationStartingPoint.options(for: "dot-1", devices: Self.devices, document: Self.document)
        #expect(options.map(\.title) == ["The Day profile"])
        #expect(options[0].green == 1, "a field the profile never saved is the shipped 1.0")
    }

    @Test func gainsStayInTheDaemonsBounds() {
        #expect(CalibrationStartingPoint.clampGain(2.4) == CalibrationModel.gainRange.upperBound)
        #expect(CalibrationStartingPoint.clampGain(0.01) == CalibrationModel.gainRange.lowerBound)
        #expect(CalibrationStartingPoint.clampGain(0.9) == 0.9)
    }
}
