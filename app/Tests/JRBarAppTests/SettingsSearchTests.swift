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

    @Test func aPartialWordStillFindsIt() {
        #expect(SettingsSearch.search("webho", in: entries).first?.title == "Webhook URL")
        #expect(SettingsSearch.search("calib", in: entries).contains { $0.title == "Colour calibration" })
    }

    @Test func aPagesSynonymsLandOnThePage() {
        #expect(SettingsSearch.search("sound", in: entries).contains { $0.page == .notifications && $0.title == SettingsStore.Page.notifications.title })
        #expect(SettingsSearch.search("hotkey", in: entries).contains { $0.page == .shortcuts })
    }

    @Test func quickTogglesAreFoundByTheirChipWords() {
        let hits = SettingsSearch.search("microphone", in: entries)
        #expect(hits.first?.title == SystemToggle.micMute.longTitle)
        #expect(hits.first?.page == .shortcuts)
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
        for case let url as URL in files where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        #expect(!text.isEmpty)
        for row in SettingsSearch.rows {
            #expect(text.contains("\"\(row.title)\""), "no row titled \(row.title) remains")
        }
    }

    @Test func everyPageIsSearchable() {
        #expect(Set(SettingsSearch.pages.map(\.page)) == Set(SettingsStore.Page.allCases))
        for page in SettingsStore.Page.allCases {
            #expect(SettingsSearch.pageKeywords[page] != nil, "\(page) has no search words")
        }
    }
}
