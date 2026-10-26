import JRBarCore

/// Saved Off wins even when the daemon omits the device or retains an old row.
enum DeviceConnectionState: String, CaseIterable {
    case off = "Off"
    case connected = "Connected"
    case notConnected = "Not connected"
    case unknown = "Unknown"

    init(enabled: Bool?, connected: Bool?, live: Bool) {
        if enabled == false { self = .off }
        else if !live { self = .unknown }
        else if let connected { self = connected ? .connected : .notConnected }
        else { self = .unknown }
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

    static func toast(_ event: CoreEvent, settings: SettingsDocument?, live: Bool) -> String? {
        guard event.kind == "device_connected" || event.kind == "device_disconnected" else { return nil }
        let entry = settings?.deviceEntries.first { $0.id == event.detail }
        let state = Self(enabled: entry?.entry["enabled"]?.boolValue,
                         connected: event.kind == "device_connected", live: live)
        return state.help(name: event.label ?? event.detail ?? "Device")
    }

    var isConnected: Bool { self == .connected }

    func help(name: String) -> String { "\(name) · \(rawValue)" }
}

extension SettingsStore {
    func deviceConnection(_ id: String) -> DeviceConnectionState {
        let entry = deviceEntries.first { $0.id == id }
        let enabled = entry.flatMap { values.bool(SettingsPath("\($0.prefix).enabled")) }
        return .device(deviceFacts(id), enabled: enabled, live: isLive)
    }

    var creatorMicroConnection: DeviceConnectionState { .creatorMicro(deck, live: isLive) }

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
