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

    @Test("the keyboard's bar claims only keys aimed at its own window; the pointer's bar only Esc")
    func claimsKeys() {
        let letter = UInt16(kVK_ANSI_K)
        let escape = UInt16(kVK_Escape)
        #expect(Keys.claims(keyCode: letter, keyboard: true, inBar: true))
        #expect(!Keys.claims(keyCode: letter, keyboard: true, inBar: false),
                "a key typed into the palette's field is the palette's")
        #expect(!Keys.claims(keyCode: escape, keyboard: true, inBar: false))
        #expect(Keys.claims(keyCode: escape, keyboard: false, inBar: false), "Esc folds the pointer's bar")
        #expect(!Keys.claims(keyCode: letter, keyboard: false, inBar: true))
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

/// The keyboard's way in, named where the pointer already goes: the ‹'s
/// tooltip and the icon menu's Open Item Bar row.
@Suite("Menu Bar — naming the keyboard's way in")
struct MenuBarKeyboardHintTests {
    private let toggle = MenuBarHotkeyBinding(action: .toggleReveal, keyCode: UInt32(kVK_ANSI_B),
                                              modifiers: UInt32(cmdKey | optionKey), enabled: true)

    @Test("the ‹ says what a click does, and names the hotkey when it is on")
    func tooltip() {
        #expect(MenuBarUtility.chevronToolTip(hiddenCount: 0, toggleHotkey: toggle, style: .bar) == nil)
        #expect(MenuBarUtility.chevronToolTip(hiddenCount: 1, toggleHotkey: nil, style: .bar)
                == "1 hidden item — click for the Item Bar")
        let named = MenuBarUtility.chevronToolTip(hiddenCount: 3, toggleHotkey: toggle, style: .bar)
        #expect(named?.hasPrefix("3 hidden items — click for the Item Bar. ⌥⌘B opens it for the keyboard") == true)
        #expect(MenuBarUtility.chevronToolTip(hiddenCount: 2, toggleHotkey: toggle, style: .inline)
                == "2 hidden items — click to bring them back. ⌥⌘B does the same.")
    }

    @Test("a letter or digit hotkey becomes the menu row's key equivalent; an arrow does not")
    func keyEquivalent() {
        #expect(MenuBarUtility.menuKeyEquivalent(for: toggle) == "b")
        var arrow = toggle
        arrow.keyCode = UInt32(kVK_RightArrow)
        #expect(MenuBarUtility.menuKeyEquivalent(for: arrow) == nil)
        var digit = toggle
        digit.keyCode = UInt32(kVK_ANSI_7)
        #expect(MenuBarUtility.menuKeyEquivalent(for: digit) == "7")
    }
}
