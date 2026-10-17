import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shelf keyboard command")
struct ShelfKeyboardCommandTests {
    @Test("keyboard Shelf has a separate canonical link and leaves the drop toggle unchanged")
    func commandRoundtrip() throws {
        #expect(AppCommand.shelfKeyboard.link.absoluteString == "jrbar://shelf/keyboard")
        #expect(AppCommand.parse(AppCommand.shelfKeyboard.link) == .shelfKeyboard)
        #expect(AppCommand.parse(AppCommand.shelf.link) == .shelf)
        #expect(AppCommand.parse(try #require(URL(string: "jrbar://shelf/keyboard/extra"))) == nil)
        #expect(AppCommand.shelfKeyboard.linkConfirmation == nil)
    }

    @Test("the keyboard action starts unbound and keeps its own command")
    func actionStartsUnbound() throws {
        let action = try #require(AppShortcutCatalog.action(id: "action.shelfKeyboard"))
        #expect(action.title == "Use Shelf with keyboard")
        #expect(action.command == .shelfKeyboard)
        let suite = "jrbar-shelf-key-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = AppHotkeys()
        keys.defaults = defaults
        #expect(keys.chord(for: action.id) == nil)
    }

    @Test("routing reports keyboard refusal and does not invoke the drop toggle")
    func routerRefusalAndSuccess() async {
        let router = AppCommandRouter()
        var toggles = 0
        router.toggleShelf = { toggles += 1; return nil }
        #expect(await router.perform(.shelfKeyboard) == .refused("JR-Bar is still starting."))
        router.useShelfKeyboard = { "The Shelf is turned off." }
        #expect(await router.perform(.shelfKeyboard) == .refused("The Shelf is turned off."))
        router.useShelfKeyboard = { nil }
        #expect(await router.perform(.shelfKeyboard) == .done)
        #expect(toggles == 0)
        #expect(await router.perform(.shelf) == .done)
        #expect(toggles == 1)
    }
}
