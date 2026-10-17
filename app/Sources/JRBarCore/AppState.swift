import Foundation

/// The app's own remembered facts: which packaged build last installed the
/// provider hooks, whether the first launch has registered the login item,
/// and whether the Screen Bar is shown.
///
/// These used to live in `UserDefaults.standard`, but on the owner's Mac
/// cfprefsd refused every write for the app's domain (`defaults write`
/// failed the same way from the shell), so a relaunch forgot them and the
/// first-run work ran again. They live in `~/.local/state/jrbar/app-state.json`
/// now, next to the daemon's state, written atomically; user defaults are
/// left to Sparkle, which owns its own keys.
public struct AppState: Codable, Equatable, Sendable {
    /// The packaged build whose setup or existing-hook refresh completed.
    public var bundledHooksInstalledFor: String?
    /// The first packaged launch has registered the login item.
    public var loginItemRegistered: Bool
    /// The Screen Bar is shown under the notch.
    public var showScreenBar: Bool
    /// `menu_bar_icon_style`: the daemon's settings dataclass carries the
    /// field and round-trips it in the document, but the document only
    /// exists after connect — so the app keeps a launch-time copy here
    /// for the moments before the first frame. nil means the app's
    /// default.
    public var menuBarIconStyle: String?
    /// The Toys page's state (docs/TOYS.md): everything it persists lives
    /// here because the daemon's document is not the toys' to write in.
    public var toys: ToysState
    /// The Utilities page's state (docs/UTILITIES.md): the same file and
    /// the same tolerant decode as `toys`.
    public var utilities: UtilitiesState

    public init(bundledHooksInstalledFor: String? = nil, loginItemRegistered: Bool = false, showScreenBar: Bool = true,
                menuBarIconStyle: String? = nil, toys: ToysState = ToysState(),
                utilities: UtilitiesState = UtilitiesState()) {
        self.bundledHooksInstalledFor = bundledHooksInstalledFor
        self.loginItemRegistered = loginItemRegistered
        self.showScreenBar = showScreenBar
        self.menuBarIconStyle = menuBarIconStyle
        self.toys = toys
        self.utilities = utilities
    }

    private enum CodingKeys: String, CodingKey {
        case bundledHooksInstalledFor, loginItemRegistered, showScreenBar, menuBarIconStyle, toys, utilities
    }

    /// Missing or wrongly typed keys read as the defaults; unknown keys are
    /// ignored, so an older or newer app can share the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundledHooksInstalledFor = (try? container.decodeIfPresent(String.self, forKey: .bundledHooksInstalledFor)) ?? nil
        loginItemRegistered = (try? container.decodeIfPresent(Bool.self, forKey: .loginItemRegistered)) ?? false
        showScreenBar = (try? container.decodeIfPresent(Bool.self, forKey: .showScreenBar)) ?? true
        menuBarIconStyle = (try? container.decodeIfPresent(String.self, forKey: .menuBarIconStyle)) ?? nil
        toys = (try? container.decodeIfPresent(ToysState.self, forKey: .toys)) ?? ToysState()
        utilities = (try? container.decodeIfPresent(UtilitiesState.self, forKey: .utilities)) ?? UtilitiesState()
    }
}

/// `AppState` on disk: a small JSON document, read tolerantly and written
/// atomically (a temporary file in the same directory, renamed over the
/// old one), so a crash mid-write leaves the previous file intact.
public struct AppStateFile: Sendable {
    public let url: URL

    public init(url: URL = AppStateFile.defaultURL()) {
        self.url = url
    }

    /// `$XDG_STATE_HOME/jrbar/app-state.json`, else
    /// `~/.local/state/jrbar/app-state.json`: the daemon's state directory.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let directory: String
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            directory = NSString(string: xdg).expandingTildeInPath + "/jrbar"
        } else {
            directory = NSString(string: "~/.local/state/jrbar").expandingTildeInPath
        }
        return URL(fileURLWithPath: directory).appending(path: "app-state.json")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// How a load went, so a file that could not be read is told to the
    /// person rather than silently replaced by the defaults.
    public enum LoadOutcome: Equatable, Sendable {
        /// There was no file: a first launch.
        case missing
        case loaded
        /// The file was there and could not be used; the defaults stand in,
        /// and the next save keeps the old bytes as a recovery copy first.
        case unreadable(String)
    }

    /// The stored state, or the defaults when the file is missing or not
    /// readable as JSON. Never throws: a broken file must not stop a launch.
    public func load() -> AppState { loadChecked().state }

    /// `load`, and what happened.
    public func loadChecked() -> (state: AppState, outcome: LoadOutcome) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AppState(), .missing) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return (AppState(), .unreadable("the file could not be read: \(error.localizedDescription)"))
        }
        do {
            return (try JSONDecoder().decode(AppState.self, from: data), .loaded)
        } catch {
            return (AppState(), .unreadable("the file is not valid JSON for this app"))
        }
    }

    /// Keys this app wrote once and no longer does, as dotted paths. A file
    /// that still carries one is an old file, not a damaged one: dropping the
    /// key on the next save loses nothing anyone reads, so it must not cut a
    /// recovery copy. Add a path here when a key is retired.
    public static let retiredKeyPaths: Set<String> = [
        "utilities.menuBar.agentStatusItem",
        "utilities.menuBar.combinedSystemItem",
        "utilities.menuBar.combinedStatusItem",
        "utilities.menuBar.spacers",
        "utilities.menuBar.arrangeOrder",
        "utilities.menuBar.curation.forceSpacerEngine",
        "utilities.agents.grouping",
        "utilities.agents.rowLimit",
        "utilities.agents.showElapsed",
        "utilities.agents.showEnded",
        "utilities.agents.showIdle",
        "utilities.agents.showRemote",
        "utilities.dataHoarderEnabled",
        "utilities.dataHoarder",
        "toys.fold.holdPicture",
        "toys.notch.weather",
        "toys.notch.weatherCity",
        "toys.notch.weatherUseIPLocation",
    ]

    /// Writes the state, creating the directory when needed.
    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decoded = try? decoder.decode(AppState.self, from: previous)
            let normalized = try decoded.map { try encoder.encode($0) }
            let previousJSON = try? decoder.decode(JSONValue.self, from: previous)
            let normalizedJSON = try normalized.map { try decoder.decode(JSONValue.self, from: $0) }
            let preserved: Bool
            if let previousJSON, let normalizedJSON {
                preserved = Self.preserves(previousJSON, in: normalizedJSON, at: "")
            } else {
                preserved = false
            }
            if !preserved {
                let recovery = directory.appending(path: "app-state.recovery-\(UUID().uuidString).json")
                // Preserve the original bytes before replacing a damaged
                // file. A failed backup leaves the original untouched.
                try previous.write(to: recovery, options: [.withoutOverwriting])
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: recovery.path)
                try? Self.pruneRecoveryCopies(in: directory)
            }
        }
        try data.write(to: url, options: [.atomic])
    }

    /// Recovery copies exist to rescue a damaged file — beyond the newest
    /// few they are identical backups that would accumulate on every save.
    private static func pruneRecoveryCopies(in directory: URL, keep: Int = 5) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("app-state.recovery-") && $0.hasSuffix(".json") }
        guard names.count > keep else { return }
        // UUID names carry no order — age comes from the file's mtime.
        let aged = names.compactMap { name -> (String, Date)? in
            let path = directory.appending(path: name)
            guard let modified = try? FileManager.default
                .attributesOfItem(atPath: path.path)[.modificationDate] as? Date else { return nil }
            return (name, modified)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in aged.dropFirst(keep) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Missing fields may gain defaults. Values and fields present in the
    /// original must survive, including unknown fields from a newer app.
    private static func preserves(_ original: JSONValue, in normalized: JSONValue, at path: String) -> Bool {
        switch (original, normalized) {
        case let (.object(before), .object(after)):
            return before.allSatisfy { key, value in
                let here = path.isEmpty ? key : path + "." + key
                // A retired key is gone on purpose.
                if retiredKeyPaths.contains(here) { return true }
                return after[key].map { preserves(value, in: $0, at: here) } ?? false
            }
        case let (.array(before), .array(after)):
            guard before.count == after.count else { return false }
            if zip(before, after).allSatisfy({ preserves($0.0, in: $0.1, at: path) }) { return true }
            // A set of words (the providers a trigger names) comes back
            // in whatever order this process hashes it: the same words in
            // another order lose nothing, so it is not a damaged file.
            let wordsBefore = before.compactMap { value -> String? in
                if case .string(let word) = value { return word } else { return nil }
            }
            let wordsAfter = after.compactMap { value -> String? in
                if case .string(let word) = value { return word } else { return nil }
            }
            return wordsBefore.count == before.count && wordsAfter.count == after.count
                && wordsBefore.sorted() == wordsAfter.sorted()
        default:
            return original == normalized
        }
    }
}
