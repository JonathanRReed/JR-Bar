import SwiftUI
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Device connection render proof")
@MainActor
struct DeviceConnectionRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func connectedAndCachedOffline() throws {
        let connected = DevicePresentationTests.fixture(live: true)
        let offline = DevicePresentationTests.fixture(live: false)
        try WindowsRenderProofTests.write("device-connection-current-and-cached", size: CGSize(width: 1100, height: 520)) {
            HStack(alignment: .top, spacing: 16) {
                cards(connected)
                cards(offline)
            }
            .padding(16)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func consolidatedScreenBarSettings() throws {
        let cases: [(name: String, automatic: Bool, live: Bool, entry: Bool, enabled: Bool?)] = [
            ("automatic", true, true, true, true),
            ("manual", false, true, true, true),
            ("mirrored", false, true, true, true),
            ("offline", true, false, true, true),
            ("missing-settings", false, true, false, true),
            ("hidden", false, true, true, false),
            ("unreported", false, true, true, nil),
        ]
        for item in cases {
            let store = Self.screenBarFixture(automatic: item.automatic, live: item.live,
                                              entry: item.entry, enabled: item.enabled, mirror: item.name == "mirrored")
            store.openFolds.insert(SettingsFold.screenBar)
            let device = DevicesPage.Layout(entries: store.deviceEntries).screenBar
            let height: CGFloat = item.entry ? 1600 : 1000
            try WindowsRenderProofTests.write("screen-bar-single-card-\(item.name)", size: CGSize(width: 620, height: height)) {
                Form {
                    ScreenBarSettingsCard(store: store, device: device)
                }
                .formStyle(.grouped)
                .environment(store)
            }
        }
    }

    private static func screenBarFixture(automatic: Bool, live: Bool, entry: Bool, enabled: Bool?, mirror: Bool) -> SettingsStore {
        let store = DevicePresentationTests.fixture(live: true)
        let device: JSONValue = .object([
            "id": .string("virtual:status-bar"), "name": .string("Screen Bar"),
            "led_display": .string("agent"), "brightness": .number(122),
            "auto_brightness_enabled": .bool(automatic), "provider_pin": .null,
            "signal_policy": .null, "blend_mode": .null,
            "red_gain": .number(1), "green_gain": .number(1), "blue_gain": .number(1),
            "resting_glow": .number(0),
        ])
        store.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array(entry ? [device] : []),
                "virtual_status_device_enabled": .bool(true),
                "screen_bar_follow_alcove": .bool(true),
                "screen_bar_show_in_full_screen": .bool(true),
                "screen_bar_hidden_apps": .array([]),
                "screen_bar_notch_wings": .bool(true), "screen_bar_notch_profile": .string("auto"),
                "link_screen_bar_to_hardware": .bool(mirror),
                "screen_bar_phase_offset_ms": .number(0), "screen_bar_gap_width": .null,
                "screen_bar_wing_length": .null, "screen_bar_min_glow": .number(0.25),
                "colors": .object(["blend_mode": .string("color_blend")]),
            ]))))
        let reported = enabled.map { CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: $0) }
        store.core.apply(.state(CoreState(devices: reported.map { [$0] } ?? [])))
        store.core.apply(.lights(CoreLights(surfaces: [
            "screen_bar": CoreLightSurface(program: "#FF9F0A 1s none", why: "working"),
        ])))
        if !live { store.core.stop() }
        return store
    }

    private func cards(_ store: SettingsStore) -> some View {
        Form {
            ForEach(store.deviceEntries) { device in
                DeviceCard(store: store, device: device, firmware: store.firmware)
            }
            Section {
                DotRoleControls(store: store, inDeviceCard: false)
            }
        }
        .formStyle(.grouped)
    }
}
