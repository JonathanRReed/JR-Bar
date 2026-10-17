import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// One home for each setting that used to be offered in several places:
/// hotkeys on Shortcuts, the menu bar meters on Usage, the brightness cap
/// on Lighting. Everywhere else says so in a line and links there, and a
/// search for the old words still lands on the home.
@Suite("Settings homes")
@MainActor
struct SettingsHomesTests {
    private var entries: [SettingsSearchEntry] {
        SettingsSearch.rows + SettingsSearch.pages + SettingsSearch.shortcutRows
    }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/JRBarApp")

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.sources.appending(path: relative), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("every home is a row the search lists, so its link can land on it")
    func everyHomeResolves() {
        for home in SettingsHome.allCases {
            let entry = home.entry
            #expect(entry != nil, "\(home) has no search entry titled \(home.title)")
            #expect(entry?.chapter == home.chapter)
        }
        #expect(SettingsHome.hotkeys.chapter == .shortcuts)
        #expect(SettingsHome.meters.chapter == .usage)
        #expect(SettingsHome.brightness.chapter == .lighting)
        #expect(SettingsHome.meters.page == .agents)
        #expect(SettingsHome.brightness.page == .devices)
    }

    @Test("a search for the old words lands on the home, not on a copy")
    func oldWordsFindTheHome() {
        let panel = SettingsSearch.search("panel hotkey", in: entries).first
        #expect(panel?.chapter == .shortcuts && panel?.title == "Show the panel")
        let shelf = SettingsSearch.search("shelf hotkey", in: entries).first
        #expect(shelf?.chapter == .shortcuts && shelf?.title == "Open the shelf")
        let brightness = SettingsSearch.search("maximum brightness", in: entries).first
        #expect(brightness?.chapter == .lighting && brightness?.title == "Maximum brightness")
        let meters = SettingsSearch.search("menu bar meters", in: entries).first
        #expect(meters?.chapter == .usage && meters?.title == "Show meters for")
        #expect(!SettingsSearch.rows.contains { $0.chapter == .general && $0.title.hasSuffix("hotkey") },
                "General lists no hotkey row of its own")
        #expect(!SettingsSearch.rows.contains { $0.chapter == .general && $0.title == "Maximum brightness" })
    }

    @Test("following a pointer opens the home page scrolled to its row")
    func followingAPointer() {
        let store = SettingsStore(core: CoreModel())
        store.page = .general
        let before = store.revealRequest
        store.revealHome(.hotkeys)
        #expect(store.page == .shortcuts)
        #expect(store.searchHit?.title == "Show the panel")
        #expect(store.revealRequest == before + 1)
        store.page = .general
        store.revealHome(.brightness)
        #expect(store.page == .devices && store.searchHit?.title == "Maximum brightness")
        store.revealHome(.hotkeys, titled: "Open the shelf")
        #expect(store.searchHit?.title == "Open the shelf")
        store.revealHome(.meters)
        #expect(store.page == .agents)
    }

    @Test("the brightness cap's reset belongs to the page it is drawn on")
    func brightnessResetsWithLighting() {
        let key = SettingsKey.all.first { $0.path == "global_brightness_scale" }
        #expect(key?.page == .lighting)
        #expect(!SettingsKey.all.contains { $0.page == .general && $0.path == "global_brightness_scale" })
    }

    @Test("each control is drawn once: no second switch, slider or recorder for the same setting")
    func eachControlIsDrawnOnce() throws {
        let general = try source("SettingsPagesA.swift")
        let shell = try source("SettingsPagesShell.swift")
        let lighting = try source("SettingsPagesB.swift")
        // The summon keys: one switch for each, on Shortcuts.
        #expect(count("$store.panelHotkeyEnabled", in: general) == 0)
        #expect(count("$store.shelfHotkeyEnabled", in: general) == 0)
        #expect(count("$store.panelHotkeyEnabled", in: shell) == 1)
        #expect(count("$store.shelfHotkeyEnabled", in: shell) == 1)
        let notch = try source("Toys/NotchControlsView.swift")
        #expect(count("shelfHotkeyEnabled", in: notch) == 0, "the shelf card links to the key, it does not switch it")
        // The Menu Bar utility's keys: switched on Shortcuts, not on its card.
        let card = try source("Utilities/MenuBar/MenuBarUtilityCard.swift")
        #expect(count("setHotkeyEnabled", in: card) == 0)
        #expect(count("menuBar.setHotkeyEnabled", in: shell) == 1)
        // The brightness cap: one slider, on Lighting.
        #expect(count("\"global_brightness_scale\"", in: general) == 0)
        #expect(count("\"global_brightness_scale\"", in: lighting) == 1)
        // The menu bar meters: one picker, on Usage.
        let usage = try source("SettingsPagesA.swift")
        #expect(count("MultiSelectMenu(store, \"Show meters for\"", in: usage) == 1)
        #expect(count("path: \"usage_graph_providers\"", in: usage) == 1, "one control writes the meters' providers")
        #expect(count("SettingsPointerRow(store: store, home:", in: general) == 3)
    }

    @Test("General's line about the summon keys says what they are and where to change them")
    func summonLine() {
        let store = SettingsStore(core: CoreModel())
        store.panelHotkeyEnabled = true
        store.shelfHotkeyEnabled = false
        store.panelHotkeyRegistrationFailed = false
        store.shelfHotkeyRegistrationFailed = false
        let line = store.summonHotkeyLine
        #expect(line.contains("Shortcuts"))
        #expect(line.contains("shelf key off"))
        store.panelHotkeyRegistrationFailed = true
        #expect(store.summonHotkeyLine.contains("is taken"))
    }
}
