import Foundation
import Testing
@testable import JRBarCore

/// The settings document: path access over a partial document, the key
/// catalogue against the seeded mock, and `set_setting` round-trips.
@Suite("Settings document")
struct SettingsDocumentTests {
    @Test("paths parse keys and array indexes")
    func paths() {
        let path = SettingsPath("colors.agent_colors.claude")
        #expect(path.segments == [.key("colors"), .key("agent_colors"), .key("claude")])
        #expect(SettingsPath("devices.0.brightness").segments == [.key("devices"), .index(0), .key("brightness")])
        #expect(SettingsPath("devices.0.brightness").description == "devices.0.brightness")
        #expect(SettingsPath("").segments.isEmpty)
    }

    @Test("a partial document reads what it has and nil for the rest, without crashing")
    func partialDocument() throws {
        let frame = """
        {"t":"settings","v":1,"generation":3,"schema":3,"document":{
          "tips_enabled":false,
          "colors":{"agent_colors":{"claude":"#112233"},"blend_mode":"relay"},
          "devices":[{"id":"sidepulse:pro:1","brightness":120},"not an object",{"id":"sidepulse:dot:2"}],
          "screen_bar_gap_width":null,
          "usage_graph_providers":["claude",7,null],
          "x_future":{"deep":[1,2,{"three":3}]},
          "global_brightness_scale":"oops"
        }}
        """
        guard case .settings(let settings) = try CoreCodec.decode(frame: Data(frame.utf8)) else {
            Issue.record("not a settings message"); return
        }
        let document = SettingsDocument(settings.document)
        #expect(document.bool("tips_enabled") == false)
        #expect(document.string("colors.agent_colors.claude") == "#112233")
        #expect(document.string("colors.blend_mode") == "relay")
        #expect(document.double("devices.0.brightness") == 120)
        #expect(document.string("devices.0.id") == "sidepulse:pro:1")
        // Missing keys are nil, and so are wrongly typed ones.
        #expect(document.bool("idle_dim_enabled") == nil)
        #expect(document.double("global_brightness_scale") == nil)
        #expect(document.contains("global_brightness_scale"), "present even though it is the wrong type")
        #expect(document.string("colors.agent_colors.codex") == nil)
        #expect(document.double("devices.5.brightness") == nil)
        #expect(document.double("devices.1.brightness") == nil, "a non-object device entry reads as nothing")
        // An explicit null counts as provided (it means "automatic").
        #expect(document.contains("screen_bar_gap_width"))
        #expect(document.value(at: "screen_bar_gap_width")?.isNull == true)
        #expect(document.contains("screen_bar_wing_length") == false)
        // Lists keep only their strings.
        #expect(document.strings("usage_graph_providers") == ["claude"])
        // Device entries skip the junk and keep indexes honest.
        let devices = document.deviceEntries
        #expect(devices.map(\.index) == [0, 2])
        #expect(document.deviceIndex(id: "sidepulse:dot:2") == 2)
        // The catalogue reports provision per key rather than throwing.
        #expect(SettingsKey(.general, "tips_enabled", .bool).isProvided(in: document))
        #expect(!SettingsKey(.general, "idle_dim_enabled", .bool).isProvided(in: document))
        #expect(!SettingsKey(.devices, "devices[].brightness", .number).isProvided(in: document), "only one of two devices has it")
        #expect(SettingsKey(.devices, "devices[].id", .string).isProvided(in: document))
    }

    @Test("replacing writes by path and refuses out-of-range indexes")
    func replacing() {
        let document = SettingsDocument(["a": ["b": 1], "list": [["x": 1], ["x": 2]]])
        let written = document.replacing("a.b", with: 2).replacing("a.c.d", with: "new").replacing("list.1.x", with: 9)
        #expect(written.int("a.b") == 2)
        #expect(written.string("a.c.d") == "new")
        #expect(written.int("list.1.x") == 9)
        #expect(written.int("list.0.x") == 1)
        let refused = written.replacing("list.4.x", with: 0)
        #expect(refused == written)
    }

    @Test("reset paths expand devices[] per device")
    func resetPaths() {
        let document = SettingsDocument(["devices": [["id": "p", "brightness": 1], ["id": "d", "brightness": 2]], "screen_bar_min_glow": 0.25])
        let paths = SettingsKey.resetPaths(on: .devices, in: document)
        #expect(paths.contains("devices.0.brightness"))
        #expect(paths.contains("devices.1.brightness"))
        #expect(paths.contains("screen_bar_min_glow"))
        #expect(!paths.contains("devices[].brightness"))
    }

    @Test("a provider colour override applies when the hex validates and is ignored when it does not")
    func agentColourOverride() {
        let document = SettingsDocument(["colors": ["agent_colors": [
            "claude": "#112233",
            "codex": "not-a-hex",
            "gemini": "#FFF",
        ]]])
        // A valid override comes out canonical; the surfaces apply it over
        // the default accent.
        #expect(document.agentColorHex("claude") == "#112233")
        // Malformed or absent values are nil, so the default stands.
        #expect(document.agentColorHex("codex") == nil)
        #expect(document.agentColorHex("gemini") == nil)
        #expect(document.agentColorHex("pi") == nil)
        #expect(normalizedColorHex("a1b2c3") == "#A1B2C3")
        #expect(normalizedColorHex("") == nil)
    }
}

@Suite("Settings against the mock", .serialized)
struct SettingsMockTests {
    @Test("every catalogue key is in the seeded mock document")
    @MainActor
    func catalogueIsSeeded() async throws {
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

        let missing = SettingsKey.all.filter { !$0.isProvided(in: document) }.map(\.path)
        #expect(missing.isEmpty, "missing from the mock document: \(missing)")
        #expect(SettingsKey.all.count > 90)
        for page in SettingsKey.Page.allCases where page != .advanced {
            #expect(!SettingsKey.keys(on: page).isEmpty, "\(page) has controls")
        }
        // Spot checks on kinds the pages rely on.
        #expect(document.bool("tips_enabled") == true)
        #expect(document.string("colors.blend_mode") == "color_blend")
        // Strip, Dot and the remembered `virtual:status-bar` row the
        // daemon writes once the Screen Bar is enabled.
        #expect(document.deviceEntries.count == 3)
        #expect(document.double("devices.0.brightness") == 255)
        #expect(document.value(at: "screen_bar_gap_width")?.isNull == true)
        #expect(document.array("quota_alert_thresholds")?.compactMap(\.doubleValue) == [90, 95])
        // The mock plants an unknown key on purpose; the catalogue does not claim it.
        #expect(document.contains("x_mock_future_setting"))
        #expect(!SettingsKey.all.contains { $0.path == "x_mock_future_setting" })
        mock.waitUntilExit()
    }

    @Test("set_setting writes by path and the mock echoes a new document")
    @MainActor
    func setSettingRoundTrip() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "60"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await MockCoreIntegrationTests.waitForSocket(socket))
        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.isLive && model.settings != nil })
        let before = try #require(model.settings).generation

        // A top-level bool.
        let reply = try await model.setSetting("tips_enabled", value: false)
        #expect(reply.ok)
        #expect((reply.result?["generation"]?.intValue ?? 0) > before)
        #expect(await MockCoreIntegrationTests.wait { SettingsDocument(model.settings!.document).bool("tips_enabled") == false })
        #expect(model.settings!.generation > before)

        // Nested, array-indexed, and null writes.
        _ = try await model.setSetting("colors.agent_colors.claude", value: "#ABCDEF")
        _ = try await model.setSetting("devices.1.brightness", value: 77)
        _ = try await model.setSetting("screen_bar_gap_width", value: 210)
        #expect(await MockCoreIntegrationTests.wait {
            let document = SettingsDocument(model.settings!.document)
            return document.string("colors.agent_colors.claude") == "#ABCDEF"
                && document.int("devices.1.brightness") == 77
                && document.double("screen_bar_gap_width") == 210
        })
        _ = try await model.setSetting("screen_bar_gap_width", value: .null)
        #expect(await MockCoreIntegrationTests.wait { SettingsDocument(model.settings!.document).value(at: "screen_bar_gap_width")?.isNull == true })

        // An index past the end is refused, not created.
        let refused = try await model.setSetting("devices.9.brightness", value: 1)
        #expect(!refused.ok)
        #expect(refused.error?.code == "invalid_path")

        // Reset puts the page's keys back.
        let paths = SettingsKey.resetPaths(on: .lighting, in: SettingsDocument(model.settings!.document))
        let reset = try await model.resetSettings(paths: paths)
        #expect(reset.ok)
        #expect(await MockCoreIntegrationTests.wait { SettingsDocument(model.settings!.document).string("colors.agent_colors.claude") == "#D97757" })
        #expect(SettingsDocument(model.settings!.document).bool("tips_enabled") == false, "other pages untouched")

        // Hooks and calibration also round-trip through state and settings.
        model.installHooks(providers: ["pi"])
        #expect(await MockCoreIntegrationTests.wait { model.state?.health?["hooks"]?["pi"]?.stringValue == "ok" })
        _ = try await model.applyCalibrationNow(device: "sidepulse:pro:B293A1", profile: ["red_gain": 0.8, "resting_glow": 0.05])
        #expect(await MockCoreIntegrationTests.wait { SettingsDocument(model.settings!.document).double("devices.0.red_gain") == 0.8 })
        let doctor = try await model.doctor()
        #expect(doctor.ok)
        #expect(doctor.result?["checks"]?.arrayValue?.isEmpty == false)
        #expect(await MockCoreIntegrationTests.wait { !model.logTail.isEmpty })
    }
}
