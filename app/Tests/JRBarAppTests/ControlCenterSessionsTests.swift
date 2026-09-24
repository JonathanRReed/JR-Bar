import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Control Center's session list opens through the shared opener,
/// and a refusal lands on the window's status line instead of vanishing.
@Suite("Control Center sessions")
@MainActor
struct ControlCenterSessionsTests {
    @Test("an open that lands says nothing")
    func lands() async {
        let store = DeckStore(core: CoreModel())
        var opened: [String] = []
        store.opener = { id in
            opened.append(id)
            return nil
        }
        await store.openSession("claude:session:a")
        #expect(opened == ["claude:session:a"])
        #expect(store.lastError == nil)
    }

    @Test("a refused open is said on the status line")
    func refusal() async {
        let store = DeckStore(core: CoreModel())
        store.opener = { _ in "Could not open Ship it" }
        await store.openSession("claude:session:a")
        #expect(store.lastError == "Could not open Ship it")
    }

    @Test("the default opener is the shared one: a remote row is refused locally")
    func sharedOpener() async {
        let store = DeckStore(core: CoreModel())
        await store.openSession("remote:studio-mac:claude:session:a")
        #expect(store.lastError == "Running on studio-mac — open it there")
    }
}
