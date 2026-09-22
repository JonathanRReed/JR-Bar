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
        #expect(state.fold.anchor == .angle)
        #expect(state.fold.activationAngle == 65)
        #expect(state.fold.provider == .jrbar)
        #expect(state.fold.holdPicture == true)
        #expect(state.aquarium == AquariumSettings())
        #expect(state.notchBuddy == NotchBuddySettings())
        #expect(state.confetti == ConfettiSettings())
    }

    @Test("encode then decode returns the same state")
    func roundTrip() throws {
        var state = ToysState()
        state.fold = FoldSettings(enabled: true, anchor: .movement, activationAngle: 95,
                                  perspective: 0.8, blur: 0.2, shade: 0.7, jitterTolerance: 2,
                                  provider: .bendy, holdPicture: false)
        state.aquarium = AquariumSettings(enabled: true, showLabels: false, density: 0.4)
        state.notchBuddy = NotchBuddySettings(enabled: true, character: "dot")
        state.confetti = ConfettiSettings(enabled: true)
        let decoded = try decode(ToysState.self, encode(state))
        #expect(decoded == state)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(ToysState.self, "{}") == ToysState())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"fold": {"enabled": true, "anchor": "someday", "activationAngle": "soon", "style": "glow", "provider": "someone", "holdPicture": "sure"}, "confetti": {"enabled": "yes"}, "externalApps": "many", "futureToy": {"enabled": true}}"#
        let state = try decode(ToysState.self, json)
        #expect(state.fold.enabled == true)
        #expect(state.fold.anchor == .angle, "an unknown anchor reads as a set angle")
        #expect(state.fold.activationAngle == 65, "a string is not an angle")
        #expect(state.fold.provider == .jrbar, "an unknown renderer is jrbar")
        #expect(state.fold.holdPicture == true, "a string is not a flag")
        #expect(state.confetti.enabled == false, "a string is not a flag")
        #expect(state.aquarium == AquariumSettings())
    }

    @Test("a file still on the old defaults migrates to the new ones")
    func oldDefaultsMigrate() throws {
        // Each past default set is treated as untouched: pre-0.9.6's
        // 110°/Tilt and 0.9.6's 82°/Dusk both land on the current
        // 65°/0.7-shade portal. Real persisted files encode every key,
        // so the check sees the old shade too. Deliberate changes
        // survive either way, and the retired style key itself is
        // simply ignored.
        let stale = try decode(FoldSettings.self,
                               #"{"activationAngle": 110, "style": "tilt", "shade": 0.4}"#)
        #expect(stale.activationAngle == 65)
        #expect(stale.shade == 0.7)
        let mid = try decode(FoldSettings.self, #"{"activationAngle": 82, "style": "dusk", "shade": 0.4}"#)
        #expect(mid.activationAngle == 65)
        #expect(mid.shade == 0.7)
        // But a deliberate 110° survives: any other field moved means the
        // user touched it.
        let chosen = try decode(FoldSettings.self,
                                #"{"activationAngle": 110, "style": "tilt", "blur": 0.9}"#)
        #expect(chosen.activationAngle == 110)
        // A stale "fog" from the portal-rewrite era decodes without a
        // murmur — the key is read only for the legacy-default check.
        let fogged = try decode(FoldSettings.self, #"{"style": "fog"}"#)
        #expect(fogged == FoldSettings())
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

    @Test("the aquarium's day/night mode defaults to the clock and round-trips")
    func aquariumDayNightRoundTrip() throws {
        #expect(AquariumSettings().dayNight == .realTime)
        var settings = AquariumSettings(enabled: true)
        settings.dayNight = .cycle
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AquariumSettings.self, from: data)
        #expect(decoded.dayNight == .cycle)
    }

    @Test("an aquarium blob without `dayNight` — or with a bad one — reads as the clock")
    func aquariumDayNightTolerant() throws {
        // A settings file from before the picker existed.
        let old = try decode(AquariumSettings.self,
                             #"{"enabled": true, "showLabels": false, "density": 0.5}"#)
        #expect(old.dayNight == .realTime)
        #expect(old.showLabels == false)
        #expect(old.density == 0.5)
        // An unknown future value can't sink the mode, let alone the rest.
        let future = try decode(AquariumSettings.self,
                                #"{"dayNight": "sundial", "enabled": true}"#)
        #expect(future.dayNight == .realTime)
        #expect(future.enabled == true)
        // A mistyped key is no better.
        let mistyped = try decode(AquariumSettings.self,
                                  #"{"dayNight": 4}"#)
        #expect(mistyped.dayNight == .realTime)
    }
}
