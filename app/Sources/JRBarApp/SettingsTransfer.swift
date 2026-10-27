import Foundation
import JRBarCore

/// Settings › General › Advanced › Transfer: every JR-Bar preference in one file —
/// the monitor's settings document, the paired devices, the Utilities
/// and Toys pages, and the app's own preferences (shortcuts, sounds, the
/// toggle strip, the update channel) — so a second Mac or a reset takes
/// one import instead of an hour. Import lists what the file holds as a
/// checklist, the way Raycast's does, and applies only what is ticked.
///
/// Pure: the store gathers and applies; this builds, reads and plans.
struct SettingsBundle: Equatable, Sendable {
    static let format = "jrbar-settings"
    static let currentVersion = 1

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case monitor, devices, utilities, toys, preferences

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monitor: return "Monitor settings"
            case .devices: return "Devices"
            case .utilities: return "Utilities"
            case .toys: return "Toys"
            case .preferences: return "Shortcuts, sounds and app preferences"
            }
        }

        var detail: String {
            switch self {
            case .monitor: return "Every page's settings — lights, notifications, quiet, usage, remote."
            case .devices: return "Names, brightness and calibration per strip. A strip another Mac knew only matches here if it is the same hardware."
            case .utilities: return "The Menu Bar, Dock and Agent Overview setups, the menu bar's curated items included."
            case .toys: return "Fold, Aquarium, Notch Buddy, Confetti and the notch card."
            case .preferences: return "Global shortcuts, event sounds, the toggle strip and the update channel."
            }
        }

        /// Ticked when a file is opened. Devices wait for a tick: they
        /// belong to the hardware on the desk they were paired at.
        var onByDefault: Bool { self != .devices }
    }

    var exportedAt: Date?
    var appVersion: String?
    var schema: Int?
    /// The monitor's document by top-level key — devices and the
    /// daemon's read-only facts left out.
    var monitor: [String: JSONValue] = [:]
    var devices: JSONValue?
    var utilities: JSONValue?
    var toys: JSONValue?
    var preferences: [String: JSONValue] = [:]

    /// Document keys that are facts about a daemon, not preferences
    /// (`set_setting` answers `read_only`), and the device list, which
    /// travels as its own category.
    nonisolated static let monitorExcluded: Set<String> = ["cloud_ingest_token_path", "devices", "scene_state", "settings_seal"]

    // MARK: Preferences

    /// The app's own preferences that travel: exact keys, and the key
    /// families every shortcut and sound lives under. Window positions,
    /// drafts, migration marks and one-time hints stay on their Mac.
    /// The panel's and the shelf's switches are spelled out: their
    /// owners are main-actor types; a test holds the spellings to them.
    nonisolated static let preferenceKeys: Set<String> = [
        "panelHotkeyEnabled", "shelfHotkeyEnabled", "studioHotkeyEnabled",
        SparkleUpdater.channelDefaultsKey, SparkleUpdater.automaticChecksDefaultsKey,
        SystemTogglesStore.awakeDisplayDefaultsKey, SystemTogglesStore.stripDefaultsKey,
    ]
    nonisolated static let preferencePrefixes = ["hotkeyChord.", "sound."]

    nonisolated static func travels(_ key: String) -> Bool {
        preferenceKeys.contains(key) || preferencePrefixes.contains { key.hasPrefix($0) }
    }

    /// A shortcut read from a file, through the recorder's own gate
    /// (`HotkeyChord.problem`). A hand-edited or shared export is not a
    /// recording: a bare key, ⌘ alone or one of macOS's own chords would
    /// be taken from every app the moment it registered.
    enum ImportedChord: Equatable, Sendable {
        /// The recorder's Delete: no shortcut.
        case unbound
        case chord(HotkeyChord)
        /// Not a chord, or one the recorder would refuse.
        case refused
    }

    nonisolated static func importedChord(_ value: JSONValue?) -> ImportedChord {
        guard let stored = value?.stringValue else { return .refused }
        if stored.isEmpty { return .unbound }
        guard let chord = HotkeyChord(storageString: stored), chord.problem == nil else { return .refused }
        return .chord(chord)
    }

    /// A defaults value as JSON: bools stay bools (CFBoolean, not the
    /// number it bridges as), strings, numbers and string lists; anything
    /// else does not travel.
    nonisolated static func json(_ value: Any) -> JSONValue? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = value as? String { return .string(text) }
        if let list = value as? [String] { return .array(list.map(JSONValue.string)) }
        return nil
    }

    /// JSON back into what `UserDefaults` stores.
    nonisolated static func defaultsValue(_ value: JSONValue) -> Any? {
        switch value {
        case .bool(let on): return on
        case .number(let number): return number
        case .string(let text): return text
        case .array(let items):
            let strings = items.compactMap(\.stringValue)
            return strings.count == items.count ? strings : nil
        case .null, .object: return nil
        }
    }

    // MARK: Building

    static func make(document: JSONValue?, schema: Int?, utilities: UtilitiesState?, toys: ToysState?,
                     defaults: [String: Any], appVersion: String, now: Date) -> SettingsBundle {
        var bundle = SettingsBundle(exportedAt: now, appVersion: appVersion, schema: schema)
        for (key, value) in document?.objectValue ?? [:] where !monitorExcluded.contains(key) && !Held.neverExported.contains(key) {
            bundle.monitor[key] = key == "usage_hooks" ? Held.withoutRules(value) : value
        }
        bundle.devices = document?["devices"]
        bundle.utilities = utilities.map { state in
            var exported = state
            exported.menuBar.triggerRules.removeAll { $0.action.runsAProgram }
            return exported
        }.flatMap(asJSON)
        bundle.toys = toys.flatMap(asJSON)
        for (key, value) in defaults where travels(key) {
            if let json = json(value) { bundle.preferences[key] = json }
        }
        return bundle
    }

    private static func asJSON<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static let utilityFields = asJSON(UtilitiesState())?.objectValue ?? [:]
    private static let toyFields: [String: JSONValue] = {
        var fields = asJSON(ToysState())?.objectValue ?? [:]
        fields["alcove"] = fields["notch"]
        return fields
    }()

    private enum PageContent: Equatable { case none, settings, malformed }

    /// Unknown fields can belong to another version. A recognized section
    /// with the wrong shape would decode as defaults and reset the page.
    private static func pageContent(_ value: JSONValue?, matching supported: [String: JSONValue]) -> PageContent {
        guard let fields = value?.objectValue else { return .none }
        var recognized = false
        for (key, incoming) in fields {
            guard let expected = supported[key] else { continue }
            recognized = true
            switch (incoming, expected) {
            case (.object, .object), (.bool, .bool): continue
            default: return .malformed
            }
        }
        return recognized ? .settings : .none
    }

    /// What the file holds, in checklist order.
    var categories: [Category] {
        Category.allCases.filter { category in
            switch category {
            case .monitor: return !monitor.isEmpty
            case .devices: return !(devices?.arrayValue ?? []).isEmpty
            case .utilities: return Self.pageContent(utilities, matching: Self.utilityFields) == .settings
            case .toys: return Self.pageContent(toys, matching: Self.toyFields) == .settings
            case .preferences: return !preferences.isEmpty
            }
        }
    }

    /// The checklist row's count.
    func summary(of category: Category) -> String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        switch category {
        case .monitor: return count(monitor.count, "setting")
        case .devices: return count(devices?.arrayValue?.count ?? 0, "device")
        case .utilities: return "\(utilities?.objectValue?.count ?? 0) sections"
        case .toys: return "\(toys?.objectValue?.count ?? 0) sections"
        case .preferences: return count(preferences.count, "preference")
        }
    }

    /// The monitor keys an import writes, in order: only keys the running
    /// monitor knows (a newer file's extras are skipped, not forced) and
    /// only values that differ. Sorted, so a consent stamp
    /// (`…_consent_version`) lands before the switch it guards. A setting
    /// that sends something off the Mac, runs a program or answers an
    /// agent is never switched on from a file: the live value stays and
    /// `needsYourOK` names it (see `Held`).
    func monitorWrites(against current: JSONValue?) -> (writes: [(key: String, value: JSONValue)], unknown: [String], needsYourOK: [String]) {
        let live = current?.objectValue ?? [:]
        var writes: [(key: String, value: JSONValue)] = []
        var unknown: [String] = []
        var held: [String] = []
        for key in monitor.keys.sorted() {
            guard let now = live[key] else { unknown.append(key); continue }
            guard let incoming = Held.settle(monitor[key]!, at: key, live: now, held: &held) else { continue }
            if now != incoming { writes.append((key, incoming)) }
        }
        return (writes, unknown, Held.unique(held))
    }

    /// The Toys page as an import would leave it: everything from the file
    /// except the switches that reach a third party or ask macOS for a
    /// permission, which keep this Mac's own value.
    static func toysForImport(_ imported: ToysState, over current: ToysState) -> (state: ToysState, needsYourOK: [String]) {
        var state = imported
        var held: [String] = []
        func keep(_ name: String, _ path: WritableKeyPath<ToysState, Bool>) {
            guard imported[keyPath: path], !current[keyPath: path] else { return }
            state[keyPath: path] = current[keyPath: path]
            held.append(name)
        }
        keep("Lyrics", \.notch.lyrics)
        keep("Lyrics", \.notch.lyricsConsented)
        keep("Camera mirror", \.notch.mirror)
        keep("Audio visualizer", \.notch.audioVisualizer)
        keep("Replace the volume and brightness HUD", \.notch.replaceSystemHUD)
        keep("Meeting alerts", \.notch.meetingAlerts)
        return (state, Held.unique(held))
    }

    /// The Utilities page as an import would leave it: the Dock and Menu
    /// Bar switches (each asks for Accessibility the moment it starts) keep
    /// this Mac's own value when the file would turn them on, and a Menu Bar
    /// script rule the file brings is left off the page.
    static func utilitiesForImport(_ imported: UtilitiesState, over current: UtilitiesState) -> (state: UtilitiesState, needsYourOK: [String]) {
        var state = imported
        var held: [String] = []
        func keep(_ name: String, _ path: WritableKeyPath<UtilitiesState, Bool>) {
            guard imported[keyPath: path], !current[keyPath: path] else { return }
            state[keyPath: path] = current[keyPath: path]
            held.append(name)
        }
        keep("Dock", \.dock.enabled)
        keep("Menu Bar", \.menuBar.enabled)
        // A Menu Bar rule that runs a shell command is a program. A file may
        // carry the rules that already live here; any other waits for the
        // person to write it on this Mac.
        let ownScripts = current.menuBar.triggerRules.filter { $0.action.runsAProgram }
        let before = state.menuBar.triggerRules.count
        state.menuBar.triggerRules = imported.menuBar.triggerRules.filter {
            !$0.action.runsAProgram || ownScripts.contains($0)
        }
        if state.menuBar.triggerRules.count != before { held.append("Menu Bar script rules") }
        return (state, Held.unique(held))
    }

    /// The preference that asks the network on its own: Sparkle's
    /// automatic check. A file can turn it off; it cannot turn it on.
    nonisolated static func preferenceNeedsYourOK(_ key: String, _ value: JSONValue, currentlyOn: Bool) -> String? {
        guard key == SparkleUpdater.automaticChecksDefaultsKey, value.boolValue == true, !currentlyOn else { return nil }
        return "Automatic update checks"
    }

    /// What a file can never switch on. An import is a person's yes to
    /// copying a layout; it is not their yes to a request that leaves the
    /// Mac, a program that runs, a phone link that answers, or a
    /// permission prompt. Each of those waits for a click on this Mac, and
    /// the import names what it left off. A file can still switch one off.
    enum Held {
        /// Monitor document paths, with the name the summary uses.
        static let monitorPaths: [String: String] = [
            "claude_plan_limits_enabled": "Claude plan limits",
            "claude_plan_limits_consent_version": "Claude plan limits",
            "provider_update_checks_enabled": "Agent update checks",
            "provider_status_feeds_enabled": "Provider status pages",
            "remote_peers.enabled": "Remote machines",
            "remote_peers.publish_enabled": "Remote machines",
            "remote_peers.include_messages": "Remote machines",
            "cloud_ingest_enabled": "Accept events from other machines",
            "escalation_webhook_url": "Escalation webhook",
            "webhook_events": "Escalation webhook",
            "ntfy_enabled": "Phone alerts",
            "ntfy_topic": "Phone alerts",
            "serve_enabled": "Local status endpoint",
            "serve_answer_enabled": "Answering from the local endpoint",
            "usage_event_hook_path": "Usage hooks",
            "usage_hooks.enabled": "Usage hooks",
            "usage_hooks.rules": "Usage hooks",
            "cliproxy_hub.enabled": "Local proxy hub",
            "cliproxy_hub.url": "Local proxy hub",
            "provider_extra_homes.claude": "Extra agent homes",
            "provider_extra_homes.codex": "Extra agent homes",
            "claude_statusline_source": "Claude status line",
        ]

        /// Off, empty or zero: a value that sends nothing and runs nothing.
        static func isOff(_ value: JSONValue) -> Bool {
            switch value {
            case .null: return true
            case .bool(let on): return !on
            case .number(let number): return number == 0
            case .string(let text): return text.isEmpty
            case .array(let items): return items.isEmpty
            case .object(let fields): return fields.isEmpty
            }
        }

        /// `value` at `path` as an import may write it, or nil when nothing
        /// is left to write. Held leaves keep `live`'s value (nil when this
        /// monitor has none) unless the file's is off.
        static func settle(_ value: JSONValue, at path: String, live: JSONValue?, held: inout [String]) -> JSONValue? {
            // Turning the away-only gate off expands when phone alerts send.
            if path == "ntfy_only_when_away", value.boolValue == false, live?.boolValue != false {
                held.append("Phone alerts")
                return live
            }
            if let name = monitorPaths[path] {
                if isOff(value) { return value }
                if value != live { held.append(name) }
                return live
            }
            guard case .object(let fields) = value, monitorPaths.keys.contains(where: { $0.hasPrefix(path + ".") }) else {
                return value
            }
            var result: [String: JSONValue] = [:]
            let liveFields = live?.objectValue ?? [:]
            for (key, child) in fields {
                if let settled = settle(child, at: path + "." + key, live: liveFields[key], held: &held) {
                    result[key] = settled
                }
            }
            for (key, child) in liveFields where result[key] == nil && fields[key] == nil { result[key] = child }
            return .object(result)
        }

        /// Top-level keys that carry a secret or a program to run: the
        /// webhook URL usually holds its token, a hook rule names an
        /// executable and its arguments. An import would never take them,
        /// so an export does not carry them either.
        static let neverExported: Set<String> = ["escalation_webhook_url", "usage_event_hook_path"]

        /// The usage hooks document without its rules.
        static func withoutRules(_ value: JSONValue) -> JSONValue {
            guard case .object(var fields) = value else { return value }
            fields["rules"] = nil
            return .object(fields)
        }

        static func unique(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }.sorted()
        }
    }

    // MARK: File

    private enum Keys: String, CodingKey {
        case format, version, exportedAt = "exported_at", appVersion = "app_version", schema
        case monitor, devices, utilities, toys, preferences
    }

    func encoded() throws -> Data {
        var object: [String: JSONValue] = [
            Keys.format.rawValue: .string(Self.format),
            Keys.version.rawValue: .number(Double(Self.currentVersion)),
        ]
        if let exportedAt { object[Keys.exportedAt.rawValue] = .string(ISO8601DateFormatter().string(from: exportedAt)) }
        if let appVersion { object[Keys.appVersion.rawValue] = .string(appVersion) }
        if let schema { object[Keys.schema.rawValue] = .number(Double(schema)) }
        if !monitor.isEmpty { object[Keys.monitor.rawValue] = .object(monitor) }
        if let devices { object[Keys.devices.rawValue] = devices }
        if let utilities { object[Keys.utilities.rawValue] = utilities }
        if let toys { object[Keys.toys.rawValue] = toys }
        if !preferences.isEmpty { object[Keys.preferences.rawValue] = .object(preferences) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSONValue.object(object))
    }

    enum ReadError: Error, Equatable, LocalizedError {
        case notJSON
        case notABundle
        case newerVersion(Int)
        case tooLarge
        case malformedPage(String)

        var errorDescription: String? {
            switch self {
            case .notJSON: return "That file is not JSON."
            case .notABundle: return "That file is not a JR-Bar settings export."
            case .tooLarge: return "That file is too large to be a JR-Bar settings export."
            case .malformedPage(let page): return "The \(page) section has a setting with the wrong type. Fix the export before importing it."
            case .newerVersion(let version): return "That export is format \(version); this JR-Bar reads format \(SettingsBundle.currentVersion). Update JR-Bar first."
            }
        }
    }

    /// An export is a few kilobytes; anything past this is not one.
    nonisolated static let maxFileBytes = 4 * 1024 * 1024

    /// Reads the file at `url`, refusing one over `maxFileBytes` before
    /// it is loaded.
    static func read(contentsOf url: URL) throws -> SettingsBundle {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxFileBytes { throw ReadError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // Bound the read itself too. The file can grow after its size check.
        while data.count <= maxFileBytes {
            let remaining = maxFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try read(data)
    }

    /// Writes the export so only its owner can read its preferences.
    /// The file is created private and then
    /// moved into place, so it is never readable half-written or in
    /// transit.
    func write(to url: URL) throws {
        let data = try encoded()
        let manager = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: staging.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func read(_ data: Data) throws -> SettingsBundle {
        guard data.count <= maxFileBytes else { throw ReadError.tooLarge }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ReadError.notJSON }
        guard value[Keys.format.rawValue]?.stringValue == format else { throw ReadError.notABundle }
        // A version that is not a number (a hand-edited "99") is not
        // a version this app can vouch for.
        guard case .number(let rawVersion)? = value[Keys.version.rawValue],
              let version = Int(exactly: rawVersion), version >= 1 else { throw ReadError.notABundle }
        if version > currentVersion { throw ReadError.newerVersion(version) }
        var bundle = SettingsBundle()
        bundle.exportedAt = value[Keys.exportedAt.rawValue]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
        bundle.appVersion = value[Keys.appVersion.rawValue]?.stringValue
        bundle.schema = value[Keys.schema.rawValue]?.intValue
        for (key, item) in value[Keys.monitor.rawValue]?.objectValue ?? [:] where !monitorExcluded.contains(key) {
            bundle.monitor[key] = item
        }
        bundle.devices = value[Keys.devices.rawValue]
        bundle.utilities = value[Keys.utilities.rawValue]
        bundle.toys = value[Keys.toys.rawValue]
        if pageContent(bundle.utilities, matching: utilityFields) == .malformed {
            throw ReadError.malformedPage("Utilities")
        }
        if pageContent(bundle.toys, matching: toyFields) == .malformed {
            throw ReadError.malformedPage("Toys")
        }
        for (key, item) in value[Keys.preferences.rawValue]?.objectValue ?? [:] where travels(key) {
            bundle.preferences[key] = item
        }
        return bundle
    }

    /// A page's state read back through its own tolerant decoder, so an
    /// older or newer file's shape fills in defaults instead of failing.
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) -> T? {
        guard let value, value.objectValue != nil, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
