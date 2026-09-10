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
    /// The build stamp whose `agent-monitor install all` last succeeded.
    public var bundledHooksInstalledFor: String?
    /// The first packaged launch has registered the login item.
    public var loginItemRegistered: Bool
    /// The Screen Bar is shown under the notch.
    public var showScreenBar: Bool

    public init(bundledHooksInstalledFor: String? = nil, loginItemRegistered: Bool = false, showScreenBar: Bool = true) {
        self.bundledHooksInstalledFor = bundledHooksInstalledFor
        self.loginItemRegistered = loginItemRegistered
        self.showScreenBar = showScreenBar
    }

    private enum CodingKeys: String, CodingKey {
        case bundledHooksInstalledFor, loginItemRegistered, showScreenBar
    }

    /// Missing or wrongly typed keys read as the defaults; unknown keys are
    /// ignored, so an older or newer app can share the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundledHooksInstalledFor = (try? container.decodeIfPresent(String.self, forKey: .bundledHooksInstalledFor)) ?? nil
        loginItemRegistered = (try? container.decodeIfPresent(Bool.self, forKey: .loginItemRegistered)) ?? false
        showScreenBar = (try? container.decodeIfPresent(Bool.self, forKey: .showScreenBar)) ?? true
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

    /// The stored state, or the defaults when the file is missing or not
    /// readable as JSON. Never throws: a broken file must not stop a launch.
    public func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        return (try? JSONDecoder().decode(AppState.self, from: data)) ?? AppState()
    }

    /// Writes the state, creating the directory when needed.
    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
