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
        #expect(state.fold.anchor == .movement)
        #expect(state.fold.look == .duo)
        #expect(state.fold.activationAngle == 65)
        #expect(state.fold.provider == .jrbar)
        #expect(state.fold.holdStrength == 1)
        #expect(state.aquarium == AquariumSettings())
        #expect(state.notchBuddy == NotchBuddySettings())
        #expect(state.confetti == ConfettiSettings())
    }

    @Test("encode then decode returns the same state")
    func roundTrip() throws {
        var state = ToysState()
        state.fold = FoldSettings(enabled: true, anchor: .movement, activationAngle: 95,
                                  perspective: 0.8, blur: 0.2, shade: 0.7, jitterTolerance: 2,
                                  provider: .bendy, holdStrength: 0.4)
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
        #expect(state.fold.anchor == .movement, "an unknown anchor reads as wherever the lid rests")
        #expect(state.fold.activationAngle == 65, "a string is not an angle")
        #expect(state.fold.provider == .jrbar, "an unknown renderer is jrbar")
        #expect(state.fold.holdStrength == 1, "a string is not a flag")
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

    // MARK: lane fold

    @Test("the old Hold switch migrates by what its label meant, and the strength clamps")
    func foldHoldMigration() throws {
        // `holdPicture: true` read as "hold" but drove the picture toward
        // the lid; the strength takes the label's meaning.
        #expect(try decode(FoldSettings.self, #"{"holdPicture": true}"#).holdStrength == 1)
        #expect(try decode(FoldSettings.self, #"{"holdPicture": false}"#).holdStrength == 0)
        #expect(try decode(FoldSettings.self, "{}").holdStrength == 1)
        // A stored strength wins over a stale switch and is kept in 0…1.
        #expect(try decode(FoldSettings.self, #"{"holdStrength": 0.8, "holdPicture": false}"#).holdStrength == 0.8)
        #expect(try decode(FoldSettings.self, #"{"holdStrength": 7}"#).holdStrength == 1)
        #expect(try decode(FoldSettings.self, #"{"holdStrength": -2}"#).holdStrength == 0)
        #expect(try decode(FoldSettings.self, #"{"holdStrength": "most"}"#).holdStrength == 1)
        // The encoder writes the strength and never the retired switch.
        let written = try encode(FoldSettings(holdStrength: 0.25))
        #expect(written.contains("\"holdStrength\":0.25"))
        #expect(!written.contains("holdPicture"))
    }

    @Test("a file from before the looks moves to Duo and the resting angle, keeping its own knobs")
    func foldLookMigration() throws {
        // Jonathan's live file, as it was written before the looks.
        let live = try decode(FoldSettings.self, #"""
            {"activationAngle": 69.92919921875, "anchor": "angle", "blur": 1, "dwellTimeout": 0,
             "enabled": true, "frost": 0.012841796875, "hingeVoice": "off", "holdPicture": true,
             "jitterTolerance": 1.5, "perspective": 0.454150390625, "provider": "jrbar",
             "restoreSound": false, "shade": 1, "wallpaperFallback": true}
            """#)
        #expect(live.look == .duo, "a missing look is Duo")
        #expect(live.holdStrength == 1, "the old switch on means a full hold")
        #expect(live.anchor == .movement, "every older file folds from where the lid rests")
        #expect(live.activationAngle == 69.92919921875, "the stored angle stays for Set angle")
        #expect(live.blur == 1 && live.shade == 1, "his maxed knobs are kept as stored")
        #expect(live.perspective == 0.454150390625)
        #expect(live.frost == 0.012841796875)
        #expect(live.fadeLength == 0.55)
        #expect(live.enabled)
        // A switch that was off rides the lid; the rest of the move holds.
        let off = try decode(FoldSettings.self, #"{"anchor": "angle", "holdPicture": false, "blur": 0.2}"#)
        #expect(off.holdStrength == 0)
        #expect(off.anchor == .movement)
        #expect(off.blur == 0.2)
        // Once a file has a look, its choices are its own: Room and a set
        // angle survive every later read.
        let chosen = try decode(FoldSettings.self, #"{"look": "room", "anchor": "angle", "activationAngle": 80}"#)
        #expect(chosen.look == .room)
        #expect(chosen.anchor == .angle)
        #expect(chosen.activationAngle == 80)
        // A mistyped look is still a look that was written: Duo, anchor kept.
        let garbled = try decode(FoldSettings.self, #"{"look": 4, "anchor": "angle"}"#)
        #expect(garbled.look == .duo)
        #expect(garbled.anchor == .angle)
        let unknown = try decode(FoldSettings.self, #"{"look": "origami", "anchor": "angle"}"#)
        #expect(unknown.look == .duo)
        #expect(unknown.anchor == .angle)
    }

    @Test("new fold keys round-trip, default for a new file, and the fade length clamps")
    func foldDuoKeys() throws {
        let fresh = FoldSettings()
        #expect(fresh.look == .duo)
        #expect(fresh.anchor == .movement)
        #expect(fresh.holdStrength == 1)
        #expect(fresh.fadeLength == 0.55)
        #expect(fresh.blur == 0.6)
        #expect(fresh.shade == 0.67)
        #expect(try decode(FoldSettings.self, "{}") == fresh, "an empty blob is a new file")
        var room = FoldSettings(enabled: true, anchor: .angle, activationAngle: 100,
                                holdStrength: 0.8, look: .room, fadeLength: 0.3)
        room.frost = 0.4
        let back = try decode(FoldSettings.self, encode(room))
        #expect(back == room)
        #expect(try decode(FoldSettings.self, #"{"look": "duo", "fadeLength": 9}"#).fadeLength == 1)
        #expect(try decode(FoldSettings.self, #"{"look": "duo", "fadeLength": 0}"#).fadeLength == 0.2)
        #expect(try decode(FoldSettings.self, #"{"look": "duo", "fadeLength": "slow"}"#).fadeLength == 0.55)
        #expect(FoldSettings.clampFadeLength(.nan) == 0.55)
    }

    // MARK: lane aquarium-swim

    @Test("the swim settings default to Natural at 1× and round-trip")
    func aquariumSwimRoundTrip() throws {
        let defaults = AquariumSettings()
        #expect(defaults.swimPace == .natural)
        #expect(defaults.swimSpeed == 1)
        #expect(defaults.fishScale == 1)
        var settings = AquariumSettings(enabled: true)
        settings.swimPace = .lively
        settings.swimSpeed = 1.4
        settings.fishScale = 0.7
        let text = try encode(settings)
        #expect(text.contains("\"swimPace\":\"lively\""), "the key is written")
        let decoded = try decode(AquariumSettings.self, text)
        #expect(decoded == settings)
    }

    @Test("the swim settings read tolerantly and clamp")
    func aquariumSwimTolerant() throws {
        let old = try decode(AquariumSettings.self, #"{"enabled": true, "density": 0.5}"#)
        #expect(old.swimPace == .natural && old.swimSpeed == 1 && old.fishScale == 1)
        let wild = try decode(AquariumSettings.self,
                              #"{"swimPace": "frantic", "swimSpeed": 9, "fishScale": 0.01}"#)
        #expect(wild.swimPace == .natural, "an unknown pace is Natural")
        #expect(wild.swimSpeed == AquariumSettings.swimSpeedRange.upperBound)
        #expect(wild.fishScale == AquariumSettings.fishScaleRange.lowerBound)
        let mistyped = try decode(AquariumSettings.self,
                                  #"{"swimPace": 2, "swimSpeed": "fast", "fishScale": true}"#)
        #expect(mistyped.swimPace == .natural && mistyped.swimSpeed == 1 && mistyped.fishScale == 1)
        #expect(AquariumSettings.clamped(.nan, to: AquariumSettings.fishScaleRange) == 1)
        for pace in SwimPace.allCases {
            let back = try decode(AquariumSettings.self, #"{"swimPace": "\#(pace.rawValue)"}"#)
            #expect(back.swimPace == pace)
        }
    }

    // MARK: lane aquarium-tank

    @Test("an old aquarium file keeps its tank: labels off reads as hover, density splits into bubbles and scenery")
    func aquariumTankMigration() throws {
        let old = try decode(AquariumSettings.self,
                             #"{"enabled": true, "showLabels": false, "density": 0.5}"#)
        #expect(old.labelStyle == .hover)
        #expect(old.showLabels == false)
        #expect(old.density == 0.5)
        #expect(old.bubbles == 0.5)
        #expect(old.scenery == .light)
        #expect(old.sound == false)
        #expect(old.maxFish == 0)
        #expect(old.keepResidents == true)
        #expect(old.visitors == true)
        let dense = try decode(AquariumSettings.self, #"{"density": 1.6}"#)
        #expect(dense.labelStyle == .always)
        #expect(dense.bubbles == 1.6)
        #expect(dense.scenery == .full)
    }

    @Test("aquarium tank settings clamp to their ranges and fall back when mistyped")
    func aquariumTankClamps() throws {
        let wild = try decode(AquariumSettings.self,
                              #"{"density": 9, "bubbles": -3, "maxFish": 7, "labelStyle": "sometimes", "scenery": 4, "sound": "yes"}"#)
        #expect(wild.density == AquariumSettings.densityRange.upperBound)
        #expect(wild.bubbles == 0)
        #expect(wild.maxFish == 0, "an unknown cap means all")
        #expect(wild.labelStyle == .always, "an unknown style falls back to the old switch")
        #expect(wild.scenery == .full)
        #expect(wild.sound == false)
        let low = try decode(AquariumSettings.self, #"{"density": -1, "bubbles": 5}"#)
        #expect(low.density == AquariumSettings.densityRange.lowerBound)
        #expect(low.bubbles == AquariumSettings.bubblesRange.upperBound)
        let future = try decode(AquariumSettings.self, #"{"dayNight": "alwaysNight"}"#)
        #expect(future.dayNight == .alwaysNight)
    }

    @Test("every new aquarium key round-trips, and the old switch is still written")
    func aquariumTankRoundTrip() throws {
        var settings = AquariumSettings(enabled: true)
        settings.labelStyle = .never
        settings.sound = true
        settings.maxFish = 16
        settings.keepResidents = false
        settings.density = 0.75
        settings.bubbles = 0
        settings.scenery = .bare
        settings.visitors = false
        settings.dayNight = .appearance
        let json = try encode(settings)
        for key in ["labelStyle", "sound", "maxFish", "keepResidents", "bubbles", "scenery", "visitors"] {
            #expect(json.contains("\"\(key)\""), "\(key) is written")
        }
        #expect(json.contains(#""showLabels":false"#), "an older build still reads its switch")
        let back = try decode(AquariumSettings.self, json)
        #expect(back == settings)
    }

    @Test("the label style and the old switch stay in step")
    func aquariumLabelsInStep() {
        var settings = AquariumSettings()
        settings.labelStyle = .hover
        #expect(settings.showLabels == false)
        settings.labelStyle = .always
        #expect(settings.showLabels == true)
        settings.showLabels = false
        #expect(settings.labelStyle == .hover)
        settings.labelStyle = .never
        settings.showLabels = false
        #expect(settings.labelStyle == .never, "writing the same off keeps Never")
    }

    // MARK: integration aquarium

    @Test("every aquarium key from both lanes round-trips in one file (X1)")
    func aquariumEveryKeyRoundTrips() throws {
        var settings = AquariumSettings(enabled: true)
        settings.swimPace = .calm
        settings.swimSpeed = 1.3
        settings.fishScale = 0.8
        settings.labelStyle = .hover
        settings.sound = true
        settings.maxFish = 10
        settings.keepResidents = false
        settings.bubbles = 0.4
        settings.scenery = .light
        settings.visitors = false
        let json = try encode(settings)
        for key in ["swimPace", "swimSpeed", "fishScale", "labelStyle", "sound", "maxFish",
                    "keepResidents", "bubbles", "scenery", "visitors"] {
            #expect(json.contains("\"\(key)\""), "\(key) is written")
        }
        #expect(try decode(AquariumSettings.self, json) == settings)
    }
}
