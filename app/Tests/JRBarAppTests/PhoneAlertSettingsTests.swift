import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings › Alerts & Sounds › Phone alert: three keys the daemon serves, on the
/// Remote page, never defaulted on in the page, and one Test button that is
/// the only thing in the app that asks the daemon to send.
@Suite struct PhoneAlertSettingsTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appending(path: name), encoding: .utf8)
    }

    @Test func theKeysAreRemoteSettingsTheDaemonServes() {
        let enabled = SettingsKey.all.first { $0.path == "ntfy_enabled" }
        let topic = SettingsKey.all.first { $0.path == "ntfy_topic" }
        let away = SettingsKey.all.first { $0.path == "ntfy_only_when_away" }
        #expect(enabled?.page == .remote && enabled?.kind == .bool)
        #expect(topic?.page == .remote && topic?.kind == .string)
        #expect(away?.page == .remote && away?.kind == .bool)
        // A page reset writes the daemon's defaults back: off, no topic.
        let document = SettingsDocument(.object(["ntfy_enabled": .bool(true), "ntfy_topic": .string("mine")]))
        let paths = SettingsKey.resetPaths(on: .remote, in: document)
        #expect(paths.contains("ntfy_enabled") && paths.contains("ntfy_topic"))
    }

    @Test func thePageNeverDefaultsTheSwitchOnAndTheSwitchWaitsForATopic() throws {
        let page = try source("SettingsPagesB.swift")
        #expect(page.contains("path: \"ntfy_enabled\""))
        #expect(!page.contains("path: \"ntfy_enabled\", default: true"))
        #expect(page.contains("path: \"ntfy_topic\""))
        // The only-when-away condition is on unless the person turns it off.
        #expect(page.contains("path: \"ntfy_only_when_away\", default: true"))
        #expect(page.contains("store.testPhoneAlert()"))
    }

    @Test func nothingButTheTestButtonAsksTheDaemonToSend() throws {
        var callers: [String] = []
        let enumerator = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("testPhoneAlert()") { callers.append(url.lastPathComponent) }
        }
        #expect(Set(callers) == ["SettingsStore.swift", "SettingsPagesB.swift"])
    }

    @Test func theSettingsSearchFindsIt() {
        let titles = SettingsSearch.rows.filter { $0.chapter == .notifications }.map(\.title)
        #expect(titles.contains("ntfy topic"))
        #expect(titles.contains("Send phone alerts"))
    }
}
