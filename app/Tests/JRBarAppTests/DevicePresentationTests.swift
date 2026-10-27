import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Device connection presentation")
@MainActor
struct DevicePresentationTests {
    static func fixture(live: Bool) -> SettingsStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-device-presentation.sock")
        core.handle(.connected)
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array([
                    .object(["id": .string("pro"), "name": .string("SidePulse Pro")]),
                    .object(["id": .string("dot"), "name": .string("SidePulse Dot")]),
                ]),
                "devices_linked": .bool(true),
                "dot_role": .string("asks"),
            ]))))
        core.apply(.state(CoreState(devices: [
            CoreDevice(id: "pro", kind: "pro", connected: true, lastWrite: 1_800_000_000),
            CoreDevice(id: "dot", kind: "dot", connected: true, lastWrite: 1_800_000_000),
        ])))
        core.apply(.lights(CoreLights(surfaces: [
            "hardware": CoreLightSurface(program: "#FF9F0A 1s none", why: "waiting"),
            "dot": CoreLightSurface(program: "#FF9F0A 1s none", why: "waiting", role: "asks"),
        ])))
        if !live { core.stop() }
        return SettingsStore(core: core)
    }

    @Test func configuredScreenBarUsesReportedVirtualDeviceFacts() throws {
        let store = Self.fixture(live: true)
        store.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array([
                    .object(["id": .string("virtual:status-bar"), "name": .string("Screen Bar")]),
                ]),
            ]))))
        store.core.apply(.state(CoreState(devices: [
            CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: true, lastWrite: 1_800_000_001),
        ])))
        let surface = CoreLightSurface(program: "#FF9F0A 1s none", why: "working")
        store.core.apply(.lights(CoreLights(surfaces: ["screen_bar": surface])))
        let device = try #require(store.deviceFacts("virtual:status-bar"))
        #expect(device.id == "screen-bar")
        #expect(device.enabled == true)
        #expect(store.deviceEntries.first?.id == "virtual:status-bar")
        #expect(DevicesPage.screenBarStatus(device: device, live: store.isLive) == "Connected")
        #expect(store.deviceLastWrite("virtual:status-bar") == 1_800_000_001)
        #expect(store.deviceSurface("virtual:status-bar") == surface)
        store.core.stop()
        #expect(DevicesPage.screenBarStatus(device: store.deviceFacts("virtual:status-bar"), live: store.isLive)
            == "Monitor not connected")
        store.core.handle(.connected)
        store.core.apply(.state(CoreState(devices: [])))
        #expect(store.deviceFacts("virtual:status-bar") == nil)
        #expect(DevicesPage.screenBarStatus(device: store.deviceFacts("virtual:status-bar"), live: store.isLive)
            == "Not connected")
    }

    @Test func screenBarHasOneSettingsSeatWithoutChangingDeviceIndexes() throws {
        let entries = [
            SettingsStore.DeviceEntry(index: 0, id: "pro", name: "SidePulse Pro", kind: "pro"),
            SettingsStore.DeviceEntry(index: 1, id: "virtual:status-bar", name: "Screen Bar", kind: "screen_bar"),
            SettingsStore.DeviceEntry(index: 2, id: "dot", name: "SidePulse Dot", kind: "dot"),
            SettingsStore.DeviceEntry(index: 3, id: "other", name: "Other device", kind: "unknown"),
        ]
        let layout = DevicesPage.Layout(entries: entries)
        #expect(layout.devices.map(\.id) == ["pro", "dot", "other"])
        let bar = try #require(layout.screenBar)
        #expect(bar.id == "virtual:status-bar")
        #expect(bar.prefix == "devices.1")
        #expect(layout.devices.map(\.prefix) == ["devices.0", "devices.2", "devices.3"])
        let withoutBar = DevicesPage.Layout(entries: layout.devices)
        #expect(withoutBar.screenBar == nil)
        #expect(withoutBar.devices.map(\.id) == layout.devices.map(\.id))
        #expect(DevicesPage.Layout(entries: []).devices.isEmpty)
    }

    @Test func screenBarHeaderNeverPresentsCachedVisibilityAsLive() {
        let shown = CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: true)
        let hidden = CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: false)
        let unknown = CoreDevice(id: "screen-bar", kind: "screen_bar")
        #expect(DevicesPage.screenBarStatus(device: shown, live: true) == "Connected")
        #expect(DevicesPage.screenBarStatus(device: hidden, live: true) == "Off")
        #expect(DevicesPage.screenBarStatus(device: nil, live: true) == "Not connected")
        #expect(DevicesPage.screenBarStatus(device: unknown, live: true) == "Not connected")
        #expect(DevicesPage.screenBarStatus(device: shown, live: false) == "Monitor not connected")
        #expect(DevicesPage.screenBarStatus(device: hidden, live: false) == "Monitor not connected")
        #expect(DevicesPage.screenBarStatus(device: nil, live: false) == "Monitor not connected")
    }

    @Test func screenBarBrightnessAndCalibrationKeepTheirConfiguredWritePath() throws {
        let store = Self.fixture(live: true)
        store.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["devices": .array([
                .object(["id": .string("pro"), "brightness": .number(200), "red_gain": .number(1)]),
                .object(["id": .string("virtual:status-bar"), "brightness": .number(122), "red_gain": .number(1)]),
                .object(["id": .string("dot"), "brightness": .number(40), "red_gain": .number(1)]),
            ])]))))
        let bar = try #require(DevicesPage.Layout(entries: store.deviceEntries).screenBar)
        let brightness = store.double("\(bar.prefix).brightness", default: 255)
        brightness.wrappedValue = 96
        store.set("\(bar.prefix).red_gain", .number(0.8), throttled: true)
        #expect(store.values.double("devices.1.brightness") == 96)
        #expect(store.values.double("devices.1.red_gain") == 0.8)
        #expect(store.values.double("devices.0.brightness") == 200)
        #expect(store.values.double("devices.2.brightness") == 40)
        #expect(store.values.double("devices.0.red_gain") == 1)
        #expect(store.values.double("devices.2.red_gain") == 1)
        store.core.stop()
    }

    @Test func cachedDeviceIsNotConnectedWhileTheMonitorIsAway() throws {
        let store = Self.fixture(live: false)
        let device = try #require(store.deviceFacts("pro"))
        #expect(device.isPresent)
        #expect(DeviceConnectionState.device(device, live: store.isLive).rawValue == "Unknown")
        store.core.handle(.connected)
        store.core.apply(.state(CoreState(devices: [device])))
        #expect(DeviceConnectionState.device(device, live: store.isLive).rawValue == "Connected")
    }

    @Test func unknownAndDisconnectedDevicesAreNamed() {
        #expect(DeviceConnectionState.device(nil, live: true).rawValue == "Unknown")
        #expect(DeviceConnectionState.device(nil, live: false).rawValue == "Unknown")
        let absent = CoreDevice(id: "dot", kind: "dot", connected: false, error: "")
        #expect(DeviceConnectionState.device(absent, live: true).rawValue == "Not connected")
    }
}
