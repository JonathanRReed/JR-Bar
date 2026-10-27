import Foundation
import JRBarTestSupport

/// A throwaway `UserDefaults` suite for one test. `body` gets a fresh
/// suite whose plist lives in the temporary folder, named
/// `jrbar.tests.<label>.<uuid>`; on the way out the domain and its plist are
/// removed with their directory. A path-named suite stays out of
/// ~/Library/Preferences, so
/// a run of the suite leaves nothing in the person's real preferences
/// folder (a plain name did: the preferences daemon wrote an emptied domain
/// back after the file was deleted, 72 files a run).
@discardableResult
func withScratchDefaults<T>(_ label: String = #function, _ body: (UserDefaults) throws -> T) rethrows -> T {
    let directory = try! TestTemporaryDirectory()
    let suite = ScratchDefaults.suiteName(label, directory: directory.url)
    defer {
        ScratchDefaults.remove(suite, directory: directory.url)
        try? directory.remove()
    }
    return try body(ScratchDefaults.open(suite))
}

/// The same for an async test on the main actor.
@MainActor
@discardableResult
func withScratchDefaults<T>(_ label: String = #function,
                            _ body: @MainActor (UserDefaults) async throws -> T) async rethrows -> T {
    let directory = try! TestTemporaryDirectory()
    let suite = ScratchDefaults.suiteName(label, directory: directory.url)
    defer {
        ScratchDefaults.remove(suite, directory: directory.url)
        try? directory.remove()
    }
    return try await body(ScratchDefaults.open(suite))
}

enum ScratchDefaults {
    static let prefix = "jrbar.tests."

    /// "<test scope>/jrbar.tests.draftsSurviveRelaunch.<uuid>":
    /// the label's letters and digits, so a `#function` name makes a legal
    /// domain. The path is the suite name; the plist is that path plus
    /// ".plist".
    static func suiteName(_ label: String, directory: URL = TestTemporaryDirectory.currentURL) -> String {
        let word = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(48))
        return "\(directory.path)/\(prefix)\(word.isEmpty ? "scratch" : word).\(UUID().uuidString)"
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
    static func remove(_ suite: String, directory: URL = TestTemporaryDirectory.currentURL) {
        guard suite.hasPrefix(directory.path + "/\(prefix)"), !suite.contains("..") else { return }
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
