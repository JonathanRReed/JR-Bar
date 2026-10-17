import Foundation
import Testing
@testable import JRBarApp

@Suite("Menu Bar search names")
struct MenuBarSearchNamesTests {
    private func item(_ id: String = "item", bundle: String? = "com.example.app",
                      identifier: String? = "status", pid: Int32 = 1,
                      title: String? = "Original") -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: "Example",
                    bounds: CGRect(x: 0, y: 0, width: 24, height: 24),
                    title: title, windowID: 1, identifier: identifier, bundleID: bundle)
    }

    @Test func requiresExplicitIdentity() {
        #expect(MenuBarSearchNames.key(for: item(bundle: nil)) == nil)
        #expect(MenuBarSearchNames.key(for: item(identifier: nil)) == nil)
        #expect(MenuBarSearchNames.key(for: item(bundle: "")) == nil)
        #expect(MenuBarSearchNames.key(for: item(identifier: "")) == nil)
        #expect(MenuBarSearchNames.key(for: item(bundle: "a", identifier: "bc")) !=
                MenuBarSearchNames.key(for: item(bundle: "ab", identifier: "c")))
    }

    @Test func survivesRelaunchAndTitleChange() throws {
        let original = item()
        let key = try #require(MenuBarSearchNames.key(for: original))
        let relaunched = item("new-id", pid: 99, title: "Changed")
        let labeled = MenuBarSearchNames.applying([key: "Network"], to: [relaunched])
        #expect(labeled.first?.searchName == "Network")
        #expect(labeled.first?.id == "new-id")
        #expect(labeled.first?.title == "Changed")
    }

    @Test func collisionsAcrossInventoryRefuseNames() throws {
        let hidden = item("hidden")
        let shown = item("shown", pid: 2)
        let key = try #require(MenuBarSearchNames.key(for: hidden))
        #expect(MenuBarSearchNames.uniqueKey(for: hidden, inventory: [hidden, shown]) == nil)
        #expect(MenuBarSearchNames.applying([key: "Network"], to: [hidden],
                                           inventory: [shown, hidden]).first?.searchName == nil)
    }

    @Test func groupedCommandsKeepAliasesWithTheirOpenActions() throws {
        let first = item("first", identifier: "first-status")
        let later = item("later", identifier: "later-status")
        let firstKey = try #require(MenuBarSearchNames.key(for: first))
        let laterKey = try #require(MenuBarSearchNames.key(for: later))
        let labeled = MenuBarSearchNames.applying(
            [firstKey: "Network", laterKey: "Downloads"], to: [first, later])
        let row = MenuBarCommands.appRow(key: "com.example.app", section: .hidden, items: labeled)
        #expect(row.keywords.contains("Network"))
        #expect(!row.keywords.contains("Downloads"))
        #expect(row.verbs.first?.action == .openItem(itemID: "first"))
        let laterOpen = try #require(row.verbs.first { $0.title == "Open Downloads" })
        #expect(laterOpen.action == .openItem(itemID: "later"))
    }

    @Test func normalizesAndClears() throws {
        #expect(MenuBarSearchNames.normalized("  Network  ") == "Network")
        #expect(MenuBarSearchNames.normalized(String(repeating: "é", count: 100))?.count == 96)
        #expect(MenuBarSearchNames.normalized("bad\nname") == nil)
        #expect(MenuBarSearchNames.normalized("bad\u{0}name") == nil)
        let original = item()
        let key = try #require(MenuBarSearchNames.key(for: original))
        let labeled = MenuBarSearchNames.applying([key: "Network"], to: [original])
        #expect(MenuBarSearchNames.applying([:], to: labeled).first?.searchName == nil)
        #expect(MenuBarSearchNames.applying([key: "  "], to: labeled).first?.searchName == nil)
    }
}
