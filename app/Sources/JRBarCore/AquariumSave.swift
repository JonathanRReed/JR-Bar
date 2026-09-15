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
        return (try? JSONDecoder().decode(AquariumSave.self, from: data)) ?? AquariumSave()
    }

    /// Writes the save, creating the directory when needed.
    public func save(_ save: AquariumSave) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(save)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
