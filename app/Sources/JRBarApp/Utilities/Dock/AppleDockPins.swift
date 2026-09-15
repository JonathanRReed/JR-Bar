import AppKit

/// The one-shot pin seed: read — never write — Apple's own dock's
/// `persistent-apps` so the Replace bar opens looking like the dock it
/// replaces (docs/TOY-PARITY.md, "Seed pins from `com.apple.dock
/// persistent-apps` so it matches on first run").
///
/// Read path is `UserDefaults(suiteName:)` — the same dictionary
/// `defaults read com.apple.dock persistent-apps` returns. We never
/// write the suite and never import DockDoor: entry parsing here is
/// built from the public plist shape (`tile-data.bundle-identifier`,
/// `tile-data.file-data._CFURLString`), not from anyone's source.
enum AppleDockPins {
    static let suiteName = "com.apple.dock"
    static let persistentAppsKey = "persistent-apps"

    /// One parsed tile: a resolved bundle id, or a file URL to resolve
    /// against the bundle on disk when the tile never recorded one.
    enum Seed: Equatable {
        case bundleID(String)
        case fileURL(URL)
    }

    /// The raw `persistent-apps` array, or nil when the suite or key
    /// is unreadable. Injectable for tests.
    static func persistentAppEntries(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> [[String: Any]]? {
        defaults?.array(forKey: persistentAppsKey) as? [[String: Any]]
    }

    /// Entries → seeds, in dock order. Only `file-tile`s carry apps;
    /// directory tiles and spacers are skipped. A tile with no bundle
    /// id falls back to its file URL — older macOS builds recorded the
    /// path only.
    static func seeds(fromEntries entries: [[String: Any]]) -> [Seed] {
        var seeds: [Seed] = []
        for entry in entries {
            guard let data = entry["tile-data"] as? [String: Any] else { continue }
            if let bundleID = data["bundle-identifier"] as? String, !bundleID.isEmpty {
                seeds.append(.bundleID(bundleID))
                continue
            }
            if let fileData = data["file-data"] as? [String: Any],
               let raw = fileData["_CFURLString"] as? String,
               let url = URL(string: raw), url.pathExtension.lowercased() == "app" {
                seeds.append(.fileURL(url))
            }
        }
        return seeds
    }

    /// Entries → bundle ids, resolving file-URL seeds through the app
    /// bundle on disk. The resolver is injectable so the fixture test
    /// never touches `/Applications`.
    static func bundleIDs(
        fromEntries entries: [[String: Any]],
        resolve: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for seed in seeds(fromEntries: entries) {
            let id: String?
            switch seed {
            case .bundleID(let bundleID): id = bundleID
            case .fileURL(let url): id = resolve(url)
            }
            guard let id, !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// The live read: Apple's pins in dock order, or nil when the
    /// suite won't open. `nil` and `[]` differ — nil means "couldn't
    /// read", `[]` means "read it, the dock holds no pinned apps".
    static func persistentAppBundleIDs(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        resolve: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) -> [String]? {
        guard let entries = persistentAppEntries(defaults: defaults) else { return nil }
        return bundleIDs(fromEntries: entries, resolve: resolve)
    }
}
