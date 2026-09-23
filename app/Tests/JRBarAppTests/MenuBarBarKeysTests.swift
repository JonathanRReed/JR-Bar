import AppKit
import Carbon
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The Item Bar's keyboard: the hotkey's bar walks, filters and presses
/// its tiles without the pointer.
@Suite("Menu Bar — the Item Bar's keyboard")
struct MenuBarBarKeysTests {
    typealias Keys = MenuBarBarKeys

    private func item(_ id: String, _ owner: String, title: String? = nil) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: owner,
                    bounds: CGRect(x: 0, y: 0, width: 24, height: 24),
                    title: title, windowID: 1, bundleID: "com.example.\(id)")
    }

    private var items: [MenuBarItem] {
        [item("1p", "1Password"), item("vpn", "Mullvad VPN", title: "Connected"),
         item("dropbox", "Dropbox"), item("zoom", "zoom.us")]
    }

    @Test("arrows walk the row and stop at its ends; Home and End jump")
    func walk() {
        var state = Keys.State()
        (state, _) = Keys.reduce(state, key: .left, items: items)
        #expect(state.selection == 0)
        for _ in 0..<10 { (state, _) = Keys.reduce(state, key: .right, items: items) }
        #expect(state.selection == 3)
        (state, _) = Keys.reduce(state, key: .first, items: items)
        #expect(state.selection == 0)
        (state, _) = Keys.reduce(state, key: .last, items: items)
        #expect(state.selection == 3)
    }

    @Test("typing filters by app and title, every word, ignoring case and accents")
    func filter() {
        #expect(Keys.filter(items, query: "").count == 4)
        #expect(Keys.filter(items, query: "drop").map(\.id) == ["dropbox"])
        #expect(Keys.filter(items, query: "VPN conn").map(\.id) == ["vpn"])
        #expect(Keys.filter(items, query: "cönnected").map(\.id) == ["vpn"])
        #expect(Keys.filter(items, query: "nothing").isEmpty)
    }

    @Test("Return presses the selected tile of the filtered row")
    func submit() {
        var state = Keys.State()
        (state, _) = Keys.reduce(state, key: .text("o"), items: items)
        #expect(state.query == "o" && state.selection == 0)
        (state, _) = Keys.reduce(state, key: .right, items: items)
        let visible = Keys.filter(items, query: "o")
        let (_, effect) = Keys.reduce(state, key: .submit, items: items)
        #expect(effect == .trigger(itemID: visible[1].id))
        // A typed filter that leaves nothing presses nothing.
        let (_, none) = Keys.reduce(Keys.State(query: "qqq"), key: .submit, items: items)
        #expect(none == .none)
    }

    @Test("⌘1–⌘9 press that place in the row; past its end is nothing")
    func jump() {
        #expect(Keys.reduce(Keys.State(), key: .jump(2), items: items).1 == .trigger(itemID: "vpn"))
        #expect(Keys.reduce(Keys.State(), key: .jump(9), items: items).1 == .none)
    }

    @Test("Esc clears the filter first, then folds; Delete edits the filter")
    func cancelAndBackspace() {
        var state = Keys.State(query: "dr", selection: 0)
        (state, _) = Keys.reduce(state, key: .backspace, items: items)
        #expect(state.query == "d")
        let (cleared, effect) = Keys.reduce(state, key: .cancel, items: items)
        #expect(cleared == Keys.State() && effect == .none)
        #expect(Keys.reduce(cleared, key: .cancel, items: items).1 == .close)
        #expect(Keys.reduce(cleared, key: .backspace, items: items).0 == cleared)
    }

    @Test("key events map to bar keys; chords and function keys are left alone")
    func keyMapping() {
        #expect(Keys.key(keyCode: UInt16(kVK_LeftArrow), characters: "\u{F702}", modifiers: []) == .left)
        #expect(Keys.key(keyCode: UInt16(kVK_Tab), characters: "\t", modifiers: [.shift]) == .left)
        #expect(Keys.key(keyCode: UInt16(kVK_Tab), characters: "\t", modifiers: []) == .right)
        #expect(Keys.key(keyCode: UInt16(kVK_Return), characters: "\r", modifiers: []) == .submit)
        #expect(Keys.key(keyCode: UInt16(kVK_Escape), characters: "\u{1B}", modifiers: []) == .cancel)
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_3), characters: "3", modifiers: [.command]) == .jump(3))
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_0), characters: "0", modifiers: [.command]) == nil)
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_D), characters: "d", modifiers: []) == .text("d"))
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_D), characters: "D", modifiers: [.shift]) == .text("D"))
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_D), characters: "d", modifiers: [.command]) == nil)
        #expect(Keys.key(keyCode: UInt16(kVK_ANSI_D), characters: "d", modifiers: [.control]) == nil)
        #expect(Keys.key(keyCode: UInt16(kVK_F5), characters: "\u{F708}", modifiers: []) == nil)
    }

    @MainActor
    @Test("the keyboard's bar lists what the filter leaves, selects inside it, and makes room for the chip")
    func model() {
        let model = MenuBarBarModel()
        model.items = items
        #expect(model.selectedID == nil, "a pointer's bar selects nothing")
        model.keys = Keys.State(query: "o", selection: 10)
        let visible = Keys.filter(items, query: "o")
        #expect(model.visibleItems.map(\.id) == visible.map(\.id))
        #expect(model.selectedID == visible.last?.id, "an out-of-range selection clamps")
        let widths = model.rowWidths(liveWidths: [:])
        #expect(widths.count == visible.count + 1)
        #expect(widths.first == Keys.chipWidth("o"))
        model.keys = Keys.State()
        #expect(model.rowWidths(liveWidths: [:]).count == items.count, "no filter, no chip")
    }
}
