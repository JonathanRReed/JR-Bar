import AppKit
import Carbon
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Studio restored controls", .serialized, .timeLimit(.minutes(2)))
struct StudioFixTests {
    static let comet = EffectDefinition(id: "comet", label: "Comet", meaning: "provider animation: comet",
        parameters: [EffectParameter(name: "duration_seconds", type: .number, defaultValue: 2.2, minimum: 0.5, maximum: 10),
                     EffectParameter(name: "trail_length", type: .integer, defaultValue: 3, minimum: 1, maximum: 6)], catalog: "provider_animation")

    @Test func tunedCometCanBeSavedAndAssignedToAProject() async throws {
        try await withStore { fixture, store in
            try await seed(fixture, store, catalog: EffectCatalog(effects: [Self.comet]))
            #expect(store.groups.flatMap(\.effects).contains(Self.comet))
            let tuning: [String: JSONValue] = ["duration_seconds": 4.6, "trail_length": 5]
            store.editProviderEffect(Self.comet, parameters: tuning)
            #expect(store.mode == .effects && store.values(for: Self.comet) == tuning)
            let save = try #require(store.saveAsEffect(Self.comet, name: "Slow comet"))
            let export = try await fixture.request()
            #expect(export["name"] == "export_effect_pack")
            let source: JSONValue = ["id": "yours", "name": "Yours", "version": 2,
                "effects": [["id": "comet", "label": "Comet", "meaning": "provider animation: comet", "motion": "comet"]]]
            let sourcePath = try #require(export["args"]?["path"]?.stringValue)
            try JSONEncoder().encode(source).write(to: URL(fileURLWithPath: sourcePath))
            try await fixture.release(result: ["effects": 1])
            let imported = try await fixture.request()
            #expect(imported["name"] == "import_effect_pack")
            let path = try #require(imported["args"]?["path"]?.stringValue)
            let pack = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            #expect(pack["effects"]?[0]?["duration_seconds"] == 4.6)
            #expect(pack["effects"]?[0]?["trail_length"] == 5)
            let saved = EffectDefinition(id: "pack:yours:slow-comet", label: "Slow comet", meaning: "yours: Comet, tuned",
                parameters: [EffectParameter(name: "duration_seconds", type: .number, defaultValue: 4.6),
                             EffectParameter(name: "trail_length", type: .integer, defaultValue: 5)], pack: "yours")
            try await fixture.release(result: object(EffectCatalog(effects: [Self.comet, saved])))
            await save.value
            #expect(store.catalog?.effect(saved.id) != nil && !store.yoursBusy)
            store.beginAssigning(saved, scope: .project, target: "synthetic-project")
            let assignment = try #require(store.commitAssignment())
            let write = try await fixture.request()
            #expect(write["name"] == "set_assignment")
            #expect(write["args"]?["scope"] == "project")
            #expect(write["args"]?["parameters"] == .object(tuning))
            let row = EffectAssignment(effectID: saved.id, scope: .project, targetID: "synthetic-project", parameters: tuning)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [row])))
            await assignment.value
            #expect(store.assignments?.assignments == [row])
            store.resetParameters(Self.comet)
            #expect(store.values(for: Self.comet) == Self.comet.defaultParameters)
        }
    }

    @Test func packRemovalKeepsOrphansAndSuppressionRemovable() async throws {
        try await withStore { fixture, store in
            let packed = EffectDefinition(id: "pack:test:glow", label: "Glow", meaning: "completion", pack: "test")
            let pack = try JSONDecoder().decode(EffectPack.self, from: Data(#"{"id":"test","name":"Test","effects":["pack:test:glow"]}"#.utf8))
            let rows = [EffectAssignment(effectID: packed.id, scope: .project, targetID: "synthetic-project"),
                        EffectAssignment(effectID: packed.id, scope: .scene, targetID: "focus"),
                        EffectAssignment(effectID: "none", scope: .global)]
            try await seed(fixture, store, catalog: EffectCatalog(effects: [packed], packs: [pack]), rows: rows)
            let removal = store.removePack(pack)
            #expect(try await fixture.request()["name"] == "remove_effect_pack")
            try await fixture.release(result: object(EffectCatalog()))
            await removal.value
            #expect(store.assignments?.assignments == rows)
            #expect(store.catalog?.effect(packed.id) == nil)
            store.mode = .assignments
            for (index, row) in rows.enumerated() {
                let action = try #require(store.remove(row))
                let request = try await fixture.request()
                #expect(request["name"] == "clear_assignment")
                #expect(request["args"]?["scope"] == .string(row.scope.rawValue))
                try await fixture.release(result: object(EffectAssignmentDocument(assignments: Array(rows.dropFirst(index + 1)))))
                await action.value
            }
            #expect(store.assignments?.assignments.isEmpty == true)
        }
    }

    @Test func keepAutomaticSceneAndRestoreMissingPack() async throws {
        try await withStore { fixture, store in
            fixture.core.apply(.hello(CoreHello(stream: "studio-scene-peer")))
            fixture.core.apply(.settings(CoreSettings(generation: 1, document: ["active_scene": "calm", "active_scene_pack": "removed",
                "scene_state": ["effective_scene": "focus", "lease_id": "synthetic-lease"]])))
            #expect(store.selectedScene == "calm" && store.activeScene == "focus" && store.activeSceneIsAutomatic)
            let keep = try #require(store.setActiveScene(store.activeScene))
            #expect(try await fixture.request()["args"]?["value"] == "focus")
            try await fixture.release(result: ["path": "active_scene", "value": "focus", "generation": 2])
            await keep.value
            #expect(!store.activeSceneIsAutomatic && store.activeScene == "focus")
            let restore = try #require(store.setActiveScenePack(nil))
            #expect(try await fixture.request()["args"]?["value"] == .null)
            try await fixture.release(result: ["path": "active_scene_pack", "value": .null, "generation": 3])
            await restore.value
            #expect(store.activeScenePackID == nil)
        }
    }

    @Test func profilesSaveReplaceApplyDeleteAndKeepFocusRulesWhole() async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-profile-unused.sock")
        var document = SettingsDocument(["devices": [["id": "synthetic-strip", "brightness": 180]],
                                         "calibration_profiles": [:], "focus_profile_rules": [:]])
        core.apply(.settings(CoreSettings(generation: 1, document: document.root)))
        let settings = SettingsStore(core: core)
        var generation = 1
        settings.settingWriter = { path, value in
            document = document.replacing(path, with: value)
            generation += 1
            core.apply(.settings(CoreSettings(generation: generation, document: document.root)))
            return CoreReply(id: "profile-write", ok: true, result: ["value": value])
        }
        let section = CalibrationProfilesSection(store: settings)
        for slot in ["Day", "Night", "Travel"] {
            section.save(slot)
            await settings.flush("calibration_profiles.\(slot)")?.value
            #expect(document.object("calibration_profiles")?[slot]?["synthetic-strip"]?["brightness"] == 180)
        }
        settings.set("devices.0.brightness", 64)
        await settings.flush("devices.0.brightness")?.value
        section.save("Night")
        await settings.flush("calibration_profiles.Night")?.value
        #expect(document.object("calibration_profiles")?["Night"]?["synthetic-strip"]?["brightness"] == 64)
        section.apply("Day")
        await settings.flush("devices.0.brightness")?.value
        #expect(document.value(at: "devices.0.brightness") == 180)
        settings.set("focus_profile_rules", LightProfiles.rules(nil, setting: "com.apple.focus.work", to: "Night"))
        await settings.flush("focus_profile_rules")?.value
        section.delete("Night")
        await settings.flush("calibration_profiles.Night")?.value
        await settings.flush("focus_profile_rules")?.value
        #expect(document.object("calibration_profiles")?["Night"] == .null)
        #expect(document.object("focus_profile_rules")?.isEmpty == true)
        settings.settingsWindowDidClose()
    }

    @Test func liveNoticesComeFromDevicePrograms() {
        let moving = "#0088FF 1s pulse\nrepeat"
        for played in ["idle", "ask", "classic"] {
            let device = StudioLightPlan.Device(device: "virtual:status-bar", ledCount: 8, requestedMix: "classic",
                played: played, reason: "Test state", warnings: [], program: moving, cueReason: nil)
            #expect(device.playbackWarnings.isEmpty == (played != "classic"))
        }
        let still = StudioLightPlan.Device(device: "virtual:status-bar", ledCount: 8, requestedMix: "classic",
            played: "classic", reason: "Working", warnings: [], program: "#0088FF", cueReason: nil)
        #expect(still.playbackWarnings.isEmpty)
    }

    @Test func studioStartupHonoursDisabledAndReboundPreferences() {
        let suite = ScratchDefaults.suiteName("studio-combined-startup")
        let defaults = ScratchDefaults.open(suite)
        defer { ScratchDefaults.remove(suite) }
        let recorder = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: recorder)
        let settings = SettingsStore(core: CoreModel(), shortcutDefaults: defaults)
        settings.studioHotkeyEnabled = false
        let panel = PanelHotkey(id: PanelHotkey.panelID, title: "Panel", defaultChord: PanelHotkey.panelDefault, center: center)
        panel.chordSource = { PanelHotkey.panelDefault }
        let studio = PanelHotkey(id: PanelHotkey.studioID, title: "Studio", defaultChord: PanelHotkey.studioDefault, center: center)
        studio.chordSource = { settings.studioHotkeyChord }
        settings.onStudioHotkeyChange = { studio.setEnabled($0) }
        panel.setEnabled(true)
        studio.setEnabled(settings.studioHotkeyEnabled)
        _ = EffectStudioWindowController(store: EffectStudioStore(core: CoreModel(), defaults: defaults))
        #expect(center.entries["studio"] == nil)
        let rebound = HotkeyChord(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))
        settings.setShortcut(rebound, for: PanelHotkey.studioID)
        #expect(center.entries["studio"]?.chord == rebound)
        #expect(center.entries["panel"]?.chord == PanelHotkey.panelDefault)
    }

    @Test(arguments: [
        ("duration_seconds was rejected; using 2.2.", "Cycle length could not be used; using 2.2."),
        ("duration_seconds was clamped to 10.", "Cycle length was limited to 10."),
        ("tail_length was rejected for Weave.", "Tail length is not available for Weave."),
        ("width was rounded to 2 LEDs.", "Width was rounded to 2 LEDs."),
        ("The safety compiler adjusted the timing: phase_cadence_clamped, roll_cadence_clamped, loop_cadence_clamped.",
         "Timing changed for safety: flashes slowed to a safe rate, movement slowed to a safe rate, the repeating cycle slowed to a safe rate."),
        ("codex's background_glow is not used by comet.", "Codex's background glow is not used by Comet."),
        ("claude's duration_seconds cannot play exactly; the renderer uses a safe default or bound.",
         "Claude's cycle length cannot play exactly; a safe value is used."),
        ("codex's kitt cannot play exactly at this speed; showing breathe.",
         "Codex's Knight Rider cannot play exactly at this speed; showing Breathe."),
        ("Split cannot play exactly on 2 LEDs: the program exceeds 512 bytes or 20 lines.",
         "Split cannot play exactly on 2 LEDs: the pattern is too large for this device."),
        ("Comet is simplified slightly to share the strip; its native 2200 ms cycle plays in 4000 ms.",
         "Comet is simplified slightly to share the strip; its native 2200 ms cycle plays in 4000 ms."),
        ("One at a Time stretches fewer cycles to four seconds to fit the device.",
         "One at a Time stretches fewer cycles to four seconds to fit the device."),
        ("Knight Rider shows the beam's rise and fall on a one-LED share.",
         "Knight Rider shows the beam's rise and fall on a one-LED share."),
        ("One at a Time uses a circulating Knight Rider scan to fit all providers.",
         "One at a Time uses a circulating Knight Rider scan to fit all providers."),
        ("the presentation safety compiler refused the program", "The pattern could not be made safe"),
        ("safe timing leaves no room for the device brightness line", "Safe timing and brightness do not fit together"),
        ("the provider program is invalid", "The provider pattern is invalid"),
        ("the provider program could not be mapped to its share", "The provider pattern cannot play on its part of the strip"),
        ("a curved roll cannot run inside a separate share", "This moving pattern cannot play on only part of the strip"),
    ])
    func warningsUsePlainWords(_ warning: String, expected: String) {
        #expect(StudioWarning.plain(warning) == expected)
    }

    private func withStore(_ body: (CoreCommandReplyFixture, EffectStudioStore) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("studio-fix")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.scenePackLoader = { [] }
        store.renderer = { _, _, _, _ in EffectPreview(program: "#0088FF") }
        do { try await fixture.start(); try await body(fixture, store); store.windowDidClose(); await fixture.stop() }
        catch { store.windowDidClose(); await fixture.stop(); throw error }
    }

    private func seed(_ fixture: CoreCommandReplyFixture, _ store: EffectStudioStore,
                      catalog: EffectCatalog, rows: [EffectAssignment] = []) async throws {
        let load = try #require(store.reload())
        try await fixture.pending(2)
        for name in ["list_effects", "list_assignments"] {
            let pending = try await fixture.core.send("fixture_pending")
            let requests = try #require(pending.result?["requests"]?.arrayValue)
            let index = try #require(requests.firstIndex { $0["name"]?.stringValue == name })
            try await fixture.release(index: index, result: name == "list_effects" ? object(catalog) : object(EffectAssignmentDocument(assignments: rows)))
        }
        await load.value
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)).objectValue)
    }
}
