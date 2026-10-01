import Foundation

/// A throwaway `UserDefaults` suite for one test. `body` gets a fresh
/// suite whose plist lives in the temporary folder, named
/// `jrbar.tests.<label>.<uuid>`; on the way out the domain and its plist are
/// removed. A suite named by a path never reaches ~/Library/Preferences, so
/// a run of the suite leaves nothing in the person's real preferences
/// folder (a plain name did: the preferences daemon wrote an emptied domain
/// back after the file was deleted, 72 files a run).
@discardableResult
func withScratchDefaults<T>(_ label: String = #function, _ body: (UserDefaults) throws -> T) rethrows -> T {
    let suite = ScratchDefaults.suiteName(label)
    defer { ScratchDefaults.remove(suite) }
    return try body(ScratchDefaults.open(suite))
}

/// The same for an async test on the main actor.
@MainActor
@discardableResult
func withScratchDefaults<T>(_ label: String = #function,
                            _ body: @MainActor (UserDefaults) async throws -> T) async rethrows -> T {
    let suite = ScratchDefaults.suiteName(label)
    defer { ScratchDefaults.remove(suite) }
    return try await body(ScratchDefaults.open(suite))
}

enum ScratchDefaults {
    static let prefix = "jrbar.tests."

    /// Where scratch suites keep their plists.
    static let directory = NSTemporaryDirectory() + "jrbar-test-defaults"

    /// "<temp>/jrbar-test-defaults/jrbar.tests.draftsSurviveRelaunch.<uuid>":
    /// the label's letters and digits, so a `#function` name makes a legal
    /// domain. The path is the suite name; the plist is that path plus
    /// ".plist".
    static func suiteName(_ label: String) -> String {
        let word = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(48))
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return "\(directory)/\(prefix)\(word.isEmpty ? "scratch" : word).\(UUID().uuidString)"
    }

    static func open(_ suite: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("no defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Removes the suite's domain and its plist. Only a scratch suite:
    /// anything else is left alone. The removal is flushed before the file
    /// goes so the preferences daemon has nothing left to write back.
    static func remove(_ suite: String) {
        guard suite.hasPrefix(directory + "/\(prefix)"), !suite.contains("..") else { return }
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defaults?.synchronize()
        try? FileManager.default.removeItem(at: plist(suite))
    }

    /// Where the preferences daemon keeps a suite's plist.
    static func plist(_ suite: String) -> URL {
        URL(fileURLWithPath: suite + ".plist")
    }
}
