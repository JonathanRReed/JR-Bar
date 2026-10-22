import Foundation
import Testing
@testable import JRBarCore

/// The app's remembered facts in `app-state.json`: defaults when the file
/// is missing, tolerant reads, atomic writes and the state-directory rule.
@Suite("App state file")
struct AppStateTests {
    private func temporaryFile() -> AppStateFile {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-app-state-\(UUID().uuidString.prefix(8))")
        return AppStateFile(url: directory.appending(path: "app-state.json"))
    }

    @Test("a missing file reads as the defaults: no hooks stamp, no login item, Screen Bar shown")
    func missingFile() {
        let file = temporaryFile()
        #expect(!file.exists)
        let state = file.load()
        #expect(state == AppState())
        #expect(state.bundledHooksInstalledFor == nil)
        #expect(state.loginItemRegistered == false)
        #expect(state.showScreenBar == true)
    }

    @Test("save creates the directory and load reads the same state back")
    func roundTrip() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let state = AppState(bundledHooksInstalledFor: "0.8.0+2026-09-10", loginItemRegistered: true, showScreenBar: false)
        try file.save(state)
        #expect(file.exists)
        #expect(file.load() == state)
        // A second process (or the shell) sees plain JSON with the documented keys.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
        #expect(object?["bundledHooksInstalledFor"] as? String == "0.8.0+2026-09-10")
        #expect(object?["loginItemRegistered"] as? Bool == true)
        #expect(object?["showScreenBar"] as? Bool == false)
    }

    @Test("the menu bar icon style is remembered here, since the daemon drops it")
    func menuBarIconStyle() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(file.load().menuBarIconStyle == nil, "unset means the app's default")
        try file.save(AppState(menuBarIconStyle: "glyph_ring"))
        #expect(file.load().menuBarIconStyle == "glyph_ring")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
        #expect(object?["menuBarIconStyle"] as? String == "glyph_ring")
        // A file written by a build that did not know the key still reads.
        try Data(#"{"showScreenBar": false}"#.utf8).write(to: file.url)
        #expect(file.load().menuBarIconStyle == nil)
        #expect(file.load().showScreenBar == false)
    }

    @Test("provider choices persist and preserve account and session order")
    func menuBarProviderChoices() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let choices = MenuBarProviderPreferences(order: ["codex", "codex", "claude"], hidden: ["factory"])
        try file.save(AppState(menuBarProviders: choices))
        let restored = file.load().menuBarProviders
        let rows = [("claude", "a"), ("codex", "one"), ("factory", "hidden"), ("codex", "two"), ("new", "last")]
        #expect(restored.arranged(rows, provider: { $0.0 }).map { $0.1 } == ["one", "two", "a", "last"])
        #expect(MenuBarProviderPreferences(hidden: ["codex"]).arranged(["codex"], provider: { $0 }).isEmpty)
        #expect(try JSONDecoder().decode(AppState.self, from: Data("{}".utf8)).menuBarProviders == .init())
        let malformed = Data(#"{"menuBarProviders":{"order":1}}"#.utf8)
        #expect(try JSONDecoder().decode(AppState.self, from: malformed).menuBarProviders == .init())
    }

    @Test("saving again replaces the file and leaves no temporary files behind")
    func atomicReplace() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.save(AppState(showScreenBar: false))
        try file.save(AppState(bundledHooksInstalledFor: "stamp", showScreenBar: true))
        #expect(file.load() == AppState(bundledHooksInstalledFor: "stamp", showScreenBar: true))
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["app-state.json"], "only the state file: \(entries)")
    }

    @Test("a partial or wrongly typed document keeps the defaults for what it lacks")
    func partialDocument() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"showScreenBar": false, "loginItemRegistered": "yes", "someFutureKey": [1, 2]}"#.utf8).write(to: file.url)
        let state = file.load()
        #expect(state.showScreenBar == false)
        #expect(state.loginItemRegistered == false, "a string is not a flag")
        #expect(state.bundledHooksInstalledFor == nil)
    }

    @Test("a corrupt file reads as the defaults instead of failing the launch")
    func corruptFile() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file.url)
        #expect(file.exists)
        #expect(file.load() == AppState())
        // Recovery may write defaults, but must retain the damaged file.
        try file.save(AppState(loginItemRegistered: true))
        #expect(file.load().loginItemRegistered)
        let backups = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("app-state.recovery-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: backup) == Data("{not json".utf8))
        }
        try file.save(AppState(loginItemRegistered: true, showScreenBar: false))
        let after = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("app-state.recovery-") }
        #expect(after.count == 1, "healthy saves must not keep creating recovery files")
    }

    @Test(arguments: [
        #"{"toys":"damaged"}"#,
        #"{"utilities":{"menuBar":{"enabled":"damaged"}}}"#,
        #"{"future_setting":{"important":"value"}}"#,
    ])
    func tolerantReadsPreserveDataTheyCannotRoundTrip(_ json: String) throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(json.utf8)
        try original.write(to: file.url)
        try file.save(file.load())
        let backups = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("app-state.recovery-") }
        #expect(backups.count == 1)
        if let backup = backups.first { #expect(try Data(contentsOf: backup) == original) }
    }

    @Test("the default path follows the daemon's state directory")
    func defaultPath() {
        #expect(AppStateFile.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/state"]).path == "/tmp/state/jrbar/app-state.json")
        #expect(AppStateFile.defaultURL(environment: ["XDG_STATE_HOME": ""]).path.hasSuffix("/.local/state/jrbar/app-state.json"))
        #expect(AppStateFile.defaultURL(environment: [:]).path.hasSuffix("/.local/state/jrbar/app-state.json"))
        #expect(AppStateFile.defaultURL(environment: [:]).deletingLastPathComponent().path
                == CoreSocketPath.resolve(environment: [:]).replacingOccurrences(of: "/core.sock", with: ""),
                "the same directory as core.sock")
    }

    @Test("a set of providers saved in another order is not a damaged file")
    func setOrderDoesNotMakeARecoveryCopy() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = AppState()
        state.toys.confetti.triggers.perProviderReset = ["claude", "codex", "gemini", "grok"]
        try file.save(state)
        // The file as an earlier launch, hashing the set in another
        // order, would have written it: both directions, so one of them
        // differs from this process's own order whatever that is.
        for reversed in [false, true] {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
            var toys = try #require(object["toys"] as? [String: Any])
            var confetti = try #require(toys["confetti"] as? [String: Any])
            var triggers = try #require(confetti["triggers"] as? [String: Any])
            let words = try #require(triggers["perProviderReset"] as? [String]).sorted()
            triggers["perProviderReset"] = reversed ? Array(words.reversed()) : words
            confetti["triggers"] = triggers
            toys["confetti"] = confetti
            object["toys"] = toys
            try JSONSerialization.data(withJSONObject: object).write(to: file.url)
            try file.save(state)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("app-state.recovery-") }
        #expect(backups.isEmpty, "the same providers in another order lose nothing")
    }

    private func recoveryCopies(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("app-state.recovery-") }
    }

    @Test("a key this app has retired is not damage, so a plain upgrade cuts no recovery copy")
    func retiredKeysCutNoRecoveryCopy() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.save(AppState())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        var utilities = try #require(object["utilities"] as? [String: Any])
        var menuBar = try #require(utilities["menuBar"] as? [String: Any])
        menuBar["agentStatusItem"] = true
        menuBar["spacers"] = ["old"]
        utilities["menuBar"] = menuBar
        // The Data Hoarder's switch and capture dials, cut with the utility.
        utilities["dataHoarderEnabled"] = true
        utilities["dataHoarder"] = ["captureSources": ["claude-projects": true], "fullContent": false]
        // The notch card's Weather row, cut the same way.
        var toys = try #require(object["toys"] as? [String: Any])
        var notch = try #require(toys["notch"] as? [String: Any])
        notch["weather"] = true
        notch["weatherCity"] = "London"
        notch["weatherUseIPLocation"] = false
        toys["notch"] = notch
        object["toys"] = toys
        object["utilities"] = utilities
        try JSONSerialization.data(withJSONObject: object).write(to: file.url)

        try file.save(AppState())
        #expect(try recoveryCopies(in: directory).isEmpty, "retired keys are gone on purpose")
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        let menuAfter = try #require((after["utilities"] as? [String: Any])?["menuBar"] as? [String: Any])
        #expect(menuAfter["agentStatusItem"] == nil)
        let utilitiesAfter = try #require(after["utilities"] as? [String: Any])
        #expect(utilitiesAfter["dataHoarderEnabled"] == nil)
        #expect(utilitiesAfter["dataHoarder"] == nil)
        let notchAfter = try #require((after["toys"] as? [String: Any])?["notch"] as? [String: Any])
        #expect(notchAfter["weather"] == nil)
        #expect(notchAfter["weatherCity"] == nil)
    }

    @Test("a key nobody has retired is still kept as a recovery copy when it is dropped")
    func unknownKeysStillCutOne() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.save(AppState())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        object["aNewerAppsKey"] = ["keep": "me"]
        try JSONSerialization.data(withJSONObject: object).write(to: file.url)

        try file.save(AppState())
        #expect(try recoveryCopies(in: directory).count == 1)
    }

    @Test("no retired path is one this app still writes")
    func retiredPathsAreNotLive() throws {
        let data = try JSONEncoder().encode(AppState())
        let live = try JSONDecoder().decode(JSONValue.self, from: data)
        func paths(_ value: JSONValue, _ prefix: String) -> Set<String> {
            guard case .object(let members) = value else { return [] }
            var found: Set<String> = []
            for (key, inner) in members {
                let here = prefix.isEmpty ? key : prefix + "." + key
                found.insert(here)
                found.formUnion(paths(inner, here))
            }
            return found
        }
        #expect(paths(live, "").isDisjoint(with: AppStateFile.retiredKeyPaths))
    }

    @Test("an unreadable file loads as the defaults and says so; a missing or good one does not")
    func loadOutcomes() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(file.loadChecked().outcome == .missing)

        try file.save(AppState(showScreenBar: false))
        #expect(file.loadChecked().outcome == .loaded)
        #expect(file.loadChecked().state.showScreenBar == false)

        try Data("{ this is not json".utf8).write(to: file.url)
        let broken = file.loadChecked()
        #expect(broken.state == AppState())
        guard case .unreadable = broken.outcome else {
            Issue.record("expected unreadable, got \(broken.outcome)")
            return
        }

        // The next save keeps the broken bytes before replacing them.
        try file.save(AppState())
        #expect(try recoveryCopies(in: directory).count == 1)
        #expect(file.loadChecked().outcome == .loaded, "after that the file reads fine, so the notice is not repeated")
    }
}
