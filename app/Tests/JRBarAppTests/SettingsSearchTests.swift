import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings search: the ranking lands a row's own words on its row, a
/// page's synonyms on the page, and the listed rows can never name a
/// title the app no longer draws.
@Suite struct SettingsSearchTests {
    private var entries: [SettingsSearchEntry] {
        SettingsSearch.rows + SettingsSearch.pages + SettingsSearch.shortcutRows
    }

    @Test func aRowsOwnWordsLandOnTheRow() {
        let lid = SettingsSearch.search("lid closed", in: entries).first
        #expect(lid?.title == "Lid closed")
        #expect(lid?.page == .notifications)
        #expect(SettingsSearch.search("alert burst", in: entries).first?.title == "Alert burst")
        #expect(SettingsSearch.search("launch at login", in: entries).first?.page == .general)
    }

    @Test func everySidebarPageHasItsOwnGlyph() {
        let symbols = SettingsStore.Page.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "no two pages share a sidebar icon")
        #expect(SettingsStore.Page.advanced.symbol == "slider.horizontal.3")
    }

    @Test func aPartialWordStillFindsIt() {
        #expect(SettingsSearch.search("webho", in: entries).first?.title == "Webhook URL")
        #expect(SettingsSearch.search("calib", in: entries).contains { $0.title == "Colour calibration" })
    }

    @Test func aPagesSynonymsLandOnThePage() {
        #expect(SettingsSearch.search("sound", in: entries).first?.page == .sounds)
        #expect(SettingsSearch.search("dnd", in: entries).contains { $0.page == .notifications && $0.title == SettingsStore.Page.notifications.title })
        #expect(SettingsSearch.search("hotkey", in: entries).contains { $0.page == .shortcuts })
    }

    @Test func quickTogglesAreFoundByTheirChipWords() {
        let hits = SettingsSearch.search("microphone", in: entries)
        #expect(hits.first?.title == SystemToggle.micMute.longTitle)
        #expect(hits.first?.page == .shortcuts)
    }

    @Test func theCommandLineToolIsFoundByTerminalWords() {
        #expect(SettingsSearch.search("cli", in: entries).first?.title == "jrbar in Terminal")
        #expect(SettingsSearch.search("terminal", in: entries).first?.page == .shortcuts)
    }

    @Test func accentsCaseAndPunctuationDoNotMatter() {
        #expect(SettingsSearch.search("COLOUR-calibration", in: entries).first?.title == "Colour calibration")
        #expect(SettingsSearch.search("  ", in: entries).isEmpty)
        #expect(SettingsSearch.search("zzqqxx", in: entries).isEmpty)
    }

    @Test func everyListedRowIsStillARowTheAppDraws() throws {
        // The list is hand-kept, so it is held honest against the source:
        // a renamed or removed row fails here instead of leading a search
        // to a title that is no longer on the page.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var text = ""
        // The index itself quotes every title, so it cannot vouch for one.
        for case let url as URL in files
        where url.pathExtension == "swift" && url.lastPathComponent != "SettingsSearch.swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        #expect(!text.isEmpty)
        for row in SettingsSearch.rows {
            #expect(text.contains("\"\(row.title)\""), "no row titled \(row.title) remains")
        }
    }

    @Test func everyToyCatalogTitleIsStillARowItsCardDraws() throws {
        // The card rows are hand-kept too: each title must still be the
        // exact `SettingLabel` title a card's controls draw.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in files
        where url.pathExtension == "swift" && url.lastPathComponent != "ToySearchRows.swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        #expect(!text.isEmpty)
        for (card, rows) in ToySearchCatalog.rows {
            #expect(!rows.isEmpty, "\(card) lists no rows")
            #expect(text.contains("\"\(card)\""), "no card has the id \(card)")
            for row in rows {
                #expect(text.contains("title: \"\(row.title)\""), "\(card) no longer draws \(row.title)")
            }
            #expect(Set(rows.map(\.title)).count == rows.count, "\(card) lists a row twice")
        }
    }

    @Test @MainActor func aRowInsideACardLandsOnThatCard() {
        let core = CoreModel()
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        let searchable = settings.searchEntries
        let lyrics = SettingsSearch.search("synced lyrics", in: searchable).first
        #expect(lyrics?.title == "Synced lyrics")
        #expect(lyrics?.page == .utilities)
        #expect(lyrics?.card == "notch")
        #expect(SettingsSearch.search("lrclib", in: searchable).first?.card == "notch")
        let screensaver = SettingsSearch.search("screensaver", in: searchable).first
        #expect(screensaver?.card == "aquarium")
        #expect(screensaver?.page == .toys)
        // The notch card itself is searchable, on the Utilities page.
        #expect(searchable.contains { $0.title == "Notch" && $0.page == .utilities && $0.card == "notch" })
        withExtendedLifetime(toys) {}
    }

    @Test @MainActor func revealingACardRowOpensAndLightsTheCard() {
        let settings = SettingsStore(core: CoreModel())
        let hit = SettingsSearchEntry(.utilities, "Notch", "Synced lyrics", card: "notch")
        let before = settings.revealRequest
        settings.reveal(hit)
        #expect(settings.page == .utilities)
        #expect(settings.searchHit == hit)
        #expect(settings.expandedCards.contains("notch"))
        #expect(settings.highlightedCard == "notch")
        #expect(settings.revealRequest == before + 1)
        // The same hit again still asks the page to scroll.
        settings.reveal(hit)
        #expect(settings.revealRequest == before + 2)
        // Folding the card by hand is the person's.
        settings.setCard("notch", expanded: false)
        #expect(!settings.expandedCards.contains("notch"))
        // A daemon-page row names itself and lights no card; leaving
        // the page lets the light go.
        settings.reveal(hit)
        settings.page = .general
        #expect(settings.highlightedCard == nil)
        #expect(settings.searchHit == nil)
        settings.reveal(SettingsSearchEntry(.notifications, "Power", "Lid closed"))
        #expect(settings.highlightedCard == nil)
        #expect(settings.revealRequest == before + 3)
    }

    @Test func everyPageIsSearchable() {
        #expect(Set(SettingsSearch.pages.map(\.page)) == Set(SettingsStore.Page.allCases))
        for page in SettingsStore.Page.allCases {
            #expect(SettingsSearch.pageKeywords[page] != nil, "\(page) has no search words")
        }
    }
}
