import Foundation
import JRBarCore

/// What the first-run walkthrough remembers between launches, in
/// `setup.json` beside `app-state.json`.
///
/// Its own file on purpose: the walkthrough's bookkeeping is not
/// `AppState`'s to carry, and — like that file — it lives in the state
/// directory rather than user defaults (cfprefsd refused this app's
/// domain on the owner's Mac). Written atomically; a tolerant decode
/// lets older and newer builds share it.
struct SetupState: Codable, Equatable, Sendable {
    /// Shape version; bump when fields change meaning. Unknown keys are
    /// ignored either way.
    var version: Int
    /// Names of the steps the user left by the primary button (Next /
    /// Get Started / Finish) on the latest run — `SetupStore.Step` raw
    /// values as plain strings, so the file never needs the app enum.
    var completedSteps: [String]
    /// Names of the steps left by Skip.
    var skippedSteps: [String]
    /// When the Done step's Finish (or Open Toys) last ran. nil while
    /// setup has never run to its end — the fact `shouldPresentOnLaunch`
    /// reads.
    var finishedAt: Double?
    /// Launches that presented the window. A walkthrough dismissed
    /// mid-way is offered once more, then stops asking; "Run setup
    /// again" is always available from Settings.
    var presentedCount: Int
    /// The permission rows granted when JR-Bar last looked
    /// (`SetupPermission` raw values). nil until the first look, which
    /// only records; a later look that finds one of these gone says so
    /// once — the reset an OS update or a re-signed build can leave.
    var grantedPermissions: [String]?

    static let currentVersion = 1

    init(version: Int = SetupState.currentVersion, completedSteps: [String] = [],
         skippedSteps: [String] = [], finishedAt: Double? = nil, presentedCount: Int = 0,
         grantedPermissions: [String]? = nil) {
        self.version = version
        self.completedSteps = completedSteps
        self.skippedSteps = skippedSteps
        self.finishedAt = finishedAt
        self.presentedCount = presentedCount
        self.grantedPermissions = grantedPermissions
    }

    private enum CodingKeys: String, CodingKey {
        case version, completedSteps, skippedSteps, finishedAt, presentedCount, grantedPermissions
    }

    /// Missing or wrongly typed keys read as the defaults; unknown keys
    /// are ignored — the same rule `AppState` follows.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? SetupState.currentVersion
        completedSteps = (try? container.decodeIfPresent([String].self, forKey: .completedSteps)) ?? []
        skippedSteps = (try? container.decodeIfPresent([String].self, forKey: .skippedSteps)) ?? []
        finishedAt = (try? container.decodeIfPresent(Double.self, forKey: .finishedAt)) ?? nil
        presentedCount = (try? container.decodeIfPresent(Int.self, forKey: .presentedCount)) ?? 0
        grantedPermissions = (try? container.decodeIfPresent([String].self, forKey: .grantedPermissions)) ?? nil
    }
}

/// `SetupState` on disk: a small JSON document next to `app-state.json`,
/// read tolerantly and written atomically — a crash mid-write leaves the
/// previous file intact.
struct SetupStateFile: Sendable {
    let url: URL

    init(url: URL = SetupStateFile.defaultURL()) {
        self.url = url
    }

    /// `setup.json` in the state directory `app-state.json` lives in —
    /// `$XDG_STATE_HOME/jrbar` or `~/.local/state/jrbar`.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        AppStateFile.defaultURL(environment: environment)
            .deletingLastPathComponent()
            .appending(path: "setup.json")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The stored state, or the defaults when the file is missing or not
    /// readable as JSON. Never throws: a broken file must not stop a launch.
    func load() -> SetupState {
        guard let data = try? Data(contentsOf: url) else { return SetupState() }
        return (try? JSONDecoder().decode(SetupState.self, from: data)) ?? SetupState()
    }

    /// Writes the state, creating the directory when needed.
    func save(_ state: SetupState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
