import Foundation

/// A throwaway `UserDefaults` suite for one test. `body` gets a fresh
/// suite named `jrbar.tests.<label>.<uuid>`; on the way out the domain is
/// removed and the plist cfprefsd wrote under ~/Library/Preferences is
/// deleted, so a run of the suite leaves no `jrbar.tests.*` files behind.
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

    /// "jrbar.tests.draftsSurviveRelaunch.<uuid>": the label's letters
    /// and digits, so a `#function` name makes a legal domain.
    static func suiteName(_ label: String) -> String {
        let word = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(48))
        return "\(prefix)\(word.isEmpty ? "scratch" : word).\(UUID().uuidString)"
    }

    static func open(_ suite: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("no defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Removes the suite's domain and its plist. Only a scratch suite:
    /// anything else is left alone.
    static func remove(_ suite: String) {
        guard suite.hasPrefix(prefix), !suite.contains("/") else { return }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: plist(suite))
    }

    /// Where cfprefsd keeps a suite's plist.
    static func plist(_ suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(suite).plist")
    }
}
