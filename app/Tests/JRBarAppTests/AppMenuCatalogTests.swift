import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The menus' one catalog: More and the right-click menu list the same
/// verbs in the same order, the palette first, Creator Micro only once a
/// pad has been seen; the panel's keys are the keys the menus show.
@Suite("App menu catalog")
@MainActor
struct AppMenuCatalogTests {
    @Test("the palette leads, and Events, What's New and Check for Updates are listed")
    func sections() {
        let sections = AppMenuCatalog.sections(creatorMicro: false)
        #expect(sections.first == [.commandPalette])
        let verbs = sections.flatMap { $0 }
        #expect(verbs.contains(.events))
        #expect(verbs.contains(.whatsNew))
        #expect(verbs.contains(.checkForUpdates))
        #expect(!verbs.contains(.creatorMicro), "a Mac that never had a pad never sees the word")
        #expect(verbs.last == .quit)
        #expect(AppMenuCatalog.sections(creatorMicro: true).flatMap { $0 }.contains(.creatorMicro))
        #expect(Set(verbs).count == verbs.count, "each verb once")
    }

    @Test("Command Palette is ⇧⌘K and Creator Micro has no key")
    func keys() {
        #expect(AppMenuVerb.commandPalette.title == "Command Palette…")
        #expect(AppMenuVerb.commandPalette.key?.character == "k")
        #expect(AppMenuVerb.commandPalette.key?.shift == true)
        #expect(AppMenuVerb.creatorMicro.title == "Creator Micro…")
        #expect(AppMenuVerb.creatorMicro.key == nil)
        let item = AppMenuVerb.commandPalette.menuItem(action: nil, target: nil)
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        let characters = AppMenuVerb.allCases.compactMap { $0.key?.character }
        #expect(Set(characters).count == characters.count, "no two verbs share a key")
    }

    @Test("the panel's ⌘-keys name the catalog's verbs; ⌘K opens the palette with or without ⇧")
    func panelKeys() {
        #expect(AppMenuVerb.verb(forKey: "k") == .commandPalette)
        #expect(AppMenuVerb.verb(forKey: "K") == .commandPalette)
        #expect(AppMenuVerb.verb(forKey: "y") == .history)
        #expect(AppMenuVerb.verb(forKey: "r") == .events)
        #expect(AppMenuVerb.verb(forKey: ",") == .settings)
        #expect(AppMenuVerb.verb(forKey: "d") == nil, "⌘D is the ask's Deny, not a menu verb")
        #expect(AppMenuVerb.verb(forKey: "") == nil)
        #expect(AppMenuVerb.verb(forKey: nil) == nil)
    }

    private func store(deck: DeckState?) -> PanelStore {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(deck: deck)))
        return PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                          screenBarShown: false)
    }

    @Test("Creator Micro is listed once the daemon knows a pad or the pad is switched on")
    func creatorMicroSeen() {
        #expect(!store(deck: nil).hasCreatorMicro)
        #expect(!store(deck: DeckState()).hasCreatorMicro)
        #expect(store(deck: DeckState(device: DeckDevice(serial: "D0CF", connected: false, approved: true))).hasCreatorMicro)
        #expect(store(deck: DeckState(settings: DeckSettings(enabled: true))).hasCreatorMicro)
    }

    @MainActor
    final class Calls {
        var names: [String] = []
    }

    @Test("⌘K folds the panel and opens the palette; Events opens History's journal")
    func verbsRoute() {
        let panel = store(deck: nil)
        let calls = Calls()
        panel.onClose = { calls.names.append("close") }
        panel.onOpenPalette = { calls.names.append("palette") }
        panel.onOpenEvents = { calls.names.append("events") }
        panel.onOpenWhatsNew = { calls.names.append("whats-new") }
        panel.perform(.commandPalette)
        #expect(calls.names == ["close", "palette"])
        calls.names = []
        panel.perform(.events)
        #expect(calls.names == ["close", "events"])
        calls.names = []
        panel.perform(.whatsNew)
        #expect(calls.names == ["close", "whats-new"])
    }
}
