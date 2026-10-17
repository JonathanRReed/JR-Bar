import Foundation
import Testing
@testable import JRBarCore

@Suite struct MenuBarItemHotkeyCodecTests {
    private func target(_ bundle: String = "com.example.fixture") throws -> MenuBarItemShortcutTarget {
        try #require(MenuBarItemShortcutTarget(bundleID: bundle, selector: .identifier("status")))
    }

    @Test func absentFieldKeepsOldBindings() throws {
        let old = MenuBarHotkeyBinding(action: .showAll, keyCode: 12, modifiers: 6144, enabled: false)
        let encoded = try JSONEncoder().encode(MenuBarSettings(hotkeyBindings: [old]))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "itemHotkeyBindings")
        let settings = try JSONDecoder().decode(MenuBarSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.itemHotkeyBindings.isEmpty)
        #expect(settings.hotkeyBindings == [old])
    }

    @Test func corruptRowsDropIndependentlyAndDuplicatesDropEveryClaimant() throws {
        let first = MenuBarItemHotkeyBinding(target: try target(), displayName: "Fixture", keyCode: 12, modifiers: 6144)
        let second = MenuBarItemHotkeyBinding(target: try target("com.example.other"), displayName: "Other", keyCode: 13, modifiers: 6144)
        let firstObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let secondObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(second))
        let rows: [Any] = [firstObject, ["broken": true], secondObject, firstObject]
        let data = try JSONSerialization.data(withJSONObject: ["itemHotkeyBindings": rows])
        let settings = try JSONDecoder().decode(MenuBarSettings.self, from: data)
        #expect(settings.itemHotkeyBindings == [second])
        #expect(try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func identityMustBeExplicitAndRegistryIDsCannotCollide() throws {
        #expect(MenuBarItemShortcutTarget(bundleID: " ", selector: .soleItem) == nil)
        #expect(MenuBarItemShortcutTarget(bundleID: "com.example.fixture", selector: .identifier("")) == nil)
        let one = try #require(MenuBarItemShortcutTarget(bundleID: "a.b", selector: .identifier("c")))
        let two = try #require(MenuBarItemShortcutTarget(bundleID: "a", selector: .identifier("b.c")))
        #expect(one.registryID != two.registryID)
        #expect(one.registryID != MenuBarItemShortcutTarget(bundleID: "a.b", selector: .soleItem)?.registryID)
    }

    @Test func bindingEditsDoNotReapplyHiding() throws {
        let previous = MenuBarSettings()
        var edited = previous
        edited.itemHotkeyBindings = [MenuBarItemHotkeyBinding(target: try target(), displayName: "Fixture", keyCode: 12, modifiers: 6144)]
        #expect(!edited.requiresReapply(comparedTo: previous))
        edited.enabled.toggle()
        #expect(edited.requiresReapply(comparedTo: previous))
    }
}
