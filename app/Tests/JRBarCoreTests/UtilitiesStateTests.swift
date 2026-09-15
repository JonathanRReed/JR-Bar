import Foundation
import Testing
@testable import JRBarCore

/// `UtilitiesState` is the Utilities page's half of `app-state.json`
/// (docs/UTILITIES.md): it must round-trip cleanly and read tolerantly,
/// the way `ToysState` does — a missing or mistyped key falls back to
/// its default and a newer build's keys are ignored.
@Suite("Utilities state")
struct UtilitiesStateTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults: the page on, the Menu Bar utility off and quiet")
    func defaults() {
        let state = UtilitiesState()
        #expect(state.enabled == true)
        #expect(state.menuBar == MenuBarSettings())
        #expect(state.menuBar.enabled == false)
        #expect(state.menuBar.sections.isEmpty)
        #expect(state.menuBar.revealOnHover == true)
        #expect(state.menuBar.revealOnClick == true)
        #expect(state.menuBar.revealOnScroll == true)
        #expect(state.menuBar.rehideSeconds == MenuBarSettings.defaultRehideSeconds)
        #expect(state.menuBar.spacerLength == MenuBarSettings.defaultSpacerLength)
    }

    @Test("encode then decode returns the same state")
    func roundTrip() throws {
        var state = UtilitiesState()
        state.menuBar = MenuBarSettings(enabled: true,
                                      sections: ["1Password": .hidden, "Ice": .alwaysHidden],
                                      revealOnHover: false, revealOnClick: true, revealOnScroll: false,
                                      rehideSeconds: 8, spacerLength: 12_000)
        let decoded = try decode(UtilitiesState.self, encode(state))
        #expect(decoded == state)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(UtilitiesState.self, "{}") == UtilitiesState())
        #expect(try decode(MenuBarSettings.self, "{}") == MenuBarSettings())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"enabled": "sure", "menuBar": {"enabled": true, "revealOnHover": "yes", "rehideSeconds": "later", "futureKnob": 3}, "futureUtility": {"enabled": true}}"#
        let state = try decode(UtilitiesState.self, json)
        #expect(state.enabled == true, "a string is not a flag — the page stays on")
        #expect(state.menuBar.enabled == true)
        #expect(state.menuBar.revealOnHover == true, "a string is not a flag")
        #expect(state.menuBar.rehideSeconds == MenuBarSettings.defaultRehideSeconds)
    }

    @Test("an unknown section value is dropped, the known ones keep their item")
    func tolerantSections() throws {
        let json = #"{"sections": {"One": "hidden", "Two": "alwaysHidden", "Three": "vaulted", "Four": "shown"}}"#
        let settings = try decode(MenuBarSettings.self, json)
        #expect(settings.sections == ["One": .hidden, "Two": .alwaysHidden, "Four": .shown])
        #expect(settings.section(for: "Three") == .shown, "a newer build's section reads as shown")
        #expect(settings.section(for: "NeverListed") == .shown)
    }

    @Test("a mistyped sections blob is an empty map, not a failed decode")
    func garbageSections() throws {
        let settings = try decode(MenuBarSettings.self, #"{"sections": "many"}"#)
        #expect(settings.sections.isEmpty)
    }

    @Test("rehide seconds clamp to the dial's range; nonsense falls back")
    func rehideClamp() throws {
        #expect(try decode(MenuBarSettings.self, #"{"rehideSeconds": 0.2}"#).rehideSeconds == 1)
        #expect(try decode(MenuBarSettings.self, #"{"rehideSeconds": 999}"#).rehideSeconds == 15)
        #expect(try decode(MenuBarSettings.self, #"{"rehideSeconds": 4.5}"#).rehideSeconds == 4.5)
        // The init clamps the same way the decode does.
        #expect(MenuBarSettings(rehideSeconds: -5).rehideSeconds == 1)
        #expect(MenuBarSettings(rehideSeconds: .nan).rehideSeconds == MenuBarSettings.defaultRehideSeconds)
        #expect(MenuBarSettings(rehideSeconds: .infinity).rehideSeconds == MenuBarSettings.defaultRehideSeconds)
    }

    @Test("a spacer too small to push anything off is not a spacer")
    func spacerClamp() throws {
        #expect(try decode(MenuBarSettings.self, #"{"spacerLength": 40}"#).spacerLength
                == MenuBarSettings.defaultSpacerLength)
        #expect(try decode(MenuBarSettings.self, #"{"spacerLength": 8000}"#).spacerLength == 8000)
        #expect(MenuBarSettings(spacerLength: 0).spacerLength == MenuBarSettings.defaultSpacerLength)
        #expect(MenuBarSettings(spacerLength: .nan).spacerLength == MenuBarSettings.defaultSpacerLength)
    }

    @Test("AppState carries utilities and round-trips them through the file")
    func appStateRoundTrip() throws {
        var app = AppState(showScreenBar: false)
        app.utilities.menuBar.enabled = true
        app.utilities.menuBar.sections = ["Bartender": .alwaysHidden]
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(AppState.self, from: data) == app)
    }

    @Test("an AppState file without `utilities` reads as the defaults")
    func appStateWithoutUtilities() throws {
        let app = try decode(AppState.self, #"{"showScreenBar": false, "toys": {"confetti": {"enabled": true}}}"#)
        #expect(app.utilities == UtilitiesState())
        #expect(app.toys.confetti.enabled == true)
    }

    @Test("a mistyped `utilities` blob cannot sink the rest of AppState")
    func appStateGarbageUtilities() throws {
        let app = try decode(AppState.self, #"{"showScreenBar": true, "utilities": "serious"}"#)
        #expect(app.utilities == UtilitiesState())
        #expect(app.showScreenBar == true)
    }
}
