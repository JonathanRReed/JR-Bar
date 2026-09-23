import Foundation
import Testing
@testable import JRBarCore

/// The light settings brought over from the legacy window: the catalogue
/// entries, the personal documents a page reset must not wipe, and the
/// milestone ladder's normalisation.
@Suite("Light settings from the legacy window")
struct LightSettingsCatalogueTests {
    @Test func legacyLightKeysAreInTheCatalogue() {
        for key in SettingsKey.lightsKeys {
            #expect(SettingsKey.all.contains(key), "\(key.path) should be a page key")
        }
        #expect(SettingsKey.keys(on: .notifications).contains { $0.path == "calendar_alerts_enabled" })
        #expect(SettingsKey.keys(on: .devices).contains { $0.path == "devices[].blend_mode" })
    }

    @Test func personalDocumentsAreNeverResetByAPage() {
        let document = SettingsDocument([
            "devices": [["id": "p", "blend_mode": nil]],
            "calibration_profiles": ["Night": [:]],
            "focus_profile_rules": [:],
            "studio_program": "#FF00FF",
        ])
        for key in SettingsKey.lightsDocuments {
            #expect(!SettingsKey.all.contains(key), "\(key.path) is work, not a preference")
            for page in SettingsKey.Page.allCases {
                #expect(!SettingsKey.resetPaths(on: page, in: document).contains(key.path))
            }
        }
        // The per-device blend is a preference: a Devices reset reaches it.
        #expect(SettingsKey.resetPaths(on: .devices, in: document).contains("devices.0.blend_mode"))
    }

    @Test func milestoneLadderMatchesTheDaemonsNormalisation() {
        #expect(SettingsKey.normalizedMilestoneSteps([50, 5, 5, -3, 20]) == [5, 20, 50])
        #expect(SettingsKey.normalizedMilestoneSteps([0, -1]) == SettingsKey.defaultMilestoneSteps)
        #expect(SettingsKey.normalizedMilestoneSteps(Array(1...40)).count == SettingsKey.maxMilestoneSteps)
        #expect(SettingsKey.milestoneSteps(parsing: "10, 25;50  100") == [10, 25, 50, 100])
        #expect(SettingsKey.milestoneSteps(parsing: "7, lots, 3") == [3, 7])
        #expect(SettingsKey.milestoneSteps(parsing: "") == SettingsKey.defaultMilestoneSteps)
    }
}

@Suite("Light documents against the mock", .serialized)
struct LightDocumentsMockTests {
    @Test("the personal light documents are in the seeded mock document")
    @MainActor
    func documentsAreSeeded() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket)
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.settings != nil })
        let document = SettingsDocument(try #require(model.settings).document)
        let missing = SettingsKey.lightsDocuments.filter { !$0.isProvided(in: document) }.map(\.path)
        #expect(missing.isEmpty, "missing from the mock document: \(missing)")
        mock.waitUntilExit()
    }
}
