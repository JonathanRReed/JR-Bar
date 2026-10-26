import Foundation
import Testing
import SwiftUI
@testable import JRBarApp
@testable import JRBarCore

@Suite("Device state across views")
@MainActor
struct DeviceStateMatrixTests {
    enum Hardware: String, CaseIterable {
        case pro, dot, streamDeck, creatorMicro
    }

    static func fixture(_ hardware: Hardware, _ state: DeviceConnectionState) -> SettingsStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-device-matrix.sock")
        core.handle(.connected)
        let name = hardware == .dot ? "PulseDot" : "SidePulse Pro"
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array([.object([
                    "id": .string(hardware.rawValue), "name": .string(name),
                    "enabled": .bool(state != .off), "brightness": .number(128),
                ])]),
                "serve_enabled": .bool(state != .off),
            ]))))
        let connected: Bool? = state == .unknown ? nil : state == .connected
        // Off reproduces the daemon dropping the row entirely.
        let devices = state == .off ? [] : [CoreDevice(id: hardware.rawValue, kind: hardware.rawValue,
            name: name, connected: connected)]
        let deck = DeckState(device: connected.map { DeckDevice(connected: $0, approved: true) },
                             settings: DeckSettings(enabled: state != .off))
        core.apply(.state(CoreState(devices: devices, deck: deck)))
        return SettingsStore(core: core)
    }

    @Test(arguments: Hardware.allCases, DeviceConnectionState.allCases)
    func matrix(hardware: Hardware, expected: DeviceConnectionState) throws {
        let store = Self.fixture(hardware, expected)
        let panel = PanelStore(core: store.core,
            draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("device-matrix"))!)
        let chips = PanelDevicesRow(store: panel).chips
        switch hardware {
        case .pro, .dot:
            let entry = try #require(store.deviceEntries.first)
            let card = DeviceCard(store: store, device: entry, firmware: store.firmware)
            // The header and row visibility use the same property on the real card.
            #expect(card.connection == expected)
            let event = CoreEvent(id: "fixture-event", kind: expected == .connected ? "device_connected" : "device_disconnected",
                                  label: entry.name, detail: entry.id)
            let toast = DeviceConnectionState.toast(event, settings: panel.settingsDocument, live: expected != .unknown)
            #expect(toast == "\(entry.name) · \(expected.rawValue)")
            #expect(card.connection.isConnected == (expected == .connected))
            let chip = try #require(chips.first { $0.id == hardware.rawValue })
            #expect(chip.state == expected.rawValue)
            #expect(chip.present == expected.isConnected)
            #expect(chip.help.contains(" · " + expected.rawValue))
            let view = DeviceChip(name: chip.name, present: chip.present, dimmed: false, state: chip.state)
            #expect(view.accessibilityText == "\(chip.name) \(expected.rawValue)")
            let facts = store.deviceFacts(entry.id) ?? CoreDevice(id: entry.id, kind: entry.kind)
            let integration = IntegrationStatus.device(facts, state: store.deviceConnection(entry.id), firmware: nil)
            #expect(integration.split(separator: "·").first?.trimmingCharacters(in: .whitespaces) == expected.rawValue)
        case .streamDeck:
            let running: Bool? = expected == .unknown ? nil : expected == .connected
            #expect(store.streamDeckConnection(running: running) == expected)
            #expect(IntegrationStatus.server(live: true, enabled: expected != .off, running: running) == expected.rawValue)
            // The panel has no Stream Deck status chip.
            #expect(!chips.contains { $0.id == hardware.rawValue })
        case .creatorMicro:
            let card = CreatorMicroCard(store: store)
            #expect(card.connection == expected)
            #expect(card.statusText == expected.rawValue)
            #expect(IntegrationStatus.deck(store.deck, live: true) == expected.rawValue)
            // The panel has no Creator Micro status chip.
            #expect(!chips.contains { $0.id == hardware.rawValue })
        }
        store.core.stop()
    }

    @Test(arguments: [Hardware.pro, .dot])
    func offOverridesStaleConnectedRowsAndOfflineMonitor(hardware: Hardware) {
        let store = Self.fixture(hardware, .off)
        store.core.apply(.state(CoreState(devices: [CoreDevice(id: hardware.rawValue,
            kind: hardware.rawValue, connected: true, enabled: true)])))
        #expect(store.deviceConnection(hardware.rawValue) == .off)
        let panel = PanelStore(core: store.core,
            draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("device-off"))!)
        #expect(panel.deviceConnection(kind: hardware.rawValue) == .off)
        store.core.stop()
        #expect(store.deviceConnection(hardware.rawValue) == .off)
        #expect(panel.deviceConnection(kind: hardware.rawValue) == .off)
    }

    @Test(arguments: Hardware.allCases)
    func monitorLossDoesNotClaimAConnection(hardware: Hardware) {
        let store = Self.fixture(hardware, .connected)
        store.core.stop()
        switch hardware {
        case .pro, .dot: #expect(store.deviceConnection(hardware.rawValue) == .unknown)
        case .creatorMicro: #expect(store.creatorMicroConnection == .unknown)
        case .streamDeck: #expect(store.streamDeckConnection(running: true) == .unknown)
        }
    }
}

@Suite("Disabled device render proofs")
@MainActor
struct DisabledDeviceRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func devicesAndPanelHover() throws {
        let store = DeviceStateMatrixTests.fixture(.pro, .off)
        store.core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "devices": .array([
                    .object(["id": .string("pro"), "name": .string("SidePulse Pro"), "enabled": .bool(false),
                             "brightness": .number(128)]),
                    .object(["id": .string("dot"), "name": .string("PulseDot"), "enabled": .bool(true),
                             "brightness": .number(128)]),
                ]),
                "serve_enabled": .bool(true),
            ]))))
        store.core.apply(.state(CoreState(devices: [CoreDevice(id: "dot", kind: "dot", name: "PulseDot", connected: true)],
            deck: DeckState(device: DeckDevice(connected: true, approved: true), settings: DeckSettings(enabled: true)))))
        let panel = PanelStore(core: store.core,
            draftsDefaults: UserDefaults(suiteName: ScratchDefaults.suiteName("device-off-proof"))!)
        try WindowsRenderProofTests.write("devices-one-off", size: CGSize(width: 760, height: 1200), requiresKey: false) {
            Form { DevicesPage(store: store) }
                .formStyle(.grouped)
                .environment(store)
                .environment(\.ledPreviewsHeld, true)
        }
        let row = PanelDevicesRow(store: panel)
        let chip = try #require(row.chips.first { $0.id == "pro" })
        // Show the exact system-help string without posting mouse input.
        try WindowsRenderProofTests.write("panel-hover-one-off", size: CGSize(width: 500, height: 160), plate: .glass, requiresKey: false) {
            VStack(alignment: .leading, spacing: 12) {
                row
                Text(chip.help)
                    .font(.system(size: 11))
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 12)
            }
        }
        store.core.stop()
    }
}
