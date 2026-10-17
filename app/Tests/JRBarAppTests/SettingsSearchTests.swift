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
        #expect(lid?.page == .general, "Power sits on General now")
        #expect(lid?.chapter == .general)
        #expect(SettingsSearch.search("alert burst", in: entries).first?.title == "Alert burst")
        #expect(SettingsSearch.search("launch at login", in: entries).first?.chapter == .general)
    }

    @Test @MainActor func usageCenterSearchRevealsItsEntry() throws {
        let entry = try #require(SettingsSearch.search("usage center", in: entries).first)
        #expect(entry.title == "Usage Center")
        #expect(entry.group == "Usage Center")
        #expect(entry.chapter == .usage)
        let settings = SettingsStore(core: CoreModel())
        settings.reveal(entry)
        #expect(settings.page == entry.page)
        #expect(settings.searchHit == entry)
    }

    @Test func everySidebarPageHasItsOwnGlyph() {
        let symbols = SettingsStore.Page.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "no two pages share a sidebar icon")
        #expect(SettingsStore.Chapter.advanced.symbol == "slider.horizontal.3")
        let chapterSymbols = SettingsStore.Chapter.allCases.map(\.symbol)
        #expect(Set(chapterSymbols).count == chapterSymbols.count, "no two chapters share an icon either")
    }

    @Test func aPartialWordStillFindsIt() {
        #expect(SettingsSearch.search("webho", in: entries).first?.title == "Webhook URL")
        #expect(SettingsSearch.search("calib", in: entries).contains { $0.title == "Colour calibration" })
    }

    @Test func aPagesSynonymsLandOnThePage() {
        #expect(SettingsSearch.search("sound", in: entries).first?.chapter == .sounds)
        #expect(SettingsSearch.search("dnd", in: entries).contains { $0.chapter == .notifications && $0.title == SettingsStore.Chapter.notifications.title })
        #expect(SettingsSearch.search("hotkey", in: entries).contains { $0.chapter == .shortcuts })
    }

    @Test func quickTogglesAreFoundByTheirChipWords() {
        let hits = SettingsSearch.search("microphone", in: entries)
        // The Sounds page's microphone row answers the same word; the chip is found too.
        let chip = hits.first { $0.title == SystemToggle.micMute.longTitle }
        #expect(chip?.chapter == .shortcuts)
        #expect(hits.prefix(3).contains { $0.title == SystemToggle.micMute.longTitle })
    }

    @Test func theCommandLineToolIsFoundByTerminalWords() {
        #expect(SettingsSearch.search("cli", in: entries).contains { $0.title == "jrbar in Terminal" })
        #expect(SettingsSearch.search("command line", in: entries).first?.title == "jrbar in Terminal")
        #expect(SettingsSearch.search("terminal", in: entries).first?.chapter == .shortcuts)
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

    @Test func aRowThatIsOnlySometimesDrawnSaysWhenItAppears() {
        let corner = SettingsSearch.rows.first { $0.title == "Corner radius" }
        #expect(corner?.hint == "Shown when Notch shape is Custom.")
        let banner = corner.map(SettingsSearch.banner(for:))
        #expect(banner == "“Corner radius” is under Screen Bar. Shown when Notch shape is Custom.")
        let always = SettingsSearch.rows.first { $0.title == "Show the panel" }
        #expect(always.map(SettingsSearch.banner(for:)) == "“Show the panel” is under JR-Bar.")
        let page = SettingsSearchEntry(.general, "", "General")
        #expect(SettingsSearch.banner(for: page) == "“General” is on this page.")
    }

    @Test func everyConditionalHintNamesARowTheListHas() {
        for key in SettingsSearch.hints.keys {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            #expect(parts.count == 3)
            #expect(SettingsSearch.rows.contains { $0.chapter.rawValue == parts[0] && $0.group == parts[1] && $0.title == parts[2] },
                    "\(key) hints at a row the search does not list")
        }
        for entry in SettingsSearch.rows where SettingsSearch.hints["\(entry.chapter.rawValue)/\(entry.group)/\(entry.title)"] != nil {
            #expect(entry.hint != nil, "\(entry.title) lost its hint")
        }
    }

    @Test func everyToyCatalogTitleIsStillARowItsCardDraws() {
        // The card rows are hand-kept too: each title must still be the
        // exact `SettingLabel` title that card's own controls draw, and
        // each key must still be the id its card declares. Reading only
        // the card's own files keeps a same-named row on another card
        // ("Render with", "Density") from vouching for this one.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        let homes: [String: [String]] = [
            "notch": ["Toys/NotchToy.swift", "Toys/NotchControlsView.swift"],
            "notch-buddy": ["Toys/NotchBuddyToy.swift"],
            "confetti": ["Toys/ConfettiToy.swift", "Toys/ConfettiCard.swift"],
            "aquarium": ["Toys/Aquarium"],
            "fold": ["Toys/Fold"],
            "menuBar": ["Utilities/MenuBar"],
            "dock": ["Utilities/Dock"],
            "agents": ["Utilities/Agents"],
        ]
        func text(of home: String) -> String {
            let url = sources.appending(path: home)
            guard url.pathExtension != "swift" else {
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            var joined = ""
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                joined += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
            return joined
        }
        #expect(Set(homes.keys) == Set(ToySearchCatalog.rows.keys), "every listed card says where it lives")
        for (card, rows) in ToySearchCatalog.rows {
            let cardText = (homes[card] ?? []).map(text(of:)).joined()
            #expect(!cardText.isEmpty, "\(card)'s files are gone")
            #expect(!rows.isEmpty, "\(card) lists no rows")
            #expect(cardText.contains("let id = \"\(card)\"")
                    || cardText.contains("var id: String { \"\(card)\" }"),
                    "no card declares the id \(card)")
            for row in rows {
                #expect(cardText.contains("SettingLabel(title: \"\(row.title)\""),
                        "\(card) no longer draws \(row.title)")
            }
            #expect(Set(rows.map(\.title)).count == rows.count, "\(card) lists a row twice")
        }
    }

    @Test func aConditionalRowNamesTheSwitchThatShowsIt() {
        // A card draws some rows only while another is on. Searching for
        // one must say so, and the switch it names must be a row of the
        // same card, or the hint would send a person nowhere.
        var conditional = 0
        for (card, rows) in ToySearchCatalog.rows {
            let titles = Set(rows.map(\.title))
            for row in rows {
                guard let needs = row.needs else { continue }
                conditional += 1
                #expect(titles.contains(needs), "\(card): \(row.title) needs \(needs), which is not a row")
                #expect(row.hint?.contains(needs) == true)
            }
        }
        #expect(conditional >= 14, "the notch's and the confetti card's conditional rows are marked")
        #expect(ToySearchRow("Capsule tick").hint == nil, "an always-drawn row carries no hint")
    }

    @Test @MainActor func aConditionalRowResultCarriesItsHint() {
        let core = CoreModel()
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        let held = settings.searchEntries.first { $0.title == "A held burst" }
        #expect(held?.card == "confetti")
        #expect(held?.subtitle?.contains("Quiet the toys") == true)
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
        #expect(lyrics?.chapter == .utilities)
        #expect(lyrics?.page == .utilities)
        #expect(lyrics?.card == "notch")
        #expect(SettingsSearch.search("lrclib", in: searchable).first?.card == "notch")
        let screensaver = SettingsSearch.search("screensaver", in: searchable).first
        #expect(screensaver?.card == "aquarium")
        #expect(screensaver?.chapter == .toys)
        #expect(screensaver?.page == .utilities, "Toys sit on the Utilities & Toys page")
        // The notch card itself is searchable, on the Utilities page.
        #expect(searchable.contains { $0.title == "Notch" && $0.chapter == .utilities && $0.card == "notch" })
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
        settings.reveal(SettingsSearchEntry(.general, "Power", "Lid closed"))
        #expect(settings.highlightedCard == nil)
        #expect(settings.revealRequest == before + 4, "a row on a daemon page asks the page to scroll to its group too")
        #expect(SettingsStore.groupAnchor("Power") == "group:Power")
    }

    @Test func everyPageAndChapterIsSearchable() {
        #expect(Set(SettingsSearch.pages.map(\.chapter)) == Set(SettingsStore.Chapter.allCases))
        #expect(Set(SettingsSearch.pages.map(\.page)) == Set(SettingsStore.Page.allCases))
        for chapter in SettingsStore.Chapter.allCases {
            #expect(SettingsSearch.pageKeywords[chapter] != nil, "\(chapter) has no search words")
        }
    }
}
