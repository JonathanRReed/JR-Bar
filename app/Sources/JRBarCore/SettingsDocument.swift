import Foundation

/// A dot path into the settings document: `colors.agent_colors.claude`,
/// `devices.0.brightness`. Integer segments index arrays. This is the
/// `path` argument of `set_setting`, and the shape the mock daemon writes.
public struct SettingsPath: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public enum Segment: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    public let segments: [Segment]

    public init(_ text: String) {
        segments = text.split(separator: ".", omittingEmptySubsequences: true).map { piece in
            if let index = Int(piece), piece.first?.isNumber == true { return .index(index) }
            return .key(String(piece))
        }
    }

    public init(stringLiteral value: String) { self.init(value) }

    public init(segments: [Segment]) { self.segments = segments }

    public var description: String {
        segments.map { segment in
            switch segment {
            case .key(let key): return key
            case .index(let index): return String(index)
            }
        }.joined(separator: ".")
    }

    public func appending(_ key: String) -> SettingsPath { SettingsPath(segments: segments + [.key(key)]) }
    public func appending(index: Int) -> SettingsPath { SettingsPath(segments: segments + [.index(index)]) }
}

/// The daemon's settings document with typed, path-addressed reads and a
/// pure `replacing` write, so the app can overlay optimistic edits without
/// keeping a copy of its own schema. Absent or wrongly typed values read as
/// `nil`; the views turn that into "not provided by core".
public struct SettingsDocument: Hashable, Sendable {
    public var root: JSONValue

    public init(_ root: JSONValue = .object([:])) { self.root = root }

    public func value(at path: SettingsPath) -> JSONValue? {
        var current = root
        for segment in path.segments {
            switch segment {
            case .key(let key):
                guard let next = current[key] else { return nil }
                current = next
            case .index(let index):
                guard let next = current[index] else { return nil }
                current = next
            }
        }
        return current
    }

    /// True when the path resolves to any value, including JSON null
    /// (an explicit "unset" such as `screen_bar_gap_width: null`).
    public func contains(_ path: SettingsPath) -> Bool { value(at: path) != nil }

    public func bool(_ path: SettingsPath) -> Bool? { value(at: path)?.boolValue }
    public func double(_ path: SettingsPath) -> Double? { value(at: path)?.doubleValue }
    public func int(_ path: SettingsPath) -> Int? { value(at: path)?.intValue }
    public func string(_ path: SettingsPath) -> String? { value(at: path)?.stringValue }
    public func strings(_ path: SettingsPath) -> [String]? { value(at: path)?.arrayValue?.compactMap(\.stringValue) }
    public func object(_ path: SettingsPath) -> [String: JSONValue]? { value(at: path)?.objectValue }
    public func array(_ path: SettingsPath) -> [JSONValue]? { value(at: path)?.arrayValue }

    /// A copy with `value` at `path`, creating intermediate objects; an
    /// array index past the end is refused (the document stays as it was).
    public func replacing(_ path: SettingsPath, with value: JSONValue) -> SettingsDocument {
        SettingsDocument(Self.set(value, in: root, segments: path.segments[...]))
    }

    private static func set(_ value: JSONValue, in node: JSONValue, segments: ArraySlice<SettingsPath.Segment>) -> JSONValue {
        guard let head = segments.first else { return value }
        let rest = segments.dropFirst()
        switch head {
        case .key(let key):
            var members = node.objectValue ?? [:]
            members[key] = set(value, in: members[key] ?? .object([:]), segments: rest)
            return .object(members)
        case .index(let index):
            guard var items = node.arrayValue, items.indices.contains(index) else { return node }
            items[index] = set(value, in: items[index], segments: rest)
            return .array(items)
        }
    }

    // MARK: Devices

    /// `devices[]` entries, as (index, object); a device that is not an
    /// object is skipped rather than crashing the page.
    public var deviceEntries: [(index: Int, id: String, entry: [String: JSONValue])] {
        guard let devices = array("devices") else { return [] }
        return devices.enumerated().compactMap { index, item in
            guard let object = item.objectValue else { return nil }
            let id = object["id"]?.stringValue ?? "device-\(index)"
            return (index, id, object)
        }
    }

    public func deviceIndex(id: String) -> Int? {
        deviceEntries.first { $0.id == id }?.index
    }
}

// MARK: - Key catalogue

/// Every setting the Settings window can read or write, by page. Paths are
/// the Python `AgentMonitorSettings` document keys where one exists (see
/// `src/jrbar/_settings_legacy.py`); the few that do not are listed under
/// `SettingsKey.appIntroduced`. A test checks that the seeded mock
/// document carries every one of these.
public struct SettingsKey: Hashable, Sendable, Identifiable {
    public enum Page: String, CaseIterable, Sendable {
        case general, agents, usage, devices, lighting, notifications, remote, advanced
    }

    public enum Kind: Sendable, Hashable {
        case bool, number, string, stringList, numberList, object, nullableNumber, nullableString
    }

    public let page: Page
    /// A document path. `devices[]` stands for every element of the
    /// `devices` array (the page addresses one by index at runtime).
    public let path: String
    public let kind: Kind

    public var id: String { path }

    public init(_ page: Page, _ path: String, _ kind: Kind) {
        self.page = page
        self.path = path
        self.kind = kind
    }

    public static let providers = ["claude", "codex", "gemini", "pi", "grok", "devin", "opencode", "openclaw", "antigravity", "cursor", "hermes", "kiro"]
    public static let transcriptProviders = ["claude", "codex"]
    public static let fadeModes = ["working", "ask", "idle"]

    public static let all: [SettingsKey] = {
        var keys: [SettingsKey] = [
            // General
            SettingsKey(.general, "menu_bar_icon_style", .string),
            SettingsKey(.general, "menu_bar_label_enabled", .bool),
            SettingsKey(.general, "virtual_status_device_enabled", .bool),
            SettingsKey(.general, "screen_bar_follow_alcove", .bool),
            SettingsKey(.general, "screen_bar_show_in_full_screen", .bool),
            SettingsKey(.general, "link_screen_bar_to_hardware", .bool),
            SettingsKey(.general, "global_brightness_scale", .number),
            SettingsKey(.general, "tips_enabled", .bool),
            // Agents
            SettingsKey(.agents, "subagent_asks_alert", .bool),
            SettingsKey(.agents, "session_open_preferences", .object),
            // Usage
            SettingsKey(.usage, "usage_graph_providers", .stringList),
            SettingsKey(.usage, "usage_display_mode", .string),
            SettingsKey(.usage, "usage_graph_days", .number),
            SettingsKey(.usage, "claude_plan_limits_enabled", .bool),
            SettingsKey(.usage, "claude_plan_limits_consent_version", .number),
            SettingsKey(.usage, "quota_alerts_enabled", .bool),
            SettingsKey(.usage, "quota_alert_thresholds", .numberList),
            SettingsKey(.usage, "capacity_history_enabled", .bool),
            SettingsKey(.usage, "capacity_history_retention_days", .number),
            // Devices & Screen Bar
            SettingsKey(.devices, "devices[].led_display", .string),
            SettingsKey(.devices, "devices[].brightness", .number),
            SettingsKey(.devices, "devices[].auto_brightness_enabled", .bool),
            SettingsKey(.devices, "devices[].provider_pin", .nullableString),
            SettingsKey(.devices, "devices[].signal_policy", .nullableString),
            SettingsKey(.devices, "devices[].red_gain", .number),
            SettingsKey(.devices, "devices[].green_gain", .number),
            SettingsKey(.devices, "devices[].blue_gain", .number),
            SettingsKey(.devices, "devices[].resting_glow", .number),
            SettingsKey(.devices, "devices_linked", .bool),
            SettingsKey(.devices, "screen_bar_gap_width", .nullableNumber),
            SettingsKey(.devices, "screen_bar_wing_length", .nullableNumber),
            SettingsKey(.devices, "screen_bar_bracket_style", .string),
            SettingsKey(.devices, "screen_bar_min_glow", .number),
            // Lighting
            SettingsKey(.lighting, "colors.blend_mode", .string),
            SettingsKey(.lighting, "colors.cycle_speed_seconds", .number),
            SettingsKey(.lighting, "colors.done_celebration_enabled", .bool),
            SettingsKey(.lighting, "idle_dim_enabled", .bool),
            SettingsKey(.lighting, "idle_dim_after_minutes", .number),
            SettingsKey(.lighting, "idle_dim_fraction", .number),
            SettingsKey(.lighting, "sleep_dim_enabled", .bool),
            SettingsKey(.lighting, "sleep_dim_fraction", .number),
            SettingsKey(.lighting, "idle_auto_off_enabled", .bool),
            SettingsKey(.lighting, "idle_auto_off_after_minutes", .number),
            SettingsKey(.lighting, "active_scene", .string),
            // Notifications & Focus
            SettingsKey(.notifications, "completion_notification_enabled", .bool),
            SettingsKey(.notifications, "completion_sweep_enabled", .bool),
            SettingsKey(.notifications, "escalation_tier", .string),
            SettingsKey(.notifications, "escalation_ramp_seconds", .number),
            SettingsKey(.notifications, "escalation_menu_bar_seconds", .number),
            SettingsKey(.notifications, "escalation_final_seconds", .number),
            SettingsKey(.notifications, "alert_burst", .number),
            SettingsKey(.notifications, "dnd_schedule_enabled", .bool),
            SettingsKey(.notifications, "dnd_schedule_start_minutes", .number),
            SettingsKey(.notifications, "dnd_schedule_end_minutes", .number),
            SettingsKey(.notifications, "dnd_schedule_mode", .string),
            SettingsKey(.notifications, "dnd_dim_fraction", .number),
            SettingsKey(.notifications, "focus_sync_enabled", .bool),
            SettingsKey(.notifications, "focus_dim_rules", .object),
            SettingsKey(.notifications, "dnd_focus_mode", .string),
            SettingsKey(.notifications, "agent_keep_awake_enabled", .bool),
            SettingsKey(.notifications, "keep_display_awake", .bool),
            SettingsKey(.notifications, "closed_lid_awake_policy", .string),
            SettingsKey(.notifications, "keep_awake_on_battery", .bool),
            SettingsKey(.notifications, "battery_monitoring.low_battery_alert_enabled", .bool),
            SettingsKey(.notifications, "battery_monitoring.low_battery_threshold_percent", .number),
            // Remote
            SettingsKey(.remote, "remote_peers.enabled", .bool),
            SettingsKey(.remote, "remote_peers.publish_enabled", .bool),
            SettingsKey(.remote, "remote_peers.remote_interrupts_muted", .bool),
            SettingsKey(.remote, "remote_peers.unmuted_machines", .stringList),
            SettingsKey(.remote, "remote_peers.muted_machines", .stringList),
            SettingsKey(.remote, "cloud_ingest_enabled", .bool),
            SettingsKey(.remote, "cloud_ingest_token_path", .string),
            SettingsKey(.remote, "escalation_webhook_url", .string),
            SettingsKey(.remote, "webhook_events", .stringList),
        ]
        for provider in providers {
            keys.append(SettingsKey(.lighting, "colors.agent_colors.\(provider)", .string))
        }
        for provider in transcriptProviders {
            keys.append(SettingsKey(.agents, "transcript_monitoring.\(provider)", .bool))
        }
        for mode in fadeModes {
            keys.append(SettingsKey(.lighting, "colors.fade_floor.\(mode)", .number))
            keys.append(SettingsKey(.lighting, "colors.fade_ceiling.\(mode)", .number))
        }
        return keys
    }()

    /// Keys with no Python field: the daemon is expected to add them. The
    /// mock document carries them so the pages can be exercised.
    public static let appIntroduced: Set<String> = [
        "menu_bar_icon_style", "devices_linked", "cloud_ingest_token_path",
        "devices[].resting_glow", "quota_alert_thresholds",
    ]

    public static func keys(on page: Page) -> [SettingsKey] { all.filter { $0.page == page } }

    /// Resolves the catalogue path against a document: a plain path must
    /// exist; a `devices[]` path must exist in every device entry (and
    /// there must be at least one).
    public func isProvided(in document: SettingsDocument) -> Bool {
        if path.hasPrefix("devices[].") {
            let leaf = String(path.dropFirst("devices[].".count))
            let entries = document.deviceEntries
            guard !entries.isEmpty else { return false }
            return entries.allSatisfy { $0.entry[leaf] != nil }
        }
        return document.contains(SettingsPath(path))
    }

    /// The concrete paths this page resets: catalogue paths, with
    /// `devices[]` expanded to every device in the document.
    public static func resetPaths(on page: Page, in document: SettingsDocument) -> [String] {
        keys(on: page).flatMap { key -> [String] in
            if key.path.hasPrefix("devices[].") {
                let leaf = String(key.path.dropFirst("devices[].".count))
                return document.deviceEntries.map { "devices.\($0.index).\(leaf)" }
            }
            return [key.path]
        }
    }
}
