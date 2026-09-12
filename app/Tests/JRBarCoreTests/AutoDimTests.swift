import Foundation
import Testing
@testable import JRBarCore

/// The `auto_dim` setting: the document mapping (paths, defaults, the
/// daemon's lenient reading), `lights.auto_dim` decoding, the readout line
/// under the Lighting controls, and the words the why popover uses.
@Suite("Auto-dim")
struct AutoDimTests {
    @Test("the daemon's defaults read back from an empty document and round-trip through to_dict")
    func defaults() {
        let settings = AutoDimSettings(document: SettingsDocument())
        #expect(settings == AutoDimSettings.defaults)
        #expect(settings.mode == .off)
        #expect(settings.scheduleStartMinutes == 1320 && settings.scheduleEndMinutes == 420)
        #expect(settings.scheduleFraction == 0.3)
        #expect(settings.displayMinFraction == 0.15)
        #expect(settings.ambientMinFraction == 0.1 && settings.ambientLuxFloor == 5 && settings.ambientLuxCeiling == 400)

        let document = SettingsDocument(.object(["auto_dim": settings.document]))
        #expect(AutoDimSettings.isProvided(in: document))
        #expect(AutoDimSettings(document: document) == settings)
        #expect(document.string(AutoDimSettings.modePath) == "off")
        #expect(document.double(AutoDimSettings.scheduleStartPath) == 1320)
        #expect(document.double(AutoDimSettings.ambientLuxCeilingPath) == 400)
        for path in AutoDimSettings.allPaths {
            #expect(document.contains(path), "\(path) is written by to_dict")
        }
        #expect(!AutoDimSettings.isProvided(in: SettingsDocument()))
    }

    @Test("every catalogue path under auto_dim is one the daemon's document has")
    func catalogue() throws {
        guard case .settings(let settings) = try CoreFixtures.message("real_settings.json") else {
            Issue.record("not a settings message"); return
        }
        let document = SettingsDocument(settings.document)
        #expect(settings.schema == 3)
        let keys = SettingsKey.keys(on: .lighting).filter { $0.path.hasPrefix("auto_dim.") }
        #expect(keys.count == 8)
        for key in keys {
            #expect(key.isProvided(in: document), "\(key.path) is in the daemon's document")
            #expect(AutoDimSettings.allPaths.map(\.description).contains(key.path))
        }
        #expect(AutoDimSettings(document: document) == AutoDimSettings.defaults, "the owner's daemon ships the defaults")
    }

    @Test("malformed fields fall back the way AutoDimSettings.from_dict does")
    func lenient() {
        let document = SettingsDocument(.object(["auto_dim": .object([
            "mode": .string("dusk"),
            "schedule": .object(["start_minutes": .number(-5), "end_minutes": .number(9999), "fraction": .number(0)]),
            "display": .object(["min_fraction": .string("x")]),
            "ambient": .object(["min_fraction": .number(4), "lux_floor": .number(900), "lux_ceiling": .number(10)]),
        ])]))
        let settings = AutoDimSettings(document: document)
        #expect(settings.mode == .off, "an unknown mode is off")
        #expect(settings.scheduleStartMinutes == 0 && settings.scheduleEndMinutes == 1439, "minutes clamp to the day")
        #expect(settings.scheduleFraction == AutoDimSettings.minFraction, "fractions clamp to the floor")
        #expect(settings.displayMinFraction == 0.15, "a non-number is the default")
        #expect(settings.ambientMinFraction == 1, "fractions clamp to one")
        #expect(settings.ambientLuxFloor == 5 && settings.ambientLuxCeiling == 400, "a ceiling under the floor resets both")

        let partial = SettingsDocument(.object(["auto_dim": .object(["mode": .string("schedule")])]))
        let scheduled = AutoDimSettings(document: partial)
        #expect(scheduled.mode == .schedule && scheduled.scheduleFraction == 0.3)
        #expect(scheduled.summary == "schedule 22:00–07:00 to 30%")
    }

    @Test("the schedule window may wrap midnight and an empty window never matches")
    func schedule() {
        var settings = AutoDimSettings.defaults
        #expect(settings.scheduleActive(nowMinutes: 23 * 60))
        #expect(settings.scheduleActive(nowMinutes: 3 * 60))
        #expect(!settings.scheduleActive(nowMinutes: 12 * 60))
        #expect(!settings.scheduleActive(nowMinutes: 7 * 60), "the end is exclusive")
        settings.scheduleStartMinutes = 9 * 60
        settings.scheduleEndMinutes = 17 * 60
        #expect(settings.scheduleActive(nowMinutes: 12 * 60) && !settings.scheduleActive(nowMinutes: 20 * 60))
        settings.scheduleEndMinutes = 9 * 60
        #expect(!settings.scheduleActive(nowMinutes: 9 * 60))
    }

    @Test("summaries for every mode")
    func summaries() {
        var settings = AutoDimSettings.defaults
        #expect(settings.summary == "off")
        settings.mode = .display
        #expect(settings.summary == "follows display, floor 15%")
        settings.mode = .ambient
        #expect(settings.summary == "ambient 5–400 lux, floor 10%")
        settings.ambientLuxFloor = 2.5
        #expect(settings.summary == "ambient 2.5–400 lux, floor 10%")
        for mode in AutoDimSettings.Mode.allCases {
            #expect(!mode.label.isEmpty && !mode.detail.isEmpty)
        }
    }

    @Test("lights.auto_dim decodes from the daemon's frame and tolerates a missing or odd one")
    func decode() throws {
        guard case .lights(let lights) = try CoreFixtures.message("real_lights.json") else {
            Issue.record("not a lights message"); return
        }
        let autoDim = try #require(lights.autoDim)
        #expect(autoDim == CoreAutoDim(mode: "off", source: "off", factor: 1.0, available: true, reading: nil))
        #expect(!autoDim.isActive)
        #expect(lights.linked == true && lights.devicesLinked == true)
        #expect(lights.linkedSkewMs == 14.2)
        #expect(lights.screenBar?.whyDetail?.dimming == [])

        let bare = try CoreCodec.decode(frame: Data(#"{"t":"lights","v":1,"surfaces":{}}"#.utf8))
        guard case .lights(let plain) = bare else { Issue.record("not lights"); return }
        #expect(plain.autoDim == nil && plain.devicesLinked == nil)

        let odd = try CoreCodec.decode(frame: Data(#"{"t":"lights","v":1,"surfaces":{},"auto_dim":{"mode":"ambient","source":"display","factor":"x","available":false,"reading":0.62,"x":1}}"#.utf8))
        guard case .lights(let fallback) = odd else { Issue.record("not lights"); return }
        let result = try #require(fallback.autoDim)
        #expect(result.mode == "ambient" && result.source == "display" && !result.available)
        #expect(result.factor == nil, "a non-number factor is dropped, not fatal")
        #expect(result.reading == 0.62)

        let broken = try CoreCodec.decode(frame: Data(#"{"t":"lights","v":1,"surfaces":{},"auto_dim":"nope"}"#.utf8))
        guard case .lights(let dropped) = broken else { Issue.record("not lights"); return }
        #expect(dropped.autoDim == nil)
    }

    @Test("the readout line: what was read and the factor chosen, per mode and source")
    func readout() {
        #expect(AutoDimReadout.line(nil) == nil)
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "off", source: "off", factor: 1.0)) == "Off → 100%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "ambient", source: "ambient", factor: 0.45, available: true, reading: 12)) == "Ambient: 12 lux → 45%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "ambient", source: "ambient", factor: 0.1, available: true, reading: 2.5)) == "Ambient: 2.5 lux → 10%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "ambient", source: "display", factor: 0.62, available: false, reading: 0.62)) == "Sensor unavailable, following display: 62% → 62%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "ambient", source: "display", factor: 1.0, available: false, reading: nil)) == "Sensor unavailable, display unreadable → 100%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "display", source: "display", factor: 0.62, available: true, reading: 0.62)) == "Display: 62% → 62%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "display", source: "display", factor: 0.15, available: true, reading: 0.05)) == "Display: 5% → 15%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "display", source: "display", factor: 1.0, available: false, reading: nil)) == "Display unreadable → 100%")
        let settings = AutoDimSettings.defaults
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "schedule", source: "schedule", factor: 0.3, available: true, reading: 1390), settings: settings) == "Schedule: 23:10, inside the window → 30%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "schedule", source: "schedule", factor: 1.0, available: true, reading: 600), settings: settings) == "Schedule: 10:00, outside the window → 100%")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "schedule", source: "schedule", factor: 0.3, available: true, reading: 1390)) == "Schedule: 23:10, inside the window → 30%", "without the settings the factor says which side")
        #expect(AutoDimReadout.line(CoreAutoDim(mode: "twilight", source: "twilight", factor: 0.5)) == "Twilight → 50%", "a future mode still reads")
    }

    @Test("the why popover says Auto-dim (mode) and lists the setting")
    func whyPopover() throws {
        #expect(AutoDimReadout.dimmingWord(nil) == "Auto-dim")
        #expect(AutoDimReadout.dimmingWord(CoreAutoDim(mode: "schedule", source: "schedule", factor: 0.3)) == "Auto-dim (schedule)")
        #expect(AutoDimReadout.dimmingWord(CoreAutoDim(mode: "display", source: "display", factor: 0.6)) == "Auto-dim (display)")
        #expect(AutoDimReadout.dimmingWord(CoreAutoDim(mode: "ambient", source: "ambient", factor: 0.4)) == "Auto-dim (ambient)")
        #expect(AutoDimReadout.dimmingWord(CoreAutoDim(mode: "ambient", source: "display", factor: 0.6, available: false)) == "Auto-dim (ambient, following display)")

        // The real frames, with the schedule switched on and the light dimmed by it.
        guard case .lights(var lights) = try CoreFixtures.message("real_lights.json"),
              case .settings(let settings) = try CoreFixtures.message("real_settings.json"),
              case .state(let state) = try CoreFixtures.message("real_state.json") else {
            Issue.record("fixtures"); return
        }
        var document = SettingsDocument(settings.document)
        let off = try #require(LightExplainer.explain(lights: lights, state: state, settings: document))
        #expect(off.details.first { $0.label == "Auto-dim" }?.value == "off")
        #expect(!off.details.contains { $0.label == "Dimming" })

        document = document.replacing(AutoDimSettings.modePath, with: .string("schedule"))
        lights.autoDim = CoreAutoDim(mode: "schedule", source: "schedule", factor: 0.3, available: true, reading: 1390)
        var surface = try #require(lights.surfaces["screen_bar"])
        surface.whyDetail = CoreWhyDetail(session: surface.whyDetail?.session, label: surface.whyDetail?.label, provider: surface.whyDetail?.provider,
                                          secondsInState: 12.8, brightnessFactor: 0.3, dimming: ["auto_dim"])
        lights.surfaces["screen_bar"] = surface
        let dimmed = try #require(LightExplainer.explain(lights: lights, state: state, settings: document))
        #expect(dimmed.details.first { $0.label == "Dimming" }?.value == "Auto-dim (schedule) · 30%")
        #expect(dimmed.details.first { $0.label == "Auto-dim" }?.value == "schedule 22:00–07:00 to 30% · Schedule: 23:10, inside the window → 30%")
        #expect(dimmed.headline.hasPrefix("Cyan chase: Claude jr-bar-67 is working") || dimmed.headline.contains("is working"), "the headline is the working one: \(dimmed.headline)")

        // Every other word keeps the plain spelling.
        surface.whyDetail = CoreWhyDetail(session: nil, label: nil, provider: nil, secondsInState: 1, brightnessFactor: 0.06, dimming: ["idle_dim", "quiet", "sleep", "auto_dim"])
        lights.surfaces["screen_bar"] = surface
        let stacked = try #require(LightExplainer.explain(lights: lights, state: state, settings: document))
        #expect(stacked.details.first { $0.label == "Dimming" }?.value == "idle dim, quiet, sleep, Auto-dim (schedule) · 6%")
    }
}

/// `set_setting auto_dim.*` against the mock: the document echoes the
/// write and `lights.auto_dim` follows it.
@Suite("Auto-dim against the mock", .serialized)
struct AutoDimMockTests {
    @Test("auto_dim keys round-trip and lights.auto_dim follows the mode")
    @MainActor
    func roundTrip() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "60"])
        defer {
            mock.terminate()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.settings != nil && model.lights != nil })

        let seeded = AutoDimSettings(document: SettingsDocument(try #require(model.settings).document))
        #expect(seeded == AutoDimSettings.defaults, "the mock seeds the daemon's defaults")
        let before = try #require(model.lights?.autoDim)
        #expect(before.mode == "off" && before.source == "off" && before.factor == 1.0 && before.available)

        // Ambient: the mock has no sensor, so it follows the display and says so.
        let ambient = try await model.setSetting(AutoDimSettings.modePath, value: .string("ambient"))
        #expect(ambient.ok)
        #expect(await MockCoreIntegrationTests.wait { model.lights?.autoDim?.mode == "ambient" })
        let fallback = try #require(model.lights?.autoDim)
        #expect(fallback.source == "display" && !fallback.available && fallback.reading == 0.62)
        #expect(AutoDimReadout.line(fallback) == "Sensor unavailable, following display: 62% → 62%")
        #expect(AutoDimReadout.dimmingWord(fallback) == "Auto-dim (ambient, following display)")
        #expect(model.lights?.screenBar?.whyDetail?.dimming == ["auto_dim"])
        #expect(model.lights?.screenBar?.whyDetail?.brightnessFactor == 0.62)

        // Display with a floor above the reading: the floor wins.
        _ = try await model.setSetting(AutoDimSettings.modePath, value: .string("display"))
        let floor = try await model.setSetting(AutoDimSettings.displayMinFractionPath, value: .number(0.8))
        #expect(floor.ok)
        #expect(await MockCoreIntegrationTests.wait { model.lights?.autoDim?.factor == 0.8 })
        #expect(model.lights?.autoDim?.available == true)
        #expect(SettingsDocument(try #require(model.settings).document).double(AutoDimSettings.displayMinFractionPath) == 0.8)

        // Schedule: every path writes, and the readout is the wall clock.
        _ = try await model.setSetting(AutoDimSettings.modePath, value: .string("schedule"))
        _ = try await model.setSetting(AutoDimSettings.scheduleStartPath, value: .number(0))
        _ = try await model.setSetting(AutoDimSettings.scheduleEndPath, value: .number(1439))
        let fraction = try await model.setSetting(AutoDimSettings.scheduleFractionPath, value: .number(0.25))
        #expect(fraction.ok)
        #expect(await MockCoreIntegrationTests.wait { model.lights?.autoDim?.factor == 0.25 })
        let scheduled = try #require(model.lights?.autoDim)
        #expect(scheduled.source == "schedule" && scheduled.available)
        let settings = AutoDimSettings(document: SettingsDocument(try #require(model.settings).document))
        #expect(settings.mode == .schedule && settings.scheduleStartMinutes == 0 && settings.scheduleEndMinutes == 1439 && settings.scheduleFraction == 0.25)
        #expect(AutoDimReadout.line(scheduled, settings: settings)?.hasSuffix("inside the window → 25%") == true)

        for path in [AutoDimSettings.ambientMinFractionPath, AutoDimSettings.ambientLuxFloorPath, AutoDimSettings.ambientLuxCeilingPath] {
            let reply = try await model.setSetting(path, value: .number(7))
            #expect(reply.ok, "\(path) is writable")
        }
        #expect(await MockCoreIntegrationTests.wait { SettingsDocument(model.settings?.document ?? .null).double(AutoDimSettings.ambientLuxCeilingPath) == 7 })
        #expect(AutoDimSettings(document: SettingsDocument(try #require(model.settings).document)).ambientLuxFloor == 5,
                "a ceiling at the floor reads back as the defaults, the way the daemon reads it")
    }
}
