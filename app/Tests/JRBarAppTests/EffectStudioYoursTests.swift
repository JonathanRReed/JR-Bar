import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// "Save as Effect…": a tuned effect kept as a named effect in Yours,
/// written so the monitor reads every parameter back as it was set.
@Suite("Effect Studio · Yours")
@MainActor
struct EffectStudioYoursTests {
    private static let aurora = EffectDefinition(
        id: "aurora", label: "Aurora", meaning: "provider animation: aurora",
        parameters: [EffectParameter(name: "duration_seconds", type: .number, defaultValue: 2.4),
                     EffectParameter(name: "wave_count", type: .integer, defaultValue: 2)],
        catalog: "provider_animation")

    /// The row `build_export_pack` writes for a provider animation.
    private static let exportedAurora: JSONValue = [
        "id": "yours", "name": "Yours", "version": 2,
        "safety": ["data_only": true, "network": false],
        "accessibility": ["reduced_motion": true, "high_contrast": true],
        "effects": [[
            "id": "aurora", "label": "Aurora", "description": "Curtains of light.",
            "meaning": "provider animation: aurora", "surfaces": ["status_bar"],
            "safety": "safe", "energy": "low", "motion": "aurora",
            "duration_seconds": 2.4, "wave_count": 2, "reduce_motion_fallback": "breathe",
        ]],
    ]

    @Test func onlyEffectsThatRoundTripCanBeSaved() {
        #expect(EffectStudioYours.canSave(Self.aurora))
        let packed = EffectDefinition(id: "pack:night:glow", label: "Glow", meaning: "night", pack: "night")
        #expect(EffectStudioYours.canSave(packed))
        // A plain built-in exports as metadata only: its copy would play a
        // different light under this one's name.
        let pulse = EffectDefinition(id: "pulse", label: "Pulse", meaning: "attention required")
        #expect(!EffectStudioYours.canSave(pulse))
    }

    @Test func slugsAreDataIdentifiersAndNeverCollide() {
        #expect(EffectStudioYours.slug("Slow Aurora", taken: []) == "slow-aurora")
        #expect(EffectStudioYours.slug("  Night — calm!! ", taken: []) == "night-calm")
        #expect(EffectStudioYours.slug("✨", taken: []) == "effect")
        #expect(EffectStudioYours.slug("Slow Aurora", taken: ["slow-aurora", "slow-aurora-2"]) == "slow-aurora-3")
        let long = EffectStudioYours.slug(String(repeating: "a", count: 200), taken: [])
        #expect(long.count <= 80)
        #expect(long.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil)
    }

    @Test func localIDsMatchTheMonitorsExport() {
        #expect(EffectStudioYours.localID("pack:yours:slow-aurora") == "slow-aurora")
        #expect(EffectStudioYours.localID("aurora") == "aurora")
        #expect(EffectStudioYours.effectID(local: "slow-aurora") == "pack:yours:slow-aurora")
    }

    @Test func aSaveAddsARenamedRowWithTheTunedValues() throws {
        let pack = try EffectStudioYours.pack(yours: nil, source: Self.exportedAurora, sourceLabel: "Aurora",
                                              newID: "slow-aurora", label: "Slow aurora",
                                              values: ["duration_seconds": 6.0, "wave_count": 3])
        #expect(pack["id"]?.stringValue == "yours")
        #expect(pack["name"]?.stringValue == "Yours")
        let row = try #require(pack["effects"]?[0])
        #expect(row["id"]?.stringValue == "slow-aurora")
        #expect(row["label"]?.stringValue == "Slow aurora")
        #expect(row["motion"]?.stringValue == "aurora", "the motion is what makes it play the same")
        #expect(row["duration_seconds"]?.doubleValue == 6)
        #expect(row["wave_count"]?.doubleValue == 3)
        #expect(row["reduce_motion_fallback"] == nil, "the fallback named a row of another pack")
        #expect(row["meaning"]?.stringValue == "yours: Aurora, tuned",
                "a provider-animation meaning would file the copy back among the built-ins")
    }

    @Test func aSaveKeepsWhatYoursAlreadyHolds() throws {
        let installed: JSONValue = ["id": "yours", "name": "Yours", "version": 2,
                                    "effects": [["id": "slow-aurora", "label": "Slow aurora", "motion": "aurora"]]]
        let pack = try EffectStudioYours.pack(yours: installed, source: Self.exportedAurora, sourceLabel: "Aurora",
                                              newID: "slow-aurora-2", label: "Slow aurora", values: [:])
        #expect(EffectStudioYours.rowIDs(pack) == ["slow-aurora", "slow-aurora-2"])
    }

    @Test func aMeaningThatDrivesTheRenderIsKept() throws {
        var source = Self.exportedAurora
        if case .object(var root) = source, case .array(var rows) = root["effects"]!, case .object(var row) = rows[0] {
            row["meaning"] = "attention required"
            row.removeValue(forKey: "motion")
            rows[0] = .object(row)
            root["effects"] = .array(rows)
            source = .object(root)
        }
        let pack = try EffectStudioYours.pack(yours: nil, source: source, sourceLabel: "Glow",
                                              newID: "glow", label: "Glow", values: [:])
        #expect(pack["effects"]?[0]?["meaning"]?.stringValue == "attention required")
    }

    @Test func anEmptyExportIsRefused() {
        #expect(throws: EffectStudioYours.Failure.self) {
            _ = try EffectStudioYours.pack(yours: nil, source: ["effects": []], sourceLabel: "x",
                                           newID: "x", label: "x", values: [:])
        }
    }

    @Test func deletingTheLastRowRemovesThePack() {
        let two: JSONValue = ["id": "yours", "effects": [["id": "a"], ["id": "b"]]]
        let rest = EffectStudioYours.pack(yours: two, removing: "a")
        #expect(EffectStudioYours.rowIDs(rest) == ["b"])
        #expect(EffectStudioYours.pack(yours: ["id": "yours", "effects": [["id": "b"]]], removing: "b") == nil)
    }

    @Test func realNumbersKeepTheirFraction() throws {
        let pack = try EffectStudioYours.pack(yours: nil, source: Self.exportedAurora, sourceLabel: "Aurora",
                                              newID: "slow-aurora", label: "Slow “aurora”",
                                              values: ["duration_seconds": 6.0, "wave_count": 3])
        let text = EffectStudioYours.text(pack) { $0 == "slow-aurora" ? EffectStudioYours.floatKeys(of: Self.aurora) : [] }
        #expect(text.contains("\"duration_seconds\":6.0"), "a whole real number must not come back an integer")
        #expect(text.contains("\"wave_count\":3}"))
        #expect(text.contains("\"version\":2}"))
        #expect(text.contains("\"data_only\":true"))
        // It is JSON, and it says what the pack says.
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(decoded == pack)
        // Same pack, same text.
        #expect(EffectStudioYours.text(pack) { _ in ["duration_seconds"] } == EffectStudioYours.text(pack) { _ in ["duration_seconds"] })
    }

    @Test func fractionalAndExoticNumbersStayJSON() throws {
        let pack: JSONValue = ["effects": [["id": "x", "ratio": 0.25, "tiny": 0.0000001, "big": 1e20]]]
        let text = EffectStudioYours.text(pack) { _ in ["ratio"] }
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(decoded["effects"]?[0]?["ratio"]?.doubleValue == 0.25)
        #expect(decoded["effects"]?[0]?["tiny"]?.doubleValue == 0.0000001)
        #expect(decoded["effects"]?[0]?["big"]?.doubleValue == 1e20)
    }
}
