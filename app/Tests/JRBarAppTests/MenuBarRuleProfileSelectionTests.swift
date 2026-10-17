import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

@Suite("Menu Bar rule profile selection")
struct MenuBarRuleProfileSelectionTests {
    @Test("a saved draft follows the selected profile's id through a rename")
    func renamedSelection() throws {
        var settings = MenuBarSettings(enabled: false)
        settings.profiles = [MenuBarSettings.Profile(id: "work", name: "Work")]
        let selection = MenuBarRuleProfileSelection.saved(id: "work")
        MenuBarProfiles.rename(id: "work", to: "Office", in: &settings)
        let resolution = selection.resolve(in: settings)
        #expect(resolution == .profile(name: "Office"))
        #expect(resolution.isAvailable)
        let name = try #require(resolution.name)
        let trigger = MenuBarTriggerAction.applyProfile(name: name)
        let effect = MenuBarRuleEffect.useProfile(name: name)
        let decodedTrigger = try JSONDecoder().decode(MenuBarTriggerAction.self,
            from: JSONEncoder().encode(trigger))
        let decodedEffect = try JSONDecoder().decode(MenuBarRuleEffect.self,
            from: JSONEncoder().encode(effect))
        #expect(decodedTrigger == .applyProfile(name: "Office"))
        #expect(decodedEffect == .useProfile(name: "Office"))
    }

    @Test("deleting a selection does not let a new profile with its old label take over")
    func deletedSelection() {
        var settings = MenuBarSettings(enabled: false)
        settings.profiles = [MenuBarSettings.Profile(id: "old", name: "Work")]
        let selection = MenuBarRuleProfileSelection.saved(id: "old")
        MenuBarProfiles.delete(id: "old", in: &settings)
        #expect(selection.resolve(in: settings) == .unavailable)
        let recreatedID = MenuBarProfiles.saveCurrent(as: "Work", in: &settings)
        #expect(recreatedID != "old")
        let resolution = selection.resolve(in: settings)
        #expect(resolution == .unavailable)
        #expect(!resolution.isAvailable)
        #expect(resolution.name == nil)
    }

    @Test("a later duplicate becomes usable only after it has its own name")
    func duplicateSelection() {
        var settings = MenuBarSettings(enabled: false)
        settings.profiles = [MenuBarSettings.Profile(id: "first", name: "Work"),
                             MenuBarSettings.Profile(id: "second", name: "work")]
        let first = MenuBarRuleProfileSelection.saved(id: "first")
        let second = MenuBarRuleProfileSelection.saved(id: "second")
        #expect(first.resolve(in: settings) == .profile(name: "Work"))
        #expect(second.resolve(in: settings) == .unavailable)
        MenuBarProfiles.rename(id: "second", to: "Office", in: &settings)
        #expect(first.resolve(in: settings) == .profile(name: "Work"))
        #expect(second.resolve(in: settings) == .profile(name: "Office"))
        MenuBarProfiles.rename(id: "first", to: "Studio", in: &settings)
        #expect(first.resolve(in: settings) == .profile(name: "Studio"))
        #expect(second.resolve(in: settings) == .profile(name: "Office"))
    }

    @Test("no profile and built-in None remain different draft choices")
    func builtInChoices() {
        let settings = MenuBarSettings(enabled: false)
        let selections: Set<MenuBarRuleProfileSelection> = [
            .noProfile, .none, .saved(id: "none"), .saved(id: "work"),
        ]
        #expect(selections.count == 4)
        let omitted = MenuBarRuleProfileSelection.noProfile.resolve(in: settings)
        let none = MenuBarRuleProfileSelection.none.resolve(in: settings)
        #expect(omitted == .noProfile)
        #expect(omitted.isAvailable)
        #expect(omitted.name == nil)
        #expect(none == .profile(name: MenuBarProfiles.noneName))
        #expect(none.isAvailable)
        #expect(none.name == MenuBarProfiles.noneName)
    }

    @Test("missing and reserved saved identities cannot become rule targets")
    func malformedSelections() {
        var settings = MenuBarSettings(enabled: false)
        settings.profiles = [
            MenuBarSettings.Profile(id: "", name: "Empty id"),
            MenuBarSettings.Profile(id: MenuBarProfiles.noneID, name: "Reserved id"),
            MenuBarSettings.Profile(id: "reserved-name", name: "nOnE"),
        ]
        for id in ["", MenuBarProfiles.noneID, "reserved-name", "missing"] {
            let resolution = MenuBarRuleProfileSelection.saved(id: id).resolve(in: settings)
            #expect(resolution == .unavailable)
            #expect(!resolution.isAvailable)
            #expect(resolution.name == nil)
        }
        #expect(MenuBarRuleProfileSelection.none.resolve(in: settings)
                == .profile(name: MenuBarProfiles.noneName))
    }
}
