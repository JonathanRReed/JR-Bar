import Foundation
import Testing
@testable import JRBarCore

/// `ToysState` is the Toys page's half of `app-state.json` (docs/TOYS.md):
/// it must round-trip cleanly and read tolerantly, the way `AppState`
/// does — a missing or mistyped key falls back to its default and a
/// newer build's keys are ignored.
@Suite("Toys state")
struct ToysStateTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults are all off: every toy starts quiet")
    func defaults() {
        let state = ToysState()
        #expect(state.fold == FoldSettings())
        #expect(state.fold.enabled == false)
        #expect(state.fold.activationAngle == 65)
        #expect(state.fold.style == .fog)
        #expect(state.fold.provider == .jrbar)
        #expect(state.aquarium == AquariumSettings())
        #expect(state.notchBuddy == NotchBuddySettings())
        #expect(state.confetti == ConfettiSettings())
        #expect(state.externalApps.isEmpty)
    }

    @Test("encode then decode returns the same state")
    func roundTrip() throws {
        var state = ToysState()
        state.fold = FoldSettings(enabled: true, activationAngle: 95, style: .fog, perspective: 0.8,
                                  blur: 0.2, shade: 0.7, jitterTolerance: 2, provider: .bendy)
        state.aquarium = AquariumSettings(enabled: true, showLabels: false, density: 0.4)
        state.notchBuddy = NotchBuddySettings(enabled: true, character: "dot")
        state.confetti = ConfettiSettings(enabled: true)
        state.externalApps = [ExternalToyApp(id: "com.example.Fish", name: "Fish", launchWithJRBar: true)]
        let decoded = try decode(ToysState.self, encode(state))
        #expect(decoded == state)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(ToysState.self, "{}") == ToysState())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"fold": {"enabled": true, "activationAngle": "soon", "style": "glow", "provider": "someone"}, "confetti": {"enabled": "yes"}, "externalApps": "many", "futureToy": {"enabled": true}}"#
        let state = try decode(ToysState.self, json)
        #expect(state.fold.enabled == true)
        #expect(state.fold.activationAngle == 65, "a string is not an angle")
        #expect(state.fold.style == .fog, "an unknown style is fog")
        #expect(state.fold.provider == .jrbar, "an unknown renderer is jrbar")
        #expect(state.confetti.enabled == false, "a string is not a flag")
        #expect(state.externalApps.isEmpty)
        #expect(state.aquarium == AquariumSettings())
    }

    @Test("a partially wrong external app keeps the fields that parse")
    func tolerantExternalApp() throws {
        let json = #"{"externalApps": [{"id": "com.example.A", "name": "A", "launchWithJRBar": true}, {"name": "NoID"}, {"id": "com.example.B"}]}"#
        let state = try decode(ToysState.self, json)
        // The row with no bundle id is dropped: it can never be launched.
        #expect(state.externalApps == [
            ExternalToyApp(id: "com.example.A", name: "A", launchWithJRBar: true),
            ExternalToyApp(id: "com.example.B", name: ""),
        ])
    }

    @Test("a file still on the old defaults migrates to the new ones")
    func oldDefaultsMigrate() throws {
        // Each past default set is treated as untouched: pre-0.9.6's
        // 110°/Tilt and 0.9.6's 82°/Dusk both land on the current
        // 65°/Fog. Real persisted files encode every key, so the check
        // sees the old shade too. Deliberate changes survive either way.
        let stale = try decode(FoldSettings.self,
                               #"{"activationAngle": 110, "style": "tilt", "shade": 0.4}"#)
        #expect(stale.activationAngle == 65)
        #expect(stale.style == .fog)
        #expect(stale.shade == 0.7)
        let mid = try decode(FoldSettings.self, #"{"activationAngle": 82, "style": "dusk", "shade": 0.4}"#)
        #expect(mid.activationAngle == 65)
        #expect(mid.style == .fog)
        // But a deliberate 110° survives: any other field moved means the
        // user touched it, and Tilt on its own is a real choice too.
        let chosen = try decode(FoldSettings.self,
                                #"{"activationAngle": 110, "style": "tilt", "blur": 0.9}"#)
        #expect(chosen.activationAngle == 110)
        let tiltOnly = try decode(FoldSettings.self, #"{"activationAngle": 82, "style": "tilt"}"#)
        #expect(tiltOnly.style == .tilt)
        // A deliberate 82° with a moved field survives the migration too.
        let kept = try decode(FoldSettings.self, #"{"activationAngle": 82, "style": "dusk", "shade": 0.9}"#)
        #expect(kept.activationAngle == 82)
        #expect(kept.shade == 0.9)
    }

    @Test("the earlier confetti fields decode as their replacement: off")
    func droppedConfettiFields() throws {
        // `onCompletion`/`onMilestone` left the contract; the keys an old
        // build wrote are now just unknown keys.
        let state = try decode(ToysState.self, #"{"confetti": {"enabled": true, "onCompletion": false, "onMilestone": false}}"#)
        #expect(state.confetti == ConfettiSettings(enabled: true))
    }

    @Test("AppState carries toys and round-trips them through the file")
    func appStateRoundTrip() throws {
        var app = AppState(showScreenBar: false)
        app.toys.notchBuddy.enabled = true
        app.toys.externalApps = [ExternalToyApp(id: "com.example.Bear", name: "Bear")]
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(AppState.self, from: data) == app)
    }

    @Test("an AppState file without `toys` reads as the defaults")
    func appStateWithoutToys() throws {
        let app = try decode(AppState.self, #"{"showScreenBar": false, "menuBarIconStyle": "glyph_ring"}"#)
        #expect(app.toys == ToysState())
        #expect(app.showScreenBar == false)
        #expect(app.menuBarIconStyle == "glyph_ring")
    }

    @Test("a mistyped `toys` blob cannot sink the rest of AppState")
    func appStateGarbageToys() throws {
        let app = try decode(AppState.self, #"{"showScreenBar": true, "toys": "fun"}"#)
        #expect(app.toys == ToysState())
        #expect(app.showScreenBar == true)
    }
}
