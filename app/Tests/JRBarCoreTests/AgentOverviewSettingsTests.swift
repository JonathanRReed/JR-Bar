import Foundation
import Testing
@testable import JRBarCore

/// `AgentOrganizerSettings` is the Agent Overview card's persisted half
/// (docs/UTILITIES.md): whether the card is on, "quiet while you watch",
/// and the per-provider alert rules. Tolerant `Codable` like the rest of
/// `UtilitiesState`, so a file from an older or newer build still loads.
@Suite("Agent Overview settings")
struct AgentOverviewSettingsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults: the card is on, quiet while you watch, no rules")
    func defaults() {
        let s = AgentOrganizerSettings()
        #expect(s.enabled == true)
        #expect(s.quietWhenPaneFrontmost == true)
        #expect(s.alertRules.isEmpty)
        #expect(UtilitiesState().agents == s)
    }

    @Test("encode then decode returns the same settings")
    func roundTrip() throws {
        var state = UtilitiesState()
        state.agents = AgentOrganizerSettings(enabled: false, quietWhenPaneFrontmost: false)
        state.agents.alertRules = ["codex": AgentAlertRule(asks: false, sounds: false)]
        #expect(try decode(UtilitiesState.self, encode(state)) == state)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(AgentOrganizerSettings.self, "{}") == AgentOrganizerSettings())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"enabled": "sure", "quietWhenPaneFrontmost": 7, "alertRules": "loud", "futureKnob": 3}"#
        let s = try decode(AgentOrganizerSettings.self, json)
        #expect(s.enabled == true, "a string is not a flag")
        #expect(s.quietWhenPaneFrontmost == true, "a number is not a flag")
        #expect(s.alertRules.isEmpty, "rules that are not a table are no rules")
    }

    @Test("the keys of the old list organizer are ignored on read and gone on the next save")
    func oldOrganizerKeysAreDropped() throws {
        let json = #"""
        {"enabled": false, "quietWhenPaneFrontmost": false, "grouping": "provider",
         "showRemote": false, "showEnded": false, "showIdle": true, "showElapsed": false, "rowLimit": 15,
         "alertRules": {"grok": {"asks": false}}}
        """#
        let s = try decode(AgentOrganizerSettings.self, json)
        #expect(s.enabled == false)
        #expect(s.quietWhenPaneFrontmost == false)
        #expect(s.alertRules["grok"]?.asks == false)

        let saved = try encode(s)
        for key in ["grouping", "showRemote", "showEnded", "showIdle", "showElapsed", "rowLimit"] {
            #expect(!saved.contains("\"\(key)\""), "\(key) must not be written back")
        }
        #expect(try decode(AgentOrganizerSettings.self, saved) == s)
    }

    @Test("a file without `agents` reads as the defaults")
    func stateWithoutAgents() throws {
        let state = try decode(UtilitiesState.self, #"{"menuBar": {"enabled": true}}"#)
        #expect(state.agents == AgentOrganizerSettings())
        #expect(state.menuBar.enabled == true)
    }
}
