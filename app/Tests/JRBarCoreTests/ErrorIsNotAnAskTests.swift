import Foundation
import Testing
@testable import JRBarCore

/// The app half of "a failed session is not one waiting on you".
///
/// The daemon routed `LedDisplayState.FAILED` to the Ask mode colour until
/// 2026-09-10, and the app agreed with it: `DeckSlotState.failure` and
/// `.inputRequired` both drew `#FF3A00`, the settings catalogue named the
/// four mode colours and not a fifth, and the panel painted the word
/// "Failed" in the same grey as "Idle".
@Suite("Error is not an ask")
struct ErrorIsNotAnAskTests {
    @Test("the deck's failure key is its own colour, not the ask one")
    func deckLighting() {
        #expect(DeckLighting.errorHex == "#B00020")
        #expect(DeckLighting.errorHex != DeckLighting.askHex)
        #expect(DeckSlotState.failure.lightingHex == DeckLighting.errorHex)
        #expect(DeckSlotState.inputRequired.lightingHex == DeckLighting.askHex)
        // Both still count as "look at me", which is a separate question
        // from "and they look the same".
        #expect(DeckSlotState.failure.needsAttention && DeckSlotState.inputRequired.needsAttention)
        #expect(!DeckLighting.isDark(DeckLighting.errorHex))
    }

    @Test("the settings catalogue offers all five mode colours on the Lighting page")
    func modeColourKeys() {
        #expect(SettingsKey.modes == ["idle", "working", "done", "ask", "error"])
        let paths = Set(SettingsKey.keys(on: .lighting).map(\.path))
        for mode in SettingsKey.modes {
            #expect(paths.contains("colors.mode_colors.\(mode)"), "no control for \(mode)")
        }
        // Error shares the ask's pulse range on purpose -- only the colour
        // is its own -- so it must NOT have grown fade sliders.
        #expect(!SettingsKey.modes.isEmpty && !SettingsKey.fadeModes.contains("error"))
        #expect(!paths.contains("colors.fade_floor.error"))
    }

    @Test("a settings document written before the key existed is still readable")
    func olderDocument() throws {
        // The owner's real settings, captured before `error` was a key.
        guard case .settings(let settings) = try CoreFixtures.message("real_settings.json") else {
            throw CoreReplyError(code: "fixture", message: "not a settings message")
        }
        let document = SettingsDocument(settings.document)
        #expect(document.string("colors.mode_colors.ask") == "#D187F5")
        #expect(document.string("colors.mode_colors.error") == nil)
        // Which the page reports honestly rather than crashing or inventing
        // a value: the control says "not provided" until the daemon sends it.
        let key = try #require(SettingsKey.all.first { $0.path == "colors.mode_colors.error" })
        #expect(!key.isProvided(in: document))
    }

    @Test("failed and waiting are different words, and neither is the quiet one")
    func activityWords() {
        #expect(SessionActivity.failed.word == "Failed")
        #expect(SessionActivity.waiting.word == "Waiting on you")
        #expect(SessionActivity.failed != SessionActivity.waiting)
        // A failure is not something you clear like a finished run.
        #expect(!SessionActivity.failed.isClearable)
        // And the daemon's several spellings for it all land on failed.
        #expect(SessionActivity.reduce(lifecycle: "failed", mode: nil, hasAsk: false, nextActor: nil) == .failed)
        #expect(SessionActivity.reduce(lifecycle: nil, mode: "error", hasAsk: false, nextActor: nil) == .failed)
        // Lifecycle wins: a failed session that also has an ask open is
        // still failed, not waiting.
        #expect(SessionActivity.reduce(lifecycle: "failed", mode: nil, hasAsk: true, nextActor: "user") == .failed)
    }

    @Test("the light explanation says red flash for a failure and amber pulse for an ask")
    func explanation() {
        // The words were already right; the hardware is what had to catch
        // up. This pins them together so neither drifts alone.
        #expect(LightExplainer.colourName("#B00020") == "red")
        #expect(LightWhy.parse("failed") == .failed)
        #expect(LightWhy.parse("error") == .failed)
        #expect(LightWhy.parse("failure") == .failed)
        #expect(LightWhy.parse("waiting") == .waiting)
        #expect(LightWhy.parse("input_required") == .waiting)
    }
}
