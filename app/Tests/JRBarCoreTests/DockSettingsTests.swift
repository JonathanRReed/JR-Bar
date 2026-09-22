import Foundation
import Testing
@testable import JRBarCore

/// `DockSettings` is the Dock utility's half of `app-state.json`
/// (docs/TOY-PARITY.md "Dock — Enhance"): it must round-trip cleanly
/// and read tolerantly the way `ToysState` does — a missing or
/// mistyped key falls back to its default, and the Replace era's keys
/// are ignored rather than carried.
@Suite("Dock settings")
struct DockSettingsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults: off, quarter-second hover, thumbnails on, small cards, every window")
    func defaults() {
        let s = DockSettings()
        #expect(s.enabled == false)
        #expect(s.enhance.previewDelay == 0.25)
        #expect(s.enhance.showThumbnails == true)
        #expect(s.enhance.largePreviews == false)
        #expect(s.enhance.includeOffscreenWindows == true)
    }

    @Test("encode then decode returns the same settings")
    func roundTrip() throws {
        var s = DockSettings()
        s.enabled = true
        s.enhance = DockEnhanceSettings(previewDelay: 0.6, showThumbnails: false,
                                        largePreviews: true, includeOffscreenWindows: false)
        #expect(try decode(DockSettings.self, encode(s)) == s)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(DockSettings.self, "{}") == DockSettings())
    }

    @Test("missing and mistyped keys fall back, unknown and Replace-era keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"enabled": true, "mode": "replace", "edge": "left", "pinned": ["a.b"], "magnification": {"enabled": true}, "enhance": {"previewDelay": "slow", "showThumbnails": "no", "largePreviews": 1}, "futureDockKey": {"x": 1}}"#
        let s = try decode(DockSettings.self, json)
        #expect(s.enabled == true)
        #expect(s.enhance.previewDelay == DockEnhanceSettings.defaultDelay, "a string is not a delay")
        #expect(s.enhance.showThumbnails == true)
        #expect(s.enhance.largePreviews == false)
    }

    @Test("the hover delay is clamped to the card's range")
    func clamps() throws {
        let s = try decode(DockSettings.self, #"{"enhance": {"previewDelay": 99}}"#)
        #expect(s.enhance.previewDelay == DockEnhanceSettings.delayRange.upperBound)
        #expect(DockEnhanceSettings(previewDelay: -1).previewDelay == DockEnhanceSettings.delayRange.lowerBound)
        #expect(DockEnhanceSettings(previewDelay: .nan).previewDelay == DockEnhanceSettings.defaultDelay)
    }

    @Test("the switcher pick and hover previews decode tolerantly and default to JR-Bar, on")
    func switcherKeys() throws {
        let s = try decode(DockSettings.self, #"{"switcherProvider": "altTab", "enhance": {"hoverPreviews": false}}"#)
        #expect(s.switcherProvider == .altTab)
        #expect(s.enhance.hoverPreviews == false)
        let junk = try decode(DockSettings.self, #"{"switcherProvider": "nope", "enhance": {"hoverPreviews": "x"}}"#)
        #expect(junk.switcherProvider == .jrbar)
        #expect(junk.enhance.hoverPreviews == true)
        var round = DockSettings()
        round.switcherProvider = .contexts
        round.enhance.hoverPreviews = false
        #expect(try decode(DockSettings.self, encode(round)) == round)
    }

    @Test("handing the previews to DockDoor keeps JR-Bar's switcher; the card off stops both")
    func halvesAreIndependent() {
        var s = DockSettings(enabled: true, provider: .dockDoor)
        #expect(!s.previewsWanted)
        #expect(s.switcherWanted, "⌥⇥ no longer parks with the previews")
        s.provider = .jrbar
        s.enhance.hoverPreviews = false
        #expect(!s.previewsWanted && s.switcherWanted)
        s.switcherProvider = .altTab
        #expect(!s.switcherWanted, "a switcher counterpart parks our chords")
        s.switcherProvider = .jrbar
        s.enhance.windowSwitcher = false
        #expect(!s.switcherWanted, "both chords off is no switcher")
        s.enhance.appSwitcher = true
        #expect(s.switcherWanted)
        s.enabled = false
        #expect(!s.previewsWanted && !s.switcherWanted)
    }
}
