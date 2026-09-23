import Carbon
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The `jrbar://` vocabulary and the router behind links, shortcuts and
/// Shortcuts actions: every link parses whole or not at all, and a
/// command that cannot run is refused out loud.
@Suite struct AppCommandTests {
    private func parse(_ text: String) -> AppCommand? {
        URL(string: text).flatMap(AppCommand.parse)
    }

    @Test func thePanelAndSettingsLinks() {
        #expect(parse("jrbar://panel") == .panel(toggle: false))
        #expect(parse("jrbar://panel/toggle") == .panel(toggle: true))
        #expect(parse("jrbar:///panel/toggle") == .panel(toggle: true))
        #expect(parse("jrbar://settings") == .settings(page: nil))
        #expect(parse("jrbar://settings/Shortcuts") == .settings(page: "shortcuts"))
        #expect(parse("jrbar://settings/nowhere") == nil)
        #expect(parse("jrbar://overview") == .window(.overview))
        #expect(parse("jrbar://open/control-center") == .window(.controlCenter))
    }

    @Test func everySettingsPageALinkMayNameExists() {
        // The pure parser keeps its own list so it needs no main-actor
        // type; this keeps it honest against the real pages.
        let pages = Set(SettingsStore.Page.allCases.map(\.rawValue))
        #expect(SettingsPageName.known == pages)
    }

    @Test func toggleLinksNameChipsTheWayAPersonWould() {
        #expect(parse("jrbar://toggle/dark") == .toggle(.darkMode, on: nil))
        #expect(parse("jrbar://toggle/darkMode?on=1") == .toggle(.darkMode, on: true))
        #expect(parse("jrbar://toggle/DOCK?on=off") == .toggle(.dockAutoHide, on: false))
        #expect(parse("jrbar://toggle/mic") == .toggle(.micMute, on: nil))
        #expect(parse("jrbar://toggle/eject") == .toggle(.eject, on: nil))
        #expect(parse("jrbar://toggle/keep-awake") == .toggle(.keepAwake, on: nil))
        #expect(parse("jrbar://toggle/warp") == nil)
        #expect(parse("jrbar://toggle/dark?on=maybe") == nil)
    }

    @Test func awakeTakesADurationOrOff() {
        #expect(parse("jrbar://awake") == .keepAwake(seconds: nil))
        #expect(parse("jrbar://awake?for=2h") == .keepAwake(seconds: 7200))
        #expect(parse("jrbar://awake?for=1h30m") == .keepAwake(seconds: 5400))
        #expect(parse("jrbar://awake?for=off") == .keepAwake(seconds: 0))
        #expect(parse("jrbar://awake?for=2x") == nil)
        #expect(parse("jrbar://awake?for=3d") == nil, "longer than a day is refused")
    }

    @Test func quietTakesAModeAndALength() {
        #expect(parse("jrbar://quiet") == .quiet(mode: nil, seconds: 3600))
        #expect(parse("jrbar://quiet?mode=dim&for=30m") == .quiet(mode: "dim", seconds: 1800))
        #expect(parse("jrbar://quiet?mode=asks-only&for=1h") == .quiet(mode: "asks_only", seconds: 3600))
        #expect(parse("jrbar://quiet?mode=dnd") == .quiet(mode: "pause", seconds: 3600))
        #expect(parse("jrbar://quiet/end") == .endQuiet)
        #expect(parse("jrbar://quiet?for=0") == .endQuiet)
        #expect(parse("jrbar://quiet?mode=loud") == nil)
    }

    @Test func theRestOfTheVocabulary() {
        #expect(parse("jrbar://screenbar") == .screenBar(on: nil))
        #expect(parse("jrbar://screenbar/off") == .screenBar(on: false))
        #expect(parse("jrbar://confetti") == .confetti)
        #expect(parse("jrbar://menubar/reveal") == .menuBar(.reveal))
        #expect(parse("jrbar://menubar/command-bar") == .menuBar(.commandBar))
        #expect(parse("jrbar://ask") == .revealAsk)
        #expect(parse("jrbar://shelf") == .shelf)
        #expect(parse("jrbar://session?id=claude%3Asession%3Aabc") == .openSession("claude:session:abc"))
    }

    @Test func noLinkAnswersAnAskOrRewritesTheMenuBar() {
        // Approve and Deny stay where the ask is on screen; Hide all and
        // Show all rewrite the curated map. Neither is a link.
        #expect(parse("jrbar://ask/approve") == nil)
        #expect(parse("jrbar://answer?decision=approve") == nil)
        #expect(parse("jrbar://menubar/hide-all") == nil)
        #expect(parse("jrbar://menubar/show-all") == nil)
        #expect(parse("https://example.com/panel") == nil)
    }

    @Test func durationsRefuseTyposRatherThanReadZero() {
        #expect(AppCommand.duration("90") == 90)
        #expect(AppCommand.duration("90s") == 90)
        #expect(AppCommand.duration("15m") == 900)
        #expect(AppCommand.duration("1d") == 86_400)
        #expect(AppCommand.duration("") == nil)
        #expect(AppCommand.duration("m") == nil)
        #expect(AppCommand.duration("5 m") == 300)
        #expect(AppCommand.duration("-5") == nil)
        #expect(AppCommand.duration("99999999999999999999h") == nil)
    }

    // MARK: The router

    @MainActor
    @Test func anUnwiredOrRefusingCommandIsSaidOutLoud() {
        let router = AppCommandRouter()
        var said: [String] = []
        router.onRefused = { said.append($0) }
        #expect(router.perform(.confetti) != .done)
        router.revealAsk = { "No agent is waiting on you." }
        #expect(router.perform(.revealAsk) == .refused("No agent is waiting on you."))
        var opened: [Bool] = []
        router.showPanel = { opened.append($0) }
        #expect(router.perform(.panel(toggle: true)) == .done)
        #expect(opened == [true])
        #expect(router.open(URL(string: "jrbar://nonsense")!) != .done)
        #expect(said.count == 3)
    }

    // MARK: App shortcuts

    @Test func theRetiredRevealKeyIsReadFromTheDaemonsSettings() {
        let shortcuts: JSONValue = .object([
            "reveal_current_ask": .object([
                "key_code": .number(Double(kVK_ANSI_R)),
                "key_label": .string("R"),
                "modifiers": .array([.string("control"), .string("option"), .string("command")]),
            ]),
        ])
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: shortcuts)
                == HotkeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: nil) == nil)
        let bad: JSONValue = .object(["reveal_current_ask": .object([
            "key_code": .number(15), "modifiers": .array([.string("hyper")]),
        ])])
        #expect(AppShortcutCatalog.legacyRevealAskChord(from: bad) == nil)
    }

    @MainActor
    @Test func theLegacyKeyIsAdoptedOnceAndNeverOverAChoice() throws {
        let suite = "AppCommandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkeys = AppHotkeys()
        hotkeys.defaults = defaults
        hotkeys.center = HotkeyCenter(registrar: HotkeyCenterTests.Recorder())
        let shortcuts: JSONValue = .object([
            "reveal_current_ask": .object([
                "key_code": .number(Double(kVK_ANSI_R)),
                "modifiers": .array([.string("control"), .string("option")]),
            ]),
        ])
        hotkeys.adoptLegacy(shortcuts: shortcuts)
        let expected = HotkeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
        #expect(hotkeys.chord(for: AppShortcutCatalog.revealAskID) == expected)
        #expect(hotkeys.center.status(of: AppShortcutCatalog.revealAskID) == .active(expected))

        // A person who cleared the row keeps it cleared.
        let other = AppHotkeys()
        other.defaults = defaults
        other.center = HotkeyCenter(registrar: HotkeyCenterTests.Recorder())
        other.setChord(nil, for: AppShortcutCatalog.revealAskID)
        other.adoptLegacy(shortcuts: shortcuts)
        #expect(other.chord(for: AppShortcutCatalog.revealAskID) == nil)
    }

    @Test func theShortcutsParametersCoverTheVocabulary() {
        // Every chip is pickable in Shortcuts, and every pick is a chip.
        #expect(Set(QuickToggleOption.allCases.compactMap(\.toggle)) == Set(SystemToggle.allCases))
        #expect(QuickToggleOption.allCases.count == SystemToggle.allCases.count)
        // Every quiet mode Shortcuts offers is one the daemon takes.
        #expect(Set(QuietModeOption.allCases.map(\.rawValue)) == AppCommand.quietModes)
    }

    @MainActor
    @Test func aShortcutsActionThrowsTheRoutersRefusal() {
        let router = AppCommandRouter.shared
        let saved = router.revealAsk
        defer { router.revealAsk = saved }
        router.revealAsk = { "No agent is waiting on you." }
        #expect(throws: JRBarIntentError.self) { try JRBarIntentBridge.run(.revealAsk) }
    }

    @Test func everyChipHasAnActionAndEveryIDIsUnique() {
        let ids = AppShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for toggle in SystemToggle.allCases {
            #expect(AppShortcutCatalog.action(id: AppShortcutCatalog.toggleID(toggle))?.command
                    == .toggle(toggle, on: nil))
        }
    }
}
