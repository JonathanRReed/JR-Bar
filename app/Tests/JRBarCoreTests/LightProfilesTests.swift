import Foundation
import Testing
@testable import JRBarCore

/// Saved calibration profiles and the Focus → profile rules: the
/// snapshot the Save button writes, the per-field writes Apply sends, and
/// the whole-object rule writes dotted Focus ids need.
@Suite("Calibration profiles")
struct LightProfilesTests {
    private static let document = SettingsDocument([
        "devices": [
            ["id": "pro", "brightness": 200, "red_gain": 0.9, "green_gain": 1.0, "blue_gain": 1.1, "resting_glow": 0.05],
            ["id": "dot", "brightness": 255, "red_gain": 1.0, "green_gain": 1.0, "blue_gain": 1.0, "resting_glow": 0.0],
        ],
        "calibration_profiles": [
            "Night": [
                "pro": ["brightness": 64, "red_gain": 0.9, "green_gain": 0.8, "blue_gain": 0.7, "resting_glow": 0.2],
                "gone": ["brightness": 10],
            ],
            "Broken": "not an object",
        ],
    ])

    @Test func snapshotRecordsEveryDevicesLook() {
        let snapshot = LightProfiles.snapshot(of: Self.document).objectValue ?? [:]
        #expect(Set(snapshot.keys) == ["pro", "dot"])
        #expect(snapshot["pro"]?["brightness"]?.doubleValue == 200)
        #expect(snapshot["pro"]?["resting_glow"]?.doubleValue == 0.05)
        #expect(snapshot["pro"]?.objectValue?.count == LightProfiles.snapshotFields.count)
    }

    @Test func savedSlotsAreTheDaemonsNamedSlotsOnly() {
        #expect(LightProfiles.savedSlots(in: Self.document) == ["Night"])
        #expect(LightProfiles.deviceCount(slot: "Night", in: Self.document) == 2)
        #expect(LightProfiles.deviceCount(slot: "Day", in: Self.document) == 0)
    }

    @Test func applyingWritesBrightnessAndGainsThatDiffer() {
        let writes = LightProfiles.applyWrites(slot: "Night", to: Self.document)
        let paths = Dictionary(uniqueKeysWithValues: writes.map { ($0.path, $0.value.doubleValue) })
        // The red gain already matches; the glow is never applied; the
        // Dot and the vanished device are untouched.
        #expect(paths == ["devices.0.brightness": 64, "devices.0.green_gain": 0.8, "devices.0.blue_gain": 0.7])
        #expect(LightProfiles.applyWrites(slot: "Day", to: Self.document).isEmpty)
        #expect(!LightProfiles.isApplied(slot: "Night", in: Self.document))
        var applied = Self.document
        for write in writes { applied = applied.replacing(SettingsPath(write.path), with: write.value) }
        #expect(LightProfiles.isApplied(slot: "Night", in: applied))
        #expect(!LightProfiles.isApplied(slot: "Day", in: applied), "an unsaved slot is never in use")
    }

    @Test func rulesAreWrittenWholeWithDottedFocusKeys() {
        let set = LightProfiles.rules(["com.apple.focus.personal-time": "Day"], setting: "com.apple.focus.work",
                                      to: .string("Night"))
        #expect(set.objectValue?["com.apple.focus.work"] == .string("Night"))
        #expect(set.objectValue?["com.apple.focus.personal-time"] == .string("Day"))
        let removed = LightProfiles.rules(set.objectValue, setting: "com.apple.focus.work", to: nil)
        #expect(removed.objectValue?["com.apple.focus.work"] == nil)
        #expect(LightProfiles.rules(nil, setting: "x.y", to: .null) == .object([:]))
    }
}
