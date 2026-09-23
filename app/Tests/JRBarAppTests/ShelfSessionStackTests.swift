import Foundation
import Testing
@testable import JRBarApp

/// Session-aware stacks: a file under a live session's working folder
/// gathers with that session's other files, and the stack carries the
/// session's name while it lives. Tray persistence is cleared around
/// each test, as the other tray tests do.
@Suite("Shelf session stacks")
@MainActor
struct ShelfSessionStackTests {
    private let key = "jrbar.shelfTray.paths"
    private let fish = ShelfTrayModel.SessionHome(id: "claude:s1", label: "rename-the-fish",
                                                 root: "/tmp/work/fish")

    @Test("a path belongs to the deepest session folder that holds it, never to a too-broad one")
    func home() {
        let outer = ShelfTrayModel.SessionHome(id: "codex:s2", label: "monorepo", root: "/tmp/work/")
        let homes = [outer, fish]
        #expect(ShelfTrayModel.home(for: "/tmp/work/fish/shot.png", in: homes)?.id == "claude:s1")
        #expect(ShelfTrayModel.home(for: "/tmp/work/notes.md", in: homes)?.id == "codex:s2",
                "a trailing slash on the root still counts")
        #expect(ShelfTrayModel.home(for: "/tmp/workshop/a.txt", in: homes) == nil,
                "a sibling that shares a prefix is not inside")
        let broad = [ShelfTrayModel.SessionHome(id: "x", label: "home", root: "/Users/me"),
                     ShelfTrayModel.SessionHome(id: "y", label: "root", root: "/")]
        #expect(ShelfTrayModel.home(for: "/Users/me/Desktop/a.png", in: broad, userHome: "/Users/me") == nil)
    }

    @Test("files from different folders of one session gather into its stack, named for it")
    func gathers() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let tray = ShelfTrayModel()
        tray.sessionHomes = [fish]
        tray.add([URL(fileURLWithPath: "/tmp/work/fish/src/a.swift")])
        tray.add([URL(fileURLWithPath: "/tmp/work/fish/docs/b.md")])
        tray.add([URL(fileURLWithPath: "/tmp/elsewhere/c.png")])
        #expect(tray.entries.count == 2, "one stack for the session, one loose file")
        guard case .stack(let stack) = tray.entries.first else {
            Issue.record("the session's files should stack")
            return
        }
        #expect(stack.items.count == 2)
        #expect(tray.stackName(stack) == "rename-the-fish")
        tray.add([URL(fileURLWithPath: "/tmp/work/fish/c.txt")])
        #expect(tray.entries.first?.items.count == 3, "a third joins the same stack")

        // The session ends: the name goes, the files stay.
        tray.sessionHomes = []
        if case .stack(let after) = tray.entries.first {
            #expect(tray.stackName(after) != "rename-the-fish")
            #expect(after.items.count == 3)
        }
    }
}
