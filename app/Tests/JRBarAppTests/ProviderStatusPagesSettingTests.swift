import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Usage page's "Provider status pages" switch: it is the one key the
/// daemon reads before it contacts a status page, its words name every host
/// that switch lets JR-Bar contact, and it is off until the person turns it on.
@Suite struct ProviderStatusPagesSettingTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
    }

    private func pageSource() throws -> String {
        try String(contentsOf: appSources.appending(path: "SettingsPagesA.swift"), encoding: .utf8)
    }

    @Test func theKeyIsAUsageSwitchTheDaemonServes() {
        let key = SettingsKey.all.first { $0.path == "provider_status_feeds_enabled" }
        #expect(key?.page == .usage)
        #expect(key?.kind == .bool)
        // A page reset writes the daemon's default back, which is off.
        let document = SettingsDocument(.object(["provider_status_feeds_enabled": .bool(true)]))
        let paths = SettingsKey.resetPaths(on: .usage, in: document)
        #expect(paths.contains("provider_status_feeds_enabled"))
    }

    @Test func thePageBindsThatKeyAndDoesNotDefaultItOn() throws {
        let source = try pageSource()
        #expect(source.contains("path: \"provider_status_feeds_enabled\""))
        // `SettingToggle` falls back to off when the document lacks the key.
        #expect(!source.contains("path: \"provider_status_feeds_enabled\", default: true"))
    }

    @Test func theWordsNameEveryHostAndSayItIsOffUntilTurnedOn() {
        let words = ProviderStatusPagesCopy.subtitle
        for host in ["status.anthropic.com", "status.openai.com", "status.cursor.com"] {
            #expect(words.contains(host), "the subtitle names \(host)")
        }
        #expect(words.contains("every 10 minutes"))
        #expect(words.contains("Off by default"))
        #expect(words.contains("nothing is contacted until you turn it on"))
    }

    @Test func thePageAndTheSearchIndexShareThoseWords() throws {
        let source = try pageSource()
        #expect(source.contains("subtitle: ProviderStatusPagesCopy.subtitle"))
        let row = SettingsSearch.rows.first { $0.title == "Provider status pages" }
        #expect(row?.subtitle == ProviderStatusPagesCopy.subtitle)
        #expect(row?.page == .usage)
    }
}
