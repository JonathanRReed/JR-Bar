import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Agents page's "Sub-agent asks" switch: its words match what the
/// daemon does with a worker's ask, and it still writes the one key the
/// daemon reads.
@Suite struct SubagentAsksSettingTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
    }

    private func pageSource() throws -> String {
        try String(contentsOf: appSources.appending(path: "SettingsPagesA.swift"), encoding: .utf8)
    }

    @Test func thePageStillBindsTheDaemonsKey() throws {
        let key = SettingsKey.all.first { $0.path == "subagent_asks_alert" }
        #expect(key?.page == .agents)
        #expect(key?.kind == .bool)
        let source = try pageSource()
        #expect(source.contains("path: \"subagent_asks_alert\""))
    }

    @Test func theSubtitleSaysWhatQuietMeans() {
        let words = SubagentAsksCopy.subtitle
        #expect(words.contains("stay quiet by default"))
        for surface in ["light", "sound", "banner", "answer card"] {
            #expect(words.contains(surface), "the subtitle names \(surface)")
        }
        #expect(words.contains("still shows its own prompt"))
        #expect(words.contains("alert like a main session's"))
        // The old words claimed a worker cannot be answered, which the
        // decide lane made untrue.
        #expect(!words.contains("cannot be answered"))
    }

    @Test func thePageAndTheSearchIndexShareThoseWords() throws {
        let source = try pageSource()
        #expect(source.contains("subtitle: SubagentAsksCopy.subtitle"))
        #expect(!source.contains("Sub-agents cannot be answered"))
        let row = SettingsSearch.rows.first { $0.title == "Sub-agent asks" }
        #expect(row?.subtitle == SubagentAsksCopy.subtitle)
        #expect(row?.page == .agents)
    }
}
