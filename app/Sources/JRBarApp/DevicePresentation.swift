import JRBarCore
import JRBarUI

/// Saved Off wins even when the daemon omits the device or retains an old row.
enum DeviceConnectionState: String, CaseIterable {
    case off = "Off"
    case connected = "Connected"
    case notConnected = "Not connected"

    init(enabled: Bool?, connected: Bool?, live: Bool) {
        if enabled == false { self = .off }
        else if !live { self = .notConnected }
        else if let connected { self = connected ? .connected : .notConnected }
        else { self = .notConnected }
    }

    static func device(_ device: CoreDevice?, enabled: Bool? = nil, live: Bool) -> Self {
        Self(enabled: enabled ?? device?.enabled, connected: device?.connected, live: live)
    }

    static func creatorMicro(_ deck: DeckState?, live: Bool) -> Self {
        Self(enabled: deck?.settings.enabled, connected: deck?.device?.connected, live: live)
    }

    static func streamDeck(enabled: Bool?, running: Bool?, live: Bool) -> Self {
        Self(enabled: enabled, connected: running, live: live)
    }

    static func screenBar(_ device: CoreDevice?, enabled: Bool? = nil, live: Bool) -> Self {
        Self(enabled: enabled ?? device?.enabled, connected: device?.enabled ?? device?.connected, live: live)
    }

    static func toast(_ event: CoreEvent, settings: SettingsDocument?, live: Bool) -> String? {
        guard event.kind == "device_connected" || event.kind == "device_disconnected" else { return nil }
        let entry = settings?.deviceEntries.first { $0.id == event.detail }
        let state = Self(enabled: entry?.entry["enabled"]?.boolValue,
                         connected: event.kind == "device_connected", live: live)
        return state.help(name: event.label ?? event.detail ?? "Device")
    }

    static func name(kind: String, fallback: String? = nil) -> String {
        switch kind {
        case "pro": "SidePulse"
        case "dot": "PulseDot"
        case "screen_bar": "Screen Bar"
        case "deck": "Creator Micro 2"
        default: fallback ?? "Device"
        }
    }

    var isConnected: Bool { self == .connected }
    var tone: Tone { isConnected ? .done : .neutral }
    func badgeWord(live: Bool) -> String? { live ? rawValue : nil }

    func help(name: String) -> String { "\(name) · \(rawValue)" }
}

extension SettingsStore {
    func deviceConnection(_ id: String) -> DeviceConnectionState {
        let entry = deviceEntries.first { $0.id == id }
        let enabled = entry.flatMap { values.bool(SettingsPath("\($0.prefix).enabled")) }
        return .device(deviceFacts(id), enabled: enabled, live: isLive)
    }

    var creatorMicroConnection: DeviceConnectionState { .creatorMicro(deck, live: isLive) }

    var screenBarStatus: String {
        let status = ScreenBarLiveStatus.shared
        return Self.screenBarStatus(enabled: values.bool("virtual_status_device_enabled") ?? true,
                                    hiddenForApp: status.steppedAsideForApp,
                                    hiddenForVideo: status.steppedAsideForVideo)
    }

    static func screenBarStatus(enabled: Bool, hiddenForApp: String?, hiddenForVideo: Bool) -> String {
        guard enabled else { return "Off" }
        if let name = hiddenForApp { return "Hidden for \(name)" }
        if hiddenForVideo { return "Hidden in full screen" }
        return "Shown"
    }

    func streamDeckConnection(running: Bool?) -> DeviceConnectionState {
        .streamDeck(enabled: values.bool("serve_enabled"), running: running, live: isLive)
    }
}

extension PanelStore {
    func deviceConnection(kind: String) -> DeviceConnectionState {
        let reported = core.devices.first { $0.kind == kind }
        let entries = settingsDocument?.deviceEntries ?? []
        let entry = entries.first { $0.id == reported?.id } ?? entries.first {
            SettingsStore.guessKind(id: $0.id, name: $0.entry["name"]?.stringValue ?? "") == kind
        }
        return .device(reported, enabled: entry?.entry["enabled"]?.boolValue, live: isLive)
    }
}
