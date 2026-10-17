import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings has seven pages; the twelve older names stay valid as chapters
/// of them, in links, search, the palette and anything saved.
@MainActor
@Suite struct SettingsPagesTests {
    @Test func sevenPagesAtMost() {
        #expect(SettingsStore.Page.allCases.count <= 7)
    }

    @Test func everyChapterSitsOnExactlyOnePage() {
        let listed = SettingsStore.Page.allCases.flatMap(\.chapters)
        #expect(listed.count == SettingsStore.Chapter.allCases.count, "no chapter on two pages")
        #expect(Set(listed) == Set(SettingsStore.Chapter.allCases), "no chapter left off")
        for page in SettingsStore.Page.allCases {
            for chapter in page.chapters { #expect(chapter.page == page) }
        }
    }

    @Test func everyOldPageNameStillLands() {
        let old: [String: (SettingsStore.Page, SettingsStore.Chapter?)] = [
            "general": (.general, .general), "agents": (.agents, .agents), "usage": (.agents, .usage),
            "devices": (.devices, .devices), "lighting": (.devices, .lighting),
            "utilities": (.utilities, .utilities), "toys": (.utilities, .toys),
            "notifications": (.alerts, .notifications), "sounds": (.alerts, .sounds),
            "shortcuts": (.shortcuts, .shortcuts), "remote": (.remote, .remote),
            "advanced": (.general, .advanced),
        ]
        for (name, expected) in old {
            let found = SettingsStore.Page.destination(named: name)
            #expect(found?.page == expected.0, "\(name) lands on \(expected.0)")
            #expect(found?.chapter == expected.1)
            #expect(SettingsStore.Page.destination(named: name.uppercased())?.page == expected.0)
        }
        #expect(SettingsStore.Page.destination(named: "alerts")?.page == .alerts)
        #expect(SettingsStore.Page.destination(named: "alerts")?.chapter == nil)
        #expect(SettingsStore.Page.destination(named: "nonsense") == nil)
    }

    @Test func linksAcceptEveryPageAndChapter() {
        for name in SettingsStore.Page.linkNames {
            #expect(AppCommand.parse(URL(string: "jrbar://settings/\(name)")!) == .settings(page: name))
        }
        #expect(AppCommand.parse(URL(string: "jrbar://settings/nonsense")!) == nil)
    }

    @Test func openingANameOrChapterPicksThePageAndAsksToScroll() {
        let store = SettingsStore(core: CoreModel())
        let before = store.revealRequest
        store.open(named: "usage")
        #expect(store.page == .agents)
        #expect(store.pendingChapter == .usage)
        #expect(store.revealRequest == before + 1)
        store.open(named: "alerts")
        #expect(store.page == .alerts)
        store.open(named: "who knows")
        #expect(store.page == .general, "an unknown name opens General")
        store.open(chapter: .sounds)
        #expect(store.page == .alerts && store.pendingChapter == .sounds)
    }

    @Test func aChapterBelowTheTopOfItsPageKnowsWhereItStarts() {
        for chapter in SettingsStore.Chapter.allCases where chapter.page.chapters.first != chapter {
            #expect(chapter.anchor != nil, "\(chapter) is not the first on its page, so it needs an anchor")
        }
    }

    @Test func everyGroupNamedAsAdvancedIsAGroupSearchLists() {
        for (chapter, groups) in SettingsFold.advancedGroups {
            for group in groups {
                #expect(SettingsSearch.rows.contains { $0.chapter == chapter && $0.group == group },
                        "\(chapter) › \(group) is behind Advanced but search lists no row in it")
            }
        }
    }

    @Test func aHitBehindAdvancedOpensItsPagesFold() {
        let store = SettingsStore(core: CoreModel())
        for (chapter, groups) in SettingsFold.advancedGroups {
            for group in groups {
                guard let row = SettingsSearch.rows.first(where: { $0.chapter == chapter && $0.group == group }) else { continue }
                #expect(store.folds(holding: row).contains(SettingsFold.advanced(chapter.page)),
                        "\(row.title) hides behind Advanced without a fold to open")
            }
        }
        let doctor = SettingsSearch.rows.first { $0.title == "Doctor" }
        #expect(doctor.map { store.folds(holding: $0).contains(SettingsFold.advanced(.general)) } == true)
    }

    @Test func aRowOnTheFaceOfAPageOpensNoAdvancedFold() {
        let store = SettingsStore(core: CoreModel())
        let row = SettingsSearch.rows.first { $0.title == "Alerts profile" }
        #expect(row.map { store.folds(holding: $0).isEmpty } == true)
    }

    @Test func resettingAPageCoversEveryChapterItHolds() {
        #expect(SettingsStore.Page.agents.resettable.count == 2)
        #expect(SettingsStore.Page.devices.resettable.count == 2)
        #expect(SettingsStore.Page.general.resettable == SettingsStore.Page.general.chapters
            .filter { $0 != .advanced }.compactMap(\.catalogue))
    }
}
