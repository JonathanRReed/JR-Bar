import Testing
@testable import JRBarApp
import JRBarCore

@Suite("Menu Bar profile rename ownership")
struct MenuBarProfileRenameOwnershipTests {
    private func legacySettings() -> MenuBarSettings {
        var settings = MenuBarSettings(enabled: false)
        settings.profiles = [
            MenuBarSettings.Profile(id: "first", name: "Work", concealedApps: ["app": .hidden]),
            MenuBarSettings.Profile(id: "second", name: "work", concealedApps: ["app": .alwaysHidden]),
        ]
        settings.triggerRules = [
            MenuBarTriggerRule(id: "enabled", trigger: .focusEnabled,
                               action: .applyProfile(name: "WORK")),
            MenuBarTriggerRule(id: "disabled", enabled: false, trigger: .focusDisabled,
                               action: .applyProfile(name: "work")),
        ]
        settings.curation.stateRules = [
            MenuBarStateRule(id: "hold", condition: .microphoneLive,
                             effects: [.useProfile(name: "Work")]),
            MenuBarStateRule(id: "disabled-hold", enabled: false, condition: .microphoneLive,
                             effects: [.useProfile(name: "WORK")]),
        ]
        return settings
    }

    private func targetOwner(_ name: String, in settings: MenuBarSettings) -> String? {
        if name.caseInsensitiveCompare(MenuBarProfiles.noneName) == .orderedSame {
            return MenuBarProfiles.noneID
        }
        return settings.profiles.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.id
    }

    @Test("renaming a later duplicate keeps references with their first matching owner")
    func renameNonownerDuplicate() {
        var settings = legacySettings()
        let before = settings
        #expect(targetOwner("WORK", in: settings) == "first")
        MenuBarProfiles.rename(id: "second", to: "Office", in: &settings)
        var expected = before
        expected.profiles[1].name = "Office"
        #expect(settings == expected)
        #expect(targetOwner("WORK", in: settings) == "first")
        if case .applyProfile(let name) = settings.triggerRules[0].action {
            let owner = targetOwner(name, in: settings)
            #expect(owner == "first")
            settings.curation.activeProfileID = owner
        }
        #expect(MenuBarProfiles.curatedMaps(settings).concealedApps == ["app": .hidden])
    }

    @Test("renaming the first duplicate carries its references and layer to its new name")
    func renameOwnerDuplicate() {
        var settings = legacySettings()
        let before = settings
        MenuBarProfiles.rename(id: "first", to: "Office", in: &settings)
        var expected = before
        expected.profiles[0].name = "Office"
        for i in expected.triggerRules.indices {
            expected.triggerRules[i].action = .applyProfile(name: "Office")
            expected.curation.stateRules[i].effects = [.useProfile(name: "Office")]
        }
        #expect(settings == expected)
        #expect(targetOwner("Office", in: settings) == "first")
        #expect(targetOwner("Work", in: settings) == "second")
        if case .applyProfile(let name) = settings.triggerRules[0].action {
            settings.curation.activeProfileID = targetOwner(name, in: settings)
        }
        #expect(MenuBarProfiles.curatedMaps(settings).concealedApps == ["app": .hidden])
    }

    @Test("invalid duplicate renames leave every reference unchanged")
    func rejectedRenames() {
        for id in ["first", "second", "missing"] {
            for name in ["None", "", "   ", "WORK"] {
                var settings = legacySettings()
                let before = settings
                MenuBarProfiles.rename(id: id, to: name, in: &settings)
                #expect(settings == before)
            }
        }
    }

    @Test("malformed None rows never own built-in None references")
    func malformedNone() {
        for id in ["first", "second"] {
            var settings = legacySettings()
            settings.profiles[0].name = "None"
            settings.profiles[1].name = "none"
            settings.triggerRules[0].action = .applyProfile(name: "NONE")
            settings.triggerRules[1].action = .applyProfile(name: "none")
            settings.curation.stateRules[0].effects = [.useProfile(name: "None")]
            settings.curation.stateRules[1].effects = [.useProfile(name: "NONE")]
            let before = settings
            MenuBarProfiles.rename(id: id, to: "Office", in: &settings)
            var expected = before
            let index = id == "first" ? 0 : 1
            expected.profiles[index].name = "Office"
            #expect(settings == expected)
            #expect(targetOwner("NONE", in: settings) == MenuBarProfiles.noneID)
        }
    }
}
