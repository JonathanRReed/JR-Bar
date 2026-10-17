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

    @Test("search names agree across filtering, Return, jumps and refresh")
    func searchNameSelection() throws {
        var named = item("vpn", "Mullvad VPN", title: "Connected")
        named.identifier = "status"
        let key = try #require(MenuBarSearchNames.key(for: named))
        let labeled = MenuBarSearchNames.applying([key: "Private network"], to: [items[0], named])
        let state = Keys.State(query: "private network")
        #expect(Keys.filter(labeled, query: state.query).map(\.id) == ["vpn"])
        #expect(Keys.reduce(state, key: .submit, items: labeled).1 == .trigger(itemID: "vpn"))
        #expect(Keys.reduce(state, key: .jump(1), items: labeled).1 == .trigger(itemID: "vpn"))
        let reordered = Array(labeled.reversed())
        let refreshed = Keys.refreshed(state, from: labeled, to: reordered)
        #expect(Keys.reduce(refreshed, key: .submit, items: reordered).1 == .trigger(itemID: "vpn"))
        let cleared = MenuBarSearchNames.applying([:], to: reordered)
        #expect(Keys.reduce(refreshed, key: .submit, items: cleared).1 == .none)
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

    @Test("inventory refresh keeps the selected item's identity through insertion and removal")
    func refreshSelection() {
        let state = Keys.State(query: "o", selection: 1)
        let visible = Keys.filter(items, query: state.query)
        let selected = visible[1]
        let inserted = [item("new", "New owner")] + items
        let refreshed = Keys.refreshed(state, from: items, to: inserted)
        #expect(refreshed.query == state.query)
        #expect(Keys.reduce(refreshed, key: .submit, items: inserted).1 == .trigger(itemID: selected.id))

        let removed = inserted.filter { $0.id != visible[0].id }
        let next = Keys.refreshed(refreshed, from: inserted, to: removed)
        #expect(Keys.reduce(next, key: .submit, items: removed).1 == .trigger(itemID: selected.id))

        let reordered = Array(removed.reversed())
        let reorderedState = Keys.refreshed(next, from: removed, to: reordered)
        #expect(Keys.reduce(reorderedState, key: .submit, items: reordered).1 == .trigger(itemID: selected.id))
    }

    @Test("an empty search reserves its message and clearing the filter keeps the bar open")
    @MainActor
    func clearEmptySearch() {
        let model = MenuBarBarModel()
        model.items = items
        let state = Keys.State(query: "no-such-item", selection: 3)
        model.keys = state
        #expect(model.visibleItems.isEmpty)
        #expect(model.rowWidths(liveWidths: [:]) == [Keys.searchWidth("no-such-item"), Keys.noMatchesWidth])
        let (cleared, effect) = Keys.reduce(state, key: .clearFilter, items: items)
        #expect(cleared == Keys.State())
        #expect(effect == .none)
        model.keys = cleared
        #expect(model.visibleItems == items)
        #expect(model.selectedID == items.first?.id)
        #expect(Keys.reduce(cleared, key: .clearFilter, items: items).1 == .none)
    }

    @Test("inventory refresh clamps when the selected item disappears and handles empty rows")
    func refreshMissingSelection() {
        let state = Keys.State(selection: 3)
        let reduced = Array(items.prefix(2))
        let refreshed = Keys.refreshed(state, from: items, to: reduced)
        #expect(refreshed.selection == 1)
        #expect(Keys.reduce(refreshed, key: .submit, items: reduced).1 == .trigger(itemID: reduced[1].id))
        let empty = Keys.refreshed(refreshed, from: reduced, to: [])
        #expect(empty.selection == 0)
        #expect(Keys.reduce(empty, key: .submit, items: []).1 == .none)
        #expect(Keys.refreshed(empty, from: [], to: items).selection == 0)
    }

    @Test("modified navigation is not turned into bar actions or swallowed from accessibility")
    func modifiedNavigation() {
        let codes = [kVK_LeftArrow, kVK_RightArrow, kVK_Tab, kVK_Return, kVK_Escape, kVK_Delete]
        let chords: [NSEvent.ModifierFlags] = [.control, .option, [.control, .option], [.control, .option, .shift]]
        for code in codes {
            for chord in chords {
                #expect(Keys.key(keyCode: UInt16(code), characters: nil, modifiers: chord) == nil)
                #expect(!Keys.claims(keyCode: UInt16(code), keyboard: true, inBar: true, modifiers: chord))
                #expect(!Keys.claims(keyCode: UInt16(code), keyboard: false, inBar: true, modifiers: chord))
            }
            #expect(Keys.key(keyCode: UInt16(code), characters: nil, modifiers: .command) == nil)
        }
        #expect(Keys.claims(keyCode: UInt16(kVK_ANSI_Q), keyboard: true, inBar: true, modifiers: .command))
        #expect(!Keys.claims(keyCode: UInt16(kVK_Escape), keyboard: false, inBar: true, modifiers: .command))
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
        #expect(widths.first == Keys.searchWidth("o"))
        model.keys = Keys.State()
        #expect(model.rowWidths(liveWidths: [:]).count == items.count + 1, "keyboard search remains visible")
        model.keys = nil
        #expect(model.rowWidths(liveWidths: [:]).count == items.count, "the pointer's bar keeps its compact row")
    }

    @Test("native text replaces the whole query for committed Unicode text and pasted words")
    func nativeQueryReplacement() {
        let japanese = item("jp", "辞書", title: "日本語")
        let state = Keys.State(query: "romaji", selection: 3)
        let (committed, effect) = Keys.reduce(state, key: .query("日本語"), items: [japanese] + items)
        #expect(committed.query == "日本語")
        #expect(committed.selection == 0)
        #expect(effect == .none)
        #expect(Keys.filter([japanese] + items, query: committed.query).map(\.id) == ["jp"])
        let (pasted, _) = Keys.reduce(committed, key: .query("Mullvad Connected"), items: items)
        #expect(Keys.filter(items, query: pasted.query).map(\.id) == ["vpn"])
    }

    @Test("composition owns navigation and commit keys while ordinary tile actions stay intact")
    func nativeCompositionRouting() {
        let navigation: [Keys.Key] = [.left, .right, .first, .last, .submit, .cancel]
        for key in navigation {
            #expect(Keys.usesNativeTextInput(key, characters: nil, modifiers: [], markedText: true))
            #expect(!Keys.usesNativeTextInput(key, characters: nil, modifiers: [], markedText: false))
        }
        #expect(Keys.usesNativeTextInput(.text("a"), characters: "a", modifiers: [], markedText: false))
        #expect(Keys.usesNativeTextInput(.backspace, characters: nil, modifiers: [], markedText: false))
        #expect(!Keys.usesNativeTextInput(nil, characters: "\u{F704}", modifiers: [], markedText: false))
        #expect(!Keys.usesNativeTextInput(nil, characters: "\u{F704}", modifiers: .option, markedText: false))
        #expect(!Keys.usesNativeTextInput(nil, characters: nil, modifiers: [], markedText: false))
        #expect(Keys.usesNativeTextInput(nil, characters: "´", modifiers: .option, markedText: false))
        #expect(Keys.usesNativeTextInput(nil, characters: "", modifiers: .option, markedText: false))
        for character in ["a", "c", "v", "x", "z"] {
            #expect(Keys.usesNativeTextInput(nil, characters: character, modifiers: .command, markedText: false))
        }
        for marked in [true, false] {
            #expect(!Keys.usesNativeTextInput(nil, characters: "q", modifiers: .command, markedText: marked))
            #expect(!Keys.usesNativeTextInput(nil, characters: "w", modifiers: .command, markedText: marked))
            #expect(!Keys.usesNativeTextInput(.jump(1), characters: "1", modifiers: .command, markedText: marked))
        }
    }

    @Test("an empty keyboard bar reserves space for native search and its empty-state text")
    @MainActor
    func emptyKeyboardSearchLayout() {
        let model = MenuBarBarModel()
        model.keys = Keys.State()
        #expect(model.rowWidths(liveWidths: [:]) == [Keys.searchWidth(""), Keys.noItemsWidth])
        #expect(Keys.searchWidth("") >= 140)
    }
}

/// The keyboard's way in, named where the pointer already goes: the icon
/// menu's Open Item Bar row.
@Suite("Menu Bar — naming the keyboard's way in")
struct MenuBarKeyboardHintTests {
    private let toggle = MenuBarHotkeyBinding(action: .toggleReveal, keyCode: UInt32(kVK_ANSI_B),
                                              modifiers: UInt32(cmdKey | optionKey), enabled: true)

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
