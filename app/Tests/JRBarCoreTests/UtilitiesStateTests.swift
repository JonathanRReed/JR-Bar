import Foundation
import Testing
@testable import JRBarCore

/// `UtilitiesState` is the Utilities page's half of `app-state.json`
/// (docs/UTILITIES.md): it must round-trip cleanly and read tolerantly,
/// the way `ToysState` does — a missing or mistyped key falls back to
/// its default and a newer build's keys are ignored.
@Suite("Utilities state")
struct UtilitiesStateTests {
    @Test("local menu search names survive settings round-trip and tolerate old files")
    func searchNamesRoundTrip() throws {
        var settings = MenuBarSettings()
        settings.curation.searchNames = ["v1:example-item": "Work VPN"]
        let restored = try decode(MenuBarSettings.self, encode(settings))
        #expect(restored.curation.searchNames == settings.curation.searchNames)
        #expect(try decode(MenuBarCuration.self, "{}").searchNames.isEmpty)
        #expect(try decode(MenuBarCuration.self, #"{"searchNames": 42}"#).searchNames.isEmpty)
        #expect(try decode(MenuBarCuration.self, #"{"searchNames": {"item": false}}"#).searchNames.isEmpty)
    }

    @Test("search-name-only edits leave hiding untouched, other settings still reapply")
    func searchNamesDoNotReapplyHiding() {
        let original = MenuBarSettings()
        var renamed = original
        renamed.curation.searchNames = ["item": "Work VPN"]
        #expect(!renamed.requiresReapply(comparedTo: original))
        renamed.enabled.toggle()
        #expect(renamed.requiresReapply(comparedTo: original))
        renamed = original
        renamed.curation.itemBarAt = .pointer
        #expect(renamed.requiresReapply(comparedTo: original))
    }

    @Test("hover entry and exit delays survive round-trip without changing the click timer")
    func hoverDelayRoundTrip() throws {
        var settings = MenuBarSettings()
        settings.hoverRevealSeconds = 0.4
        settings.hoverHideSeconds = 0.6
        settings.rehideSeconds = 9
        let restored = try decode(MenuBarSettings.self, encode(settings))
        #expect(restored.hoverRevealSeconds == 0.4)
        #expect(restored.hoverHideSeconds == 0.6)
        #expect(restored.rehideSeconds == 9)
    }

    @Test("older or malformed hover settings keep fast defaults and bound timer intervals")
    func hoverDelayCompatibility() throws {
        let old = try decode(MenuBarSettings.self, #"{"rehideSeconds": 9}"#)
        #expect(old.hoverRevealSeconds == 0.18)
        #expect(old.hoverHideSeconds == 0.25)
        let malformed = try decode(MenuBarSettings.self, #"{"hoverRevealSeconds":"slow","hoverHideSeconds":null}"#)
        #expect(malformed.hoverRevealSeconds == 0.18)
        #expect(malformed.hoverHideSeconds == 0.25)
        let bounds = try decode(MenuBarSettings.self, #"{"hoverRevealSeconds":-5,"hoverHideSeconds":999}"#)
        #expect(bounds.hoverRevealSeconds == 0.05)
        #expect(bounds.hoverHideSeconds == 3)
        let nonfinite = MenuBarSettings(hoverRevealSeconds: .nan, hoverHideSeconds: .infinity)
        #expect(nonfinite.hoverRevealSeconds == 0.18)
        #expect(nonfinite.hoverHideSeconds == 0.25)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("defaults: the page on, the Menu Bar utility on and quiet")
    func defaults() {
        let state = UtilitiesState()
        #expect(state.enabled == true)
        #expect(state.menuBar == MenuBarSettings())
        #expect(state.menuBar.enabled == true)
        #expect(state.menuBar.sections.isEmpty)
        #expect(state.menuBar.revealOnHover == true)
        #expect(state.menuBar.revealOnClick == true)
        #expect(state.menuBar.revealOnScroll == true)
        #expect(state.menuBar.rehideSeconds == MenuBarSettings.defaultRehideSeconds)
        #expect(state.menuBar.layoutModel == MenuBarSettings.currentLayoutModel)
    }

    @Test("encode then decode returns the same state")
    func roundTrip() throws {
        var state = UtilitiesState()
        state.menuBar = MenuBarSettings(enabled: true,
                                      sections: ["1Password": .hidden, "Ice": .alwaysHidden],
                                      revealOnHover: false, revealOnClick: true, revealOnScroll: false,
                                      rehideSeconds: 8)
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

    @Test("a file from the cover era decodes as layout model 0; a fresh value is current")
    func layoutModel() throws {
        // A map without the key is the cover era's; no map has nothing
        // to migrate and reads as current.
        #expect(try decode(MenuBarSettings.self, #"{"sections": {"A": "hidden"}}"#).layoutModel == 0)
        #expect(try decode(MenuBarSettings.self, #"{"enabled": true}"#).layoutModel
                == MenuBarSettings.currentLayoutModel)
        #expect(try decode(MenuBarSettings.self, #"{"layoutModel": 2}"#).layoutModel == 2)
        #expect(MenuBarSettings().layoutModel == MenuBarSettings.currentLayoutModel)
        // An old file's spacer field is simply ignored.
        #expect((try? decode(MenuBarSettings.self, #"{"spacerLength": 8000}"#)) != nil)
    }

    @Test("the retired `combinedStatusItem` key decodes away: never written, never fatal")
    func retiredCombinedStatusItem() throws {
        // An old profile carrying the key still decodes, the key dropped.
        let profile = try decode(MenuBarSettings.Profile.self,
                                 #"{"id": "p1", "name": "Old", "combinedStatusItem": true}"#)
        #expect(profile.name == "Old")
        #expect(profile.sections.isEmpty)
        let state = try decode(MenuBarSettings.self, #"{"combinedStatusItem": true}"#)
        #expect(state == MenuBarSettings())
    }

    @Test("a file that had the combined system item on is told once, and the key is never written")
    func combinedSystemItemIsNamedOnce() throws {
        let state = try decode(MenuBarSettings.self, #"{"combinedSystemItem": true}"#)
        #expect(state.retiredExtras == ["combined"])
        // Off stays off, and says nothing.
        let off = try decode(MenuBarSettings.self, #"{"combinedSystemItem": false}"#)
        #expect(off.retiredExtras.isEmpty)
        // Never written back: the retired keys are gone from the encoded file.
        let written = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!written.contains("combinedSystemItem"))
        #expect(!written.contains("agentStatusItem"))
        #expect(!written.contains("spacers"))
        #expect(!written.contains("faceSystemReadout"))
    }

    @Test("the agent item and the spacer rows decode away and leave one line to say")
    func agentItemAndSpacersAreNamedOnce() throws {
        let json = #"{"agentStatusItem": true, "spacers": [{"id": "s1", "label": "x", "width": 12}], "combinedSystemItem": true}"#
        let state = try decode(MenuBarSettings.self, json)
        #expect(state.retiredExtras == ["combined", "agents", "spacers"])
        // An empty spacer list is nothing to say.
        #expect(try decode(MenuBarSettings.self, #"{"spacers": []}"#).retiredExtras.isEmpty)
        // Once said and saved, the file carries the empty list and it stays empty.
        var said = state
        said.retiredExtras = []
        let again = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(said))
        #expect(again.retiredExtras.isEmpty)
        // A profile that carried spacers drops them without losing the rest.
        let profile = try decode(MenuBarSettings.Profile.self,
                                 #"{"id": "p1", "name": "Old", "spacers": [{"id": "s"}], "itemSpacing": 6}"#)
        #expect(profile.itemSpacing == 6)
    }

    @Test("the rehide mode defaults to timed and decodes tolerantly")
    func rehideModeDecode() throws {
        #expect(MenuBarSettings().rehideMode == .timed)
        #expect(try decode(MenuBarSettings.self, "{}").rehideMode == .timed)
        #expect(try decode(MenuBarSettings.self,
                           #"{"rehideMode": "untilClick"}"#).rehideMode == .untilClick)
        // A newer build's mode falls back rather than sinking the decode.
        #expect(try decode(MenuBarSettings.self,
                           #"{"rehideMode": "scheduled"}"#).rehideMode == .timed)
        var state = MenuBarSettings()
        state.rehideMode = .untilClick
        #expect(try JSONDecoder().decode(MenuBarSettings.self,
                                         from: JSONEncoder().encode(state)) == state)
    }

    @Test("a profile saved before the breadth fields decodes with the defaults")
    func profileBreadthDecode() throws {
        // The old profile shape: sections plus the cover look — no
        // reveal style, clock or spacing.
        let json = #"{"id": "p1", "name": "Old", "sections": {"A": "hidden"}, "coverMaterial": "hud"}"#
        let profile = try decode(MenuBarSettings.Profile.self, json)
        #expect(profile.sections == ["A": .hidden])
        #expect(profile.coverMaterial == .hud)
        #expect(profile.revealStyle == .bar)
        #expect(profile.rehideMode == .timed)
        #expect(profile.rehideSeconds == MenuBarSettings.defaultRehideSeconds)
        #expect(profile.itemSpacing == 0)
    }

    @Test("the reveal style defaults to inline (Ice) and decodes tolerantly")
    func revealStyleDecode() throws {
        // Ice's model is the default: a reveal draws the hidden items on
        // the row, where they can be ⌘-dragged back.
        #expect(MenuBarSettings().revealStyle == .inline)
        #expect(try decode(MenuBarSettings.self, "{}").revealStyle == .inline)
        // Bartender's Item Bar model round-trips by name.
        #expect(try decode(MenuBarSettings.self, #"{"revealStyle": "inline"}"#).revealStyle == .inline)
        #expect(try decode(MenuBarSettings.self, #"{"revealStyle": "bar"}"#).revealStyle == .bar)
        // A newer build's value — or a mistyped one — falls back rather
        // than sinking the decode.
        #expect(try decode(MenuBarSettings.self, #"{"revealStyle": "ribbon"}"#).revealStyle == .inline)
        #expect(try decode(MenuBarSettings.self, #"{"revealStyle": 4}"#).revealStyle == .inline)
        var state = MenuBarSettings()
        state.revealStyle = .bar
        #expect(try JSONDecoder().decode(MenuBarSettings.self,
                                         from: JSONEncoder().encode(state)) == state)
    }

    @Test("the macOS engine's saved keys read harmlessly: a saved macOS pick is simply the divider")
    func retiredEngineKeysDecodeAway() throws {
        // Every key a build with the macOS engine wrote for it. None is
        // an error, none changes anything, and none is written back.
        let json = #"""
        {"enginePreference": "macOS", "forceSpacerEngine": true, "dragToHide": false,
         "concealAppleExtras": true, "mirrorSeat": "slot", "revealWhileDragging": true,
         "newItems": "hidden", "concealSystemItems": true, "layoutTableBookmark": "AAAA",
         "itemBarAt": "pointer"}
        """#
        let curation = try decode(MenuBarCuration.self, json)
        // A curation block from before the models reads model 0 for both.
        #expect(curation == MenuBarCuration(profileModel: 0, positionModel: 0, itemBarAt: .pointer))
        #expect(try decode(MenuBarCuration.self, #"{"enginePreference": "quantum"}"#)
            == MenuBarCuration(profileModel: 0, positionModel: 0))
        let written = String(decoding: try JSONEncoder().encode(curation), as: UTF8.self)
        for key in ["enginePreference", "forceSpacerEngine", "dragToHide", "concealAppleExtras", "mirrorSeat",
                    "revealWhileDragging", "newItems", "concealSystemItems", "layoutTableBookmark"] {
            #expect(!written.contains(key), "\(key) is not written back")
        }
        // The settings that carried the engine's switches decode too.
        let settings = try decode(MenuBarSettings.self,
                                  #"{"concealUnnotarized": true, "concealSeeded": true, "faceSystemReadout": true}"#)
        #expect(settings == MenuBarSettings())
        let writtenSettings = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for key in ["concealUnnotarized", "concealSeeded", "faceSystemReadout"] {
            #expect(!writtenSettings.contains(key), "\(key) is not written back")
        }
        var round = MenuBarCuration()
        round.itemBarAt = .pointer
        #expect(try JSONDecoder().decode(MenuBarCuration.self,
                                         from: JSONEncoder().encode(round)) == round)
    }

    @Test("a file from before the position model reads as model 0; a fresh one as current")
    func positionModelDecode() throws {
        #expect(MenuBarCuration().positionModel == MenuBarCuration.currentPositionModel)
        #expect(try decode(MenuBarCuration.self, "{}").positionModel == 0)
        // A curation block from before the model reads 0, so its reveal
        // style is moved once; a file with no block at all is a fresh one.
        #expect(try decode(MenuBarSettings.self, #"{"curation": {}}"#).curation.positionModel == 0)
        #expect(try decode(MenuBarSettings.self, "{}").curation.positionModel
                == MenuBarCuration.currentPositionModel)
        #expect(try decode(MenuBarCuration.self, #"{"positionModel": 1}"#).positionModel == 1)
        // The suggestions from the old list and the closed hint round-trip;
        // a file that never had them reads empty and open, and a retired
        // `positionalHiding` key is ignored.
        #expect(try decode(MenuBarCuration.self, "{}").dividerSuggestions.isEmpty)
        #expect(try decode(MenuBarCuration.self, "{}").dividerHintDismissed == false)
        let kept = try decode(MenuBarCuration.self,
                              #"{"dividerSuggestions": ["a.app", "b.app"], "dividerHintDismissed": true, "positionalHiding": false}"#)
        #expect(kept.dividerSuggestions == ["a.app", "b.app"])
        #expect(kept.dividerHintDismissed)
        #expect(try JSONDecoder().decode(MenuBarCuration.self,
                                         from: JSONEncoder().encode(kept)) == kept)
    }

    @Test("item spacing decodes with its managed flag; a bare value implies managed")
    func itemSpacingDecode() throws {
        // Nothing on file: untouched, and the writer stays out of it.
        let fresh = try decode(MenuBarSettings.self, "{}")
        #expect(fresh.itemSpacing == 0)
        #expect(fresh.itemSpacingManaged == false)
        // A file that carried a value but predates the flag was written
        // by us — managed so the default choice can remove the keys.
        let legacy = try decode(MenuBarSettings.self, #"{"itemSpacing": 8}"#)
        #expect(legacy.itemSpacing == 8)
        #expect(legacy.itemSpacingManaged == true)
        // An explicit flag wins; a negative gap clamps to untouched.
        #expect(try decode(MenuBarSettings.self,
                           #"{"itemSpacing": 4, "itemSpacingManaged": false}"#).itemSpacingManaged == false)
        #expect(try decode(MenuBarSettings.self, #"{"itemSpacing": -9}"#).itemSpacing == 0)
        var state = MenuBarSettings()
        state.itemSpacing = 8
        state.itemSpacingManaged = true
        #expect(try JSONDecoder().decode(MenuBarSettings.self,
                                         from: JSONEncoder().encode(state)) == state)
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
