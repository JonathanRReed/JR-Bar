import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings has seven pages; the twelve older names stay valid as chapters
/// of them, in links, search, the palette and anything saved.
@MainActor
@Suite struct SettingsPagesTests {
    @Test func approvedPages() {
        #expect(SettingsStore.Page.allCases.count == 11)
        #expect(SettingsStore.Page.agents.title == "Providers")
        #expect(SettingsStore.Page.devices.title == "Devices")
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
            "advanced": (.advanced, .advanced),
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
        #expect(doctor?.page == .advanced)
        #expect(doctor.map { store.folds(holding: $0).isEmpty } == true)
    }

    @Test func aRowOnTheFaceOfAPageOpensNoAdvancedFold() {
        let store = SettingsStore(core: CoreModel())
        let row = SettingsSearch.rows.first { $0.title == "Alerts profile" }
        #expect(row.map { store.folds(holding: $0).isEmpty } == true)
    }

    @Test func resettingAPageCoversEveryChapterItHolds() {
        #expect(SettingsStore.Page.agents.resettable.count == 2)
        #expect(SettingsStore.Page.devices.resettable.count == 1)
        #expect(SettingsStore.Page.general.resettable == SettingsStore.Page.general.chapters
            .filter { $0 != .advanced }.compactMap(\.catalogue))
    }
}

extension SettingsPagesTests {
    @Test func providerOrderMovesOneRowAndPreservesTheOthers() {
        let ids = ["claude", "codex", "gemini", "factory"]
        #expect(SettingsProvidersPage.moving("factory", before: "codex", in: ids)
                == ["claude", "factory", "codex", "gemini"])
        #expect(SettingsProvidersPage.moving("claude", before: "gemini", in: ids)
                == ["codex", "claude", "gemini", "factory"])
        #expect(SettingsProvidersPage.moving("missing", before: "codex", in: ids) == ids)
    }

    @Test func privacyAndPowerSearchOpenTheirActualControls() throws {
        let store = SettingsStore(core: CoreModel())
        for title in ["Watch transcripts", "Mic and camera presence", "Keep history", "Check for agent updates"] {
            let entry = try #require(SettingsSearch.rows.first { $0.title == title })
            store.reveal(entry)
            #expect(store.page == .privacy)
            #expect(store.subpage == nil)
        }
        let power = try #require(SettingsSearch.rows.first { $0.title == "Lid closed" })
        store.reveal(power)
        #expect(store.page == .utilities)
        #expect(store.subpage == "keepAwake")
    }

    @Test func t3IntegrationAppearsOnlyWhenInstalled() {
        let store = SettingsStore(core: CoreModel())
        #expect(!store.searchEntries.contains { $0.page == .integrations })
        store.t3Integration.receive(T3CodeStatus(present: false, enabled: true, readOnly: true,
                                                observation: nil, running: false, installed: true))
        #expect(store.searchEntries.contains { $0.page == .integrations })
        #expect(store.providerList.providers.allSatisfy { $0.id != "t3code" })
    }
}


extension SettingsPagesTests {
    @Test func lightingSearchOpensStudio() {
        let store = SettingsStore(core: CoreModel())
        var opened = 0
        store.onOpenEffects = { opened += 1 }
        store.reveal(SettingsSearchEntry(.lighting, "", "Lighting"))
        #expect(opened == 1)
    }
}


extension SettingsPagesTests {
    @Test func pageResetsFollowMovedControls() {
        let document = SettingsDocument(.object([
            "devices": .array([.object(["id": .string("fixture")])]),
        ]))
        let providers = SettingsStore.Page.agents.resetPaths(in: document)
        let privacy = SettingsStore.Page.privacy.resetPaths(in: document)
        let utilities = SettingsStore.Page.utilities.resetPaths(in: document)
        let alerts = SettingsStore.Page.alerts.resetPaths(in: document)
        let devices = SettingsStore.Page.devices.resetPaths(in: document)
        #expect(privacy.contains("presence_enabled"))
        #expect(privacy.contains("transcript_monitoring.claude"))
        #expect(privacy.contains("capacity_history_retention_days"))
        #expect(!providers.contains("transcript_monitoring.claude"))
        #expect(!providers.contains("capacity_history_enabled"))
        #expect(providers.contains("token_history_enabled"))
        #expect(utilities.contains("closed_lid_awake_policy"))
        #expect(!alerts.contains("closed_lid_awake_policy"))
        #expect(!alerts.contains("presence_enabled"))
        #expect(devices.contains("devices.0.brightness"))
        #expect(devices.contains("devices.0.enabled"))
        #expect(!devices.contains("devices.0.provider_pin"))
        #expect(devices.contains("devices.0.red_gain"))
        #expect(!devices.contains("colors.blend_mode"))
        #expect(devices.contains("screen_bar_phase_offset_ms"))
    }
}
