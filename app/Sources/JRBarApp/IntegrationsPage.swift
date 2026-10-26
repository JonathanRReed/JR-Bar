import AppKit
import JRBarCore
import JRBarUI
import SwiftUI

/// Opening this page never enables a device or an integration.
struct IntegrationsPage: View {
    let store: SettingsStore
    @ViewState private var serving: Bool?
    @ViewState private var focusAccess = SetupPermissionStatus.unknown
    @ViewState private var calendarAccess = SetupPermissionStatus.unknown
    @ViewState private var remindersAccess = SetupPermissionStatus.unknown

    private var serveEnabled: Bool { store.values.bool("serve_enabled") ?? false }
    private var serveKey: String { "\(store.isLive)-\(serveEnabled)" }
    private var hardwareDevices: [CoreDevice] { ["pro", "dot"].flatMap { hardware(kind: $0) } }
    private var firmwareKey: String {
        "\(store.isLive)-" + hardwareDevices.map { "\($0.id):\($0.enabled != false):\($0.connected == true)" }.sorted().joined(separator: ",")
    }

    var body: some View {
        SettingGroup("Connections") {
            T3CodeRow(status: store.isLive ? store.t3Integration.status : nil, running: ExternalProviders.t3Code.running)
            ForEach(["pro", "dot"], id: \.self) { kind in
                let devices = hardware(kind: kind)
                if devices.isEmpty {
                    connection(kind == "pro" ? "SidePulse Pro" : "PulseDot",
                               status: store.isLive ? "Not connected" : "Monitor not connected", page: .devices)
                } else {
                    ForEach(devices) { device in
                        let firmware = store.firmware.status?.devices.first { $0.id == device.id && $0.mounted }?.version
                        connection(device.name ?? (kind == "pro" ? "SidePulse Pro" : "PulseDot"),
                            status: IntegrationStatus.device(device, live: store.isLive, firmware: firmware), page: .devices)
                    }
                }
            }
            connection("Stream Deck", status: IntegrationStatus.server(live: store.isLive, enabled: serveEnabled,
                                                                        running: serving), page: .remote)
            connection("Creator Micro 2", status: IntegrationStatus.deck(store.deck, live: store.isLive), page: .devices)
            connection("Provider hooks", status: hookSummary, page: .agents)
        }
        .task(id: serveKey) {
            serving = nil
            guard store.isLive, serveEnabled else { return }
            // Reuse the Stream Deck card's one-shot endpoint receipt. Keep no token.
            let reply = try? await store.core.send("serve_token")
            guard !Task.isCancelled, store.isLive, serveEnabled else { return }
            serving = reply?.ok == true ? reply?.result?["running"]?.boolValue : nil
        }
        .task(id: firmwareKey) {
            await store.firmware.integrationsAppeared(devices: hardwareDevices, live: store.isLive,
                                                      stateJob: store.core.state?.firmware)
        }
        SettingGroup("Compatible apps") {
            app("Alcove", probe: ExternalProviders.alcove, page: .notch)
            app("Boring Notch", probe: ExternalProviders.boringNotch, page: .notch)
            app("Bendy", probe: ExternalProviders.bendy, page: .utilities, feature: "fold")
            app("Lid Plane", probe: ExternalProviders.lidPlane, page: .utilities, feature: "fold")
            ForEach(menuBarApps, id: \.name) { rival in
                app(rival.name, probe: ExternalAppProbe(bundleIDs: MenuBarRivals.bundleIDs(of: rival.name),
                    appNames: rival.name == "Bartender" ? ExternalProviders.bartender.appNames : ["\(rival.name).app"]),
                    page: .utilities, feature: "menuBar")
            }
            ForEach(dockApps, id: \.id) { rival in
                app(rival.name, probe: ExternalAppProbe(bundleIDs: rival.bundleIDs.sorted(),
                    appNames: ([rival.name] + rival.otherNames).map { "\($0).app" }), page: .utilities, feature: "dock")
            }
        }
        SettingGroup("System access") {
            connection("Focus Status", status: focusAccess.word, page: .alerts)
            connection("Calendar", status: calendarAccess.word, page: .notch)
            connection("Reminders", status: remindersAccess.word, page: .notch)
        }
        .task { refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
    }

    private func refreshAccess() {
        focusAccess = SetupModel.focusStatus()
        calendarAccess = SetupModel.calendarStatus()
        remindersAccess = SetupModel.reminderStatus()
    }

    private var menuBarApps: [MenuBarRivals.Rival] {
        MenuBarRivals.known.filter { rival in
            rival.handoff != nil || ExternalAppProbe(bundleIDs: MenuBarRivals.bundleIDs(of: rival.name),
                appNames: ["\(rival.name).app"]).installed
        }
    }

    private var dockApps: [UtilityRivals.Rival] {
        UtilityRivals.known.filter { rival in
            guard rival.roles.contains(.dockPreviews) || rival.roles.contains(.switcher) else { return false }
            return rival.isRunning(in: RunningApps.shared) || ExternalAppProbe(bundleIDs: rival.bundleIDs.sorted(),
                appNames: ([rival.name] + rival.otherNames).map { "\($0).app" }).installed
        }
    }

    private func hardware(kind: String) -> [CoreDevice] {
        var devices = (store.core.state?.devices ?? []).filter { $0.kind == kind }
        for entry in store.deviceEntries where entry.kind == kind {
            let enabled = store.values.bool(SettingsPath("\(entry.prefix).enabled")) ?? true
            if let index = devices.firstIndex(where: { $0.id == entry.id }) {
                devices[index].enabled = enabled
            } else {
                devices.append(CoreDevice(id: entry.id, kind: kind, name: entry.name, connected: false, enabled: enabled))
            }
        }
        return devices
    }

    private var hookSummary: String {
        guard store.isLive else { return "Monitor not connected" }
        let hooks = store.core.state?.health?["hooks"]?.objectValue ?? [:]
        guard !hooks.isEmpty else { return "Not reported" }
        return hooks.keys.sorted().map { "\(ProviderPalette.displayName(for: $0)): \(hooks[$0]?.stringValue ?? "Unknown")" }
            .joined(separator: " · ")
    }

    private func connection(_ name: String, status: String, page: SettingsStore.Page, feature: String? = nil) -> some View {
        SettingsNavigationRow(name, subtitle: status) {
            store.subpage = nil
            store.page = page
            if let feature { store.openFeature(feature) }
        }
    }

    private func app(_ name: String, probe: ExternalAppProbe, page: SettingsStore.Page, feature: String? = nil) -> some View {
        connection(name, status: IntegrationStatus.app(installed: probe.installed, running: probe.running),
                   page: page, feature: feature)
    }
}

enum IntegrationStatus {
    static func app(installed: Bool, running: Bool) -> String {
        running ? "Running" : installed ? "Not running" : "Not installed"
    }

    static func server(live: Bool, enabled: Bool, running: Bool?) -> String {
        guard live else { return "Monitor not connected" }
        guard enabled else { return "Off" }
        return running.map { $0 ? "Serving" : "Enabled, not serving" } ?? "Status not reported"
    }

    static func device(_ device: CoreDevice, live: Bool, firmware: String?) -> String {
        guard live else { return "Monitor not connected" }
        guard device.enabled != false else { return "Off" }
        guard let connected = device.connected else { return "Status not reported" }
        guard connected else { return "Not connected" }
        return "Connected · " + (firmware.map { "Firmware \($0)" } ?? "Firmware not read")
    }

    static func deck(_ deck: DeckState?, live: Bool) -> String {
        guard live else { return "Monitor not connected" }
        guard let deck else { return "Status not reported" }
        guard deck.settings.enabled else { return "Off" }
        guard deck.device?.connected == true else { return "Not connected" }
        if deck.device?.hasConflict == true { return "Connected · \(DeckDevice.conflictText)" }
        return deck.device?.approved == true ? "Connected" : "Connected · Not enabled"
    }
}
