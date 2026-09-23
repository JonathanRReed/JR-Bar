import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The card's layout editor: three rows of the bar's own glyphs, and a
/// drag between them is the same pick the pickers make.
@Suite("Menu Bar — the layout editor")
struct MenuBarLayoutEditorTests {
    private func item(_ id: String, _ owner: String, bundle: String?, x: Double) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: owner,
                    bounds: CGRect(x: x, y: 0, width: 24, height: 24),
                    title: nil, windowID: 1, bundleID: bundle)
    }

    private func subject(_ item: MenuBarItem) -> MenuBarProfileSubject {
        MenuBarProfileSubject(key: item.bundleID ?? item.id, isApp: item.bundleID != nil,
                              title: item.ownerName, item: item)
    }

    @Test("three rows, always, each in bar order — an empty row is still a place to drop")
    func rows() {
        let a = subject(item("a", "A", bundle: "com.a", x: 10))
        let b = subject(item("b", "B", bundle: "com.b", x: 40))
        let c = subject(item("c", "C", bundle: "com.c", x: 70))
        let sections: [String: MenuBarItemSection] = ["a": .hidden, "b": .shown, "c": .hidden]
        let rows = MenuBarLayoutEditor.rows(subjects: [a, b, c]) { sections[$0.item.id] ?? .shown }
        #expect(rows.map(\.section) == [.shown, .hidden, .alwaysHidden])
        #expect(rows[0].subjects.map(\.item.id) == ["b"])
        #expect(rows[1].subjects.map(\.item.id) == ["a", "c"])
        #expect(rows[2].subjects.isEmpty)
    }

    @Test("a drop moves only the editor's own tiles, once each")
    func drops() {
        let a = subject(item("a", "A", bundle: "com.a", x: 10))
        let b = subject(item("b", "B", bundle: nil, x: 40))
        #expect(MenuBarLayoutEditor.movableIDs(["a", "stray text", "a", "b"], subjects: [a, b]) == ["a", "b"])
        #expect(MenuBarLayoutEditor.movableIDs(["https://example.com"], subjects: [a, b]).isEmpty)
    }
}
