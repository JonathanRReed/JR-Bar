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
        // And it can be written over.
        try file.save(AppState(loginItemRegistered: true))
        #expect(file.load().loginItemRegistered)
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
}
