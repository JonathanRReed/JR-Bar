import Foundation

/// The aquarium game's own save document (docs/TOYS.md): deliberately
/// NOT `app-state.json` — the game writes often and the toys' document
/// shouldn't pay for it. `version` leaves room for a future migration;
/// every field under `game` decodes tolerantly either way.
public struct AquariumSave: Codable, Equatable, Sendable {
    /// The schema this build writes.
    public static let currentVersion = 1

    public var version: Int
    public var game: AquariumGame

    public init(version: Int = AquariumSave.currentVersion,
                game: AquariumGame = AquariumGame()) {
        self.version = version
        self.game = game
    }

    private enum CodingKeys: String, CodingKey {
        case version, game
    }

    /// A missing or mistyped `version` reads as the current one (the
    /// game document itself already tolerates anything); a missing or
    /// corrupt `game` falls back to a fresh tank rather than failing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        game = (try? c.decodeIfPresent(AquariumGame.self, forKey: .game)) ?? AquariumGame()
    }
}

/// `AquariumSave` on disk: `aquarium-save.json` in the daemon's state
/// directory, read tolerantly and written atomically (a temp file in
/// the same directory renamed over the old one), like `AppStateFile`.
public struct AquariumSaveFile: Sendable {
    public let url: URL

    public init(url: URL = AquariumSaveFile.defaultURL()) {
        self.url = url
    }

    /// `$XDG_STATE_HOME/jrbar/aquarium-save.json`, else
    /// `~/.local/state/jrbar/aquarium-save.json`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let directory: String
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            directory = NSString(string: xdg).expandingTildeInPath + "/jrbar"
        } else {
            directory = NSString(string: "~/.local/state/jrbar").expandingTildeInPath
        }
        return URL(fileURLWithPath: directory).appending(path: "aquarium-save.json")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The stored save, or a fresh one when the file is missing or not
    /// readable as JSON. Never throws: a broken file must not stop a
    /// launch — the tank just starts over.
    public func load() -> AquariumSave {
        guard let data = try? Data(contentsOf: url) else { return AquariumSave() }
        var save = (try? JSONDecoder().decode(AquariumSave.self, from: data)) ?? AquariumSave()
        // The marathon clock measures a live stretch of work and nothing
        // ticks while the app is off, so a bank saved at quit would only
        // pay the whale for time nobody worked. A load starts it fresh.
        // (Done here, not in the decoder: the round-trip normalization in
        // `save` must still see the field's stored value.)
        save.game.continuousWorkSeconds = 0
        return save
    }

    /// Writes the save, creating the directory when needed.
    ///
    /// `checkingPrevious` reads the file it replaces back first and keeps
    /// a recovery copy when this build would drop anything in it. Once a
    /// process has written the file itself, what is there is its own
    /// output, so `AquariumSaveWriter` checks only its first save.
    public func save(_ save: AquariumSave, checkingPrevious: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(save)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if checkingPrevious, FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decoded = try? decoder.decode(AquariumSave.self, from: previous)
            let normalized = try decoded.map { try encoder.encode($0) }
            let previousJSON = try? decoder.decode(JSONValue.self, from: previous)
            let normalizedJSON = try normalized.map { try decoder.decode(JSONValue.self, from: $0) }
            let preserved: Bool
            if let previousJSON, let normalizedJSON {
                preserved = Self.preserves(previousJSON, in: normalizedJSON)
            } else {
                preserved = false
            }
            if !preserved {
                let recovery = directory.appending(
                    path: "aquarium-save.recovery-\(UUID().uuidString).json")
                // Preserve the exact bytes before replacing a damaged or
                // partly unreadable save. If backup or permission hardening
                // fails, the original remains the authoritative file.
                try previous.write(to: recovery, options: [.withoutOverwriting])
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: recovery.path)
            }
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    /// Defaults may fill absent fields, but every value and field present in
    /// the original must survive normalization or the original needs backup.
    private static func preserves(_ original: JSONValue, in normalized: JSONValue) -> Bool {
        switch (original, normalized) {
        case let (.object(before), .object(after)):
            return before.allSatisfy { key, value in
                after[key].map { preserves(value, in: $0) } ?? false
            }
        case let (.array(before), .array(after)):
            return before.count == after.count
                && zip(before, after).allSatisfy { preserves($0.0, in: $0.1) }
        default:
            return original == normalized
        }
    }
}

/// Writes `AquariumSave`s on a utility queue, never on the caller's
/// thread: the encode, the read-back check and the atomic write cost the
/// main thread 3–25 ms a save. Saves land in order and a burst collapses
/// to its newest. The read-back check runs on the first save of the
/// process only — after that the file is this writer's own output.
public final class AquariumSaveWriter: @unchecked Sendable {
    public let file: AquariumSaveFile
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// The newest save not yet written, and whether a drain is queued.
    /// Guarded by `lock`.
    private var pending: AquariumSave?
    private var drainQueued = false
    /// Whether this writer has written the file once. Touched only on
    /// `queue`.
    private var wroteOnce = false

    public init(file: AquariumSaveFile,
                queue: DispatchQueue = DispatchQueue(label: "jrbar.aquarium-save", qos: .utility)) {
        self.file = file
        self.queue = queue
    }

    /// Queues `save`; it replaces a save still waiting its turn.
    public func write(_ save: AquariumSave) {
        lock.lock()
        pending = save
        let queueDrain = !drainQueued
        drainQueued = true
        lock.unlock()
        guard queueDrain else { return }
        queue.async { [self] in drain() }
    }

    /// Waits for every queued save to land: at quit, and in tests.
    public func flush() {
        queue.sync {}
    }

    private func drain() {
        lock.lock()
        let save = pending
        pending = nil
        drainQueued = false
        lock.unlock()
        guard let save else { return }
        do {
            try file.save(save, checkingPrevious: !wroteOnce)
            wroteOnce = true
        } catch {
            // A failed write keeps the check for the next one; the game
            // itself is still in memory and saves again on its next move.
        }
    }
}
