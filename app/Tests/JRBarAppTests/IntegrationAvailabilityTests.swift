import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Integration availability")
struct IntegrationAvailabilityTests {
    @MainActor
    @Test func firmwareReadsOnlyConnectedEnabledHardware() async {
        let link = FakeFirmwareLink()
        let store = FirmwareStore(send: link.send)
        let off = CoreDevice(id: "fixture-pro", kind: "pro", connected: true, enabled: false)
        let absent = CoreDevice(id: "fixture-dot", kind: "dot", connected: false, enabled: true)
        let bar = CoreDevice(id: "screen-bar", kind: "screen_bar", connected: true, enabled: true)
        await store.integrationsAppeared(devices: [off, absent, bar], live: true, stateJob: nil)
        let active = CoreDevice(id: "fixture-pro", kind: "pro", connected: true, enabled: true)
        await store.integrationsAppeared(devices: [active], live: false, stateJob: nil)
        #expect(link.sent.isEmpty)
        await store.integrationsAppeared(devices: [active], live: true, stateJob: nil)
        #expect(link.names == ["firmware_status"])
        #expect(store.status?.devices.first?.version == "1.0.2")
    }

    @Test func missingAndStoppedApps() {
        #expect(IntegrationStatus.app(installed: false, running: false) == "Not installed")
        #expect(IntegrationStatus.app(installed: true, running: false) == "Not running")
        #expect(IntegrationStatus.app(installed: false, running: true) == "Running")
        let missing = T3CodeStatus(present: false, enabled: false, readOnly: true)
        #expect(missing.line == "Not installed")
    }

    @Test func endpointEnablementIsNotAReceipt() {
        #expect(IntegrationStatus.server(live: true, enabled: false, running: true) == "Off")
        #expect(IntegrationStatus.server(live: true, enabled: true, running: nil) == "Status not reported")
        #expect(IntegrationStatus.server(live: true, enabled: true, running: false) == "Enabled, not serving")
        #expect(IntegrationStatus.server(live: true, enabled: true, running: true) == "Serving")
        #expect(IntegrationStatus.server(live: false, enabled: true, running: true) == "Monitor not connected")
    }

    @Test func disabledAndDisconnectedHardwareNeverClaimsConnection() {
        var device = CoreDevice(id: "fixture-pro", kind: "pro", connected: true, enabled: true)
        #expect(IntegrationStatus.device(device, live: true, firmware: "1.2.3") == "Connected · Firmware 1.2.3")
        #expect(IntegrationStatus.device(device, live: true, firmware: nil) == "Connected · Firmware not read")
        device.enabled = false
        #expect(IntegrationStatus.device(device, live: true, firmware: "1.2.3") == "Off")
        device.enabled = true
        device.connected = false
        #expect(IntegrationStatus.device(device, live: true, firmware: "1.2.3") == "Not connected")
        device.connected = nil
        #expect(IntegrationStatus.device(device, live: true, firmware: "1.2.3") == "Status not reported")
        #expect(IntegrationStatus.device(device, live: false, firmware: "1.2.3") == "Monitor not connected")
        var deck = DeckState(device: DeckDevice(connected: true, approved: true))
        deck.settings.enabled = false
        #expect(IntegrationStatus.deck(deck, live: true) == "Off")
        deck.settings.enabled = true
        #expect(IntegrationStatus.deck(deck, live: true) == "Connected")
        deck.device?.approved = false
        #expect(IntegrationStatus.deck(deck, live: true) == "Connected · Not enabled")
        deck.device?.connected = false
        #expect(IntegrationStatus.deck(deck, live: true) == "Not connected")
        #expect(IntegrationStatus.deck(deck, live: false) == "Monitor not connected")
        deck.device?.connected = true
        deck.device?.conflict = "foreign_responses"
        #expect(IntegrationStatus.deck(deck, live: true).contains(DeckDevice.conflictText))
        #expect(!IntegrationStatus.deck(deck, live: true).contains("foreign_responses"))
    }
}
