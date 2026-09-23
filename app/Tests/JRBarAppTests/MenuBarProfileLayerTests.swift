import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Profiles as a base map plus per-profile deltas with an active id —
/// switching swaps a layer, so what you hide on your bar survives every
/// profile that does not say otherwise.
@Suite("Menu Bar — profiles as layers over your bar")
struct MenuBarProfileLayerTests {
    private func profile(_ id: String, apps: [String: MenuBarItemSection] = [:],
                         sections: [String: MenuBarItemSection] = [:]) -> MenuBarSettings.Profile {
        MenuBarSettings.Profile(id: id, name: id.capitalized, sections: sections, concealedApps: apps)
    }

    @Test("an app hidden after a profile was saved stays hidden when you switch to it")
    func laterHideSurvivesSwitch() {
        var settings = MenuBarSettings()
        settings.profiles = [profile("work", apps: ["zoom": .shown])]
        settings.concealedApps = ["slack": .hidden]
        MenuBarProfiles.apply(settings.profiles[0], to: &settings)
        let maps = MenuBarProfiles.curatedMaps(settings)
        #expect(maps.concealedApps == ["slack": .hidden, "zoom": .shown])
        // Back to None: your bar, exactly.
        MenuBarProfiles.apply(nil, to: &settings)
        #expect(MenuBarProfiles.curatedMaps(settings).concealedApps == ["slack": .hidden])
    }

    @Test("a delta outranks the base either way — Shown over hidden, Always over shown")
    func deltaOutranksBase() {
        var settings = MenuBarSettings()
        settings.concealedApps = ["slack": .hidden, "notion": .shown]
        settings.profiles = [profile("demo", apps: ["slack": .shown, "notion": .alwaysHidden])]
        settings.curation.activeProfileID = "demo"
        #expect(MenuBarProfiles.curatedMaps(settings).concealedApps
                == ["slack": .shown, "notion": .alwaysHidden])
    }

    @Test("a dangling active id reads as None")
    func danglingActive() {
        var settings = MenuBarSettings()
        settings.concealedApps = ["slack": .hidden]
        settings.curation.activeProfileID = "gone"
        #expect(MenuBarProfiles.activeProfile(in: settings) == nil)
        #expect(MenuBarProfiles.curated(settings) == settings)
    }

    // MARK: Migration

    @Test("snapshot profiles become the deltas that reproduce them exactly, once")
    func migration() {
        var settings = MenuBarSettings()
        settings.concealedApps = ["slack": .hidden, "zoom": .alwaysHidden, "notes": .shown]
        settings.sections = ["Weather": .hidden]
        // Old snapshot: slack shown, zoom hidden, a new app, notes absent (shown).
        let snapshotApps: [String: MenuBarItemSection] = ["slack": .shown, "zoom": .hidden,
                                                          "figma": .hidden]
        settings.profiles = [profile("old", apps: snapshotApps, sections: [:])]
        settings.curation.profileModel = 0
        MenuBarProfiles.migrateToDeltas(&settings)
        #expect(settings.curation.profileModel == MenuBarCuration.currentProfileModel)
        #expect(settings.curation.activeProfileID == nil, "nothing moves at migration")
        #expect(settings.profiles[0].concealedApps
                == ["slack": .shown, "zoom": .hidden, "figma": .hidden])
        #expect(settings.profiles[0].sections == ["Weather": .shown])
        // Laid over today's base the delta is the old snapshot.
        settings.curation.activeProfileID = "old"
        let maps = MenuBarProfiles.curatedMaps(settings)
        for (app, section) in snapshotApps { #expect(maps.concealedApps[app] == section) }
        #expect((maps.concealedApps["notes"] ?? .shown) == .shown)
        #expect((maps.sections["Weather"] ?? .shown) == .shown)
        // Idempotent.
        let once = settings
        MenuBarProfiles.migrateToDeltas(&settings)
        #expect(settings == once)
    }

    @Test("a file from before the layers marks its profiles as snapshots; a fresh one does not")
    func legacyDecode() throws {
        let legacy = #"{"profiles":[{"id":"p","name":"P","concealedApps":{"a":"hidden"}}]}"#
        let old = try JSONDecoder().decode(MenuBarSettings.self, from: Data(legacy.utf8))
        #expect(old.curation.profileModel == 0)
        let fresh = try JSONDecoder().decode(MenuBarSettings.self, from: Data("{}".utf8))
        #expect(fresh.curation.profileModel == MenuBarCuration.currentProfileModel)
        #expect(MenuBarSettings().curation.profileModel == MenuBarCuration.currentProfileModel)
        // Written once migrated, it reads back migrated.
        var migrated = old
        MenuBarProfiles.migrateToDeltas(&migrated)
        let back = try JSONDecoder().decode(MenuBarSettings.self,
                                            from: JSONEncoder().encode(migrated))
        #expect(back.curation.profileModel == MenuBarCuration.currentProfileModel)
        #expect(back == migrated)
    }

    @MainActor
    @Test("the utility migrates a snapshot file on its first apply without moving the bar")
    func utilityMigrates() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["slack": .hidden]
        state.profiles = [profile("old", apps: [:])]
        state.curation.profileModel = 0
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.migrateSectionsIfNeeded()
        #expect(state.curation.profileModel == MenuBarCuration.currentProfileModel)
        #expect(state.concealedApps == ["slack": .hidden])
        // The old snapshot hid nothing: its delta shows slack.
        #expect(state.profiles[0].concealedApps == ["slack": .shown])
    }

    // MARK: Where a pick lands

    @Test("an app pick lands on the profile only when the profile already speaks for the app")
    func appPickRouting() {
        var settings = MenuBarSettings()
        settings.profiles = [profile("work", apps: ["zoom": .hidden])]
        #expect(!MenuBarProfiles.pickTargetsProfile(appID: "zoom", in: settings),
                "no active profile: every pick is your bar's")
        settings.curation.activeProfileID = "work"
        #expect(MenuBarProfiles.pickTargetsProfile(appID: "zoom", in: settings))
        #expect(!MenuBarProfiles.pickTargetsProfile(appID: "slack", in: settings))
        MenuBarProfiles.setDelta(appID: "zoom", to: .shown, profileID: "work", in: &settings)
        #expect(settings.profiles[0].concealedApps == ["zoom": .shown])
        MenuBarProfiles.setDelta(appID: "zoom", to: nil, profileID: "work", in: &settings)
        #expect(settings.profiles[0].concealedApps.isEmpty)
    }

    @MainActor
    @Test("a cover pick through the utility follows the same routing, and a delta keeps its Shown")
    func coverPickRouting() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.profiles = [profile("work", sections: ["Weather": .hidden])]
        state.curation.activeProfileID = "work"
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        // The profile speaks for Weather: its delta takes the pick, and a
        // Shown there stays explicit — it must outrank a hidden base.
        utility.setSection(.shown, for: "Weather")
        #expect(state.profiles[0].sections == ["Weather": .shown])
        #expect(state.sections.isEmpty)
        // It does not speak for Clock-ish helpers: the base takes it.
        utility.setSection(.hidden, for: "Helper")
        #expect(state.sections == ["Helper": .hidden], "your bar, in every profile")
        #expect(state.profiles[0].sections["Helper"] == nil)
        // The editor's "Your bar" drops the delta.
        utility.setProfileDelta(nil, forItem: "Weather", profileID: "work")
        #expect(state.profiles[0].sections.isEmpty)
    }

    // MARK: Cycling and the menu

    @Test("the hotkeys cycle from the active profile, through None, wrapping")
    func cycling() {
        let profiles = [profile("a"), profile("b")]
        #expect(MenuBarProfiles.cycled(from: nil, profiles: profiles, direction: 1) == "a")
        #expect(MenuBarProfiles.cycled(from: "a", profiles: profiles, direction: 1) == "b")
        #expect(MenuBarProfiles.cycled(from: "b", profiles: profiles, direction: 1)
                == MenuBarProfiles.noneID)
        #expect(MenuBarProfiles.cycled(from: nil, profiles: profiles, direction: -1) == "b")
        #expect(MenuBarProfiles.cycled(from: "gone", profiles: profiles, direction: 1) == "a")
    }

    @Test("the icon's menu lists None and every profile, a check on the active one")
    func menuRows() {
        #expect(MenuBarCombinedMenu.profileRows(profiles: [], activeID: nil).isEmpty)
        let rows = MenuBarCombinedMenu.profileRows(profiles: [profile("a"), profile("b")],
                                                   activeID: "b")
        #expect(rows.map(\.title) == ["None", "A", "B"])
        #expect(rows.map(\.active) == [false, false, true])
        let dangling = MenuBarCombinedMenu.profileRows(profiles: [profile("a")], activeID: "gone")
        #expect(dangling.first?.active == true)
    }

    @Test("deleting the active profile leaves your bar")
    func deleteActive() {
        var settings = MenuBarSettings()
        settings.profiles = [profile("a")]
        settings.curation.activeProfileID = "a"
        MenuBarProfiles.delete(id: "a", in: &settings)
        #expect(settings.curation.activeProfileID == nil)
    }
}
