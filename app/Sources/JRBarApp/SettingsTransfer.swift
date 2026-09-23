import Foundation
import JRBarCore

/// Settings › Advanced › Transfer: every JR-Bar preference in one file —
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
            case .utilities: return "The Menu Bar, Dock, Agent Overview and Data Hoarder setups, the menu bar's curated items included."
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
    nonisolated static let monitorExcluded: Set<String> = ["cloud_ingest_token_path", "devices"]

    // MARK: Preferences

    /// The app's own preferences that travel: exact keys, and the key
    /// families every shortcut and sound lives under. Window positions,
    /// drafts, migration marks and one-time hints stay on their Mac.
    /// The panel's and the shelf's switches are spelled out: their
    /// owners are main-actor types; a test holds the spellings to them.
    nonisolated static let preferenceKeys: Set<String> = [
        "panelHotkeyEnabled", "shelfHotkeyEnabled",
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
        for (key, value) in document?.objectValue ?? [:] where !monitorExcluded.contains(key) {
            bundle.monitor[key] = value
        }
        bundle.devices = document?["devices"]
        bundle.utilities = utilities.flatMap(asJSON)
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

    /// What the file holds, in checklist order.
    var categories: [Category] {
        Category.allCases.filter { category in
            switch category {
            case .monitor: return !monitor.isEmpty
            case .devices: return !(devices?.arrayValue ?? []).isEmpty
            case .utilities: return utilities?.objectValue != nil
            case .toys: return toys?.objectValue != nil
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
    /// (`…_consent_version`) lands before the switch it guards.
    func monitorWrites(against current: JSONValue?) -> (writes: [(key: String, value: JSONValue)], unknown: [String]) {
        let live = current?.objectValue ?? [:]
        var writes: [(key: String, value: JSONValue)] = []
        var unknown: [String] = []
        for key in monitor.keys.sorted() {
            guard let now = live[key] else { unknown.append(key); continue }
            if now != monitor[key] { writes.append((key, monitor[key]!)) }
        }
        return (writes, unknown)
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

        var errorDescription: String? {
            switch self {
            case .notJSON: return "That file is not JSON."
            case .notABundle: return "That file is not a JR-Bar settings export."
            case .newerVersion(let version): return "That export is format \(version); this JR-Bar reads format \(SettingsBundle.currentVersion). Update JR-Bar first."
            }
        }
    }

    static func read(_ data: Data) throws -> SettingsBundle {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ReadError.notJSON }
        guard value[Keys.format.rawValue]?.stringValue == format else { throw ReadError.notABundle }
        let version = value[Keys.version.rawValue]?.intValue ?? 0
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
