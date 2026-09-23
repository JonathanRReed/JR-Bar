import AppKit
import ApplicationServices
import JRBarCore
import OSLog

/// One leaf of an app's menu bar, as the palette lists it.
struct AppMenuEntry: Sendable, Equatable {
    /// The way back to the element at press time: the menu bar item's
    /// index, then each item's index down the submenus. Elements are not
    /// held across the open — an app that rebuilt a menu in between
    /// simply answers the path with nothing.
    let indexPath: [Int]
    /// The menus above the item ("File", "Export").
    let parents: [String]
    let title: String
    /// The item's key equivalent as the menu draws it ("⇧⌘S").
    let shortcut: String?

    /// "File › Export" — the row's subtitle.
    var path: String { parents.joined(separator: " › ") }
}

/// Raycast's Search Menu Items, native: the frontmost app's menus read
/// through Accessibility off the main actor, and a pick pressed with
/// `AXPress`. The palette never activates, so the app you were in stays
/// in front and the item runs there — no pointer move, no synthetic
/// click, the same press the Item Bar's tiles use.
enum AppMenuReader {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "palette")
    /// Leaves read at most — Xcode's menus run to a few hundred.
    nonisolated static let limit = 800
    /// Submenu levels followed below the menu bar's own menus.
    nonisolated static let depth = 4
    /// One app that stops answering must not hold the read.
    nonisolated static let messagingTimeout: Float = 0.3

    /// Every enabled leaf of `pid`'s menu bar, in menu order; stops at
    /// `limit` or `deadline`, whichever comes first.
    nonisolated static func entries(pid: pid_t, deadline: Date) -> [AppMenuEntry] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [AppMenuEntry] = []
        for (index, barItem) in children(bar).enumerated() {
            guard out.count < limit, Date() < deadline else { break }
            guard let title = string(barItem, kAXTitleAttribute),
                  let menu = children(barItem).first else { continue }
            walk(menu, path: [index], parents: [title], level: 0, deadline: deadline, into: &out)
        }
        return out
    }

    private nonisolated static func walk(_ menu: AXUIElement, path: [Int], parents: [String], level: Int,
                                         deadline: Date, into out: inout [AppMenuEntry]) {
        for (index, item) in children(menu).enumerated() {
            guard out.count < limit, Date() < deadline else { return }
            let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
                              kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
                              kAXMenuItemCmdGlyphAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, [], &values) == .success,
                  let list = values as? [Any], list.count == 6 else { continue }
            // A separator has no title; neither does a custom view row.
            guard let title = list[0] as? String, !title.isEmpty else { continue }
            if let submenu = (list[2] as? [AXUIElement])?.first {
                if level < depth {
                    walk(submenu, path: path + [index], parents: parents + [title], level: level + 1,
                         deadline: deadline, into: &out)
                }
                continue
            }
            guard (list[1] as? Bool) ?? false else { continue }
            out.append(AppMenuEntry(
                indexPath: path + [index], parents: parents, title: title,
                shortcut: shortcutText(char: list[3] as? String, modifiers: list[4] as? Int,
                                       glyph: list[5] as? Int)))
        }
    }

    /// Re-find the item by its path and press it. False when the path
    /// no longer leads to an item (the app rebuilt its menus).
    @discardableResult
    nonisolated static func press(pid: pid_t, indexPath: [Int]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard indexPath.count >= 2, let bar = element(app, kAXMenuBarAttribute) else { return false }
        let barItems = children(bar)
        guard barItems.indices.contains(indexPath[0]),
              var menu = children(barItems[indexPath[0]]).first else { return false }
        var item: AXUIElement?
        for (step, index) in indexPath.dropFirst().enumerated() {
            let items = children(menu)
            guard items.indices.contains(index) else { return false }
            item = items[index]
            if step < indexPath.count - 2 {
                guard let next = children(items[index]).first else { return false }
                menu = next
            }
        }
        guard let item else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// A key equivalent the way a menu draws it: ⌃⌥⇧⌘ then the key. The
    /// modifier word is Carbon's menu bitmask — ⌘ unless its "no
    /// command" bit is set; a special key arrives as a glyph code.
    nonisolated static func shortcutText(char: String?, modifiers: Int?, glyph: Int?) -> String? {
        let key: String
        if let char, !char.isEmpty, char.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            key = char.uppercased()
        } else if let glyph, let name = glyphNames[glyph] {
            key = name
        } else {
            return nil
        }
        let bits = modifiers ?? 0
        var text = ""
        if bits & 4 != 0 { text += "⌃" }
        if bits & 2 != 0 { text += "⌥" }
        if bits & 1 != 0 { text += "⇧" }
        if bits & 8 == 0 { text += "⌘" }
        return text + key
    }

    /// The Carbon menu glyphs a key equivalent commonly uses.
    nonisolated static let glyphNames: [Int: String] = [
        0x02: "⇥", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
        0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]

    // MARK: AX plumbing

    private nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        (value(element, attribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The frontmost app's menus as palette rows — listed only once you
/// type, so the home list stays JR-Bar's own. The read starts on the
/// first query of an open (not at the keystroke that opened it) and is
/// reused for the rest of that open.
@MainActor
final class AppMenuPaletteSource: PaletteSource {
    /// The app whose menus to read — the frontmost at open, never
    /// JR-Bar itself. Injected for tests.
    var frontmost: @MainActor () -> MenuApp? = {
        NSWorkspace.shared.frontmostApplication.map {
            MenuApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier)
        }
    }
    /// Accessibility, re-checked each open.
    var trusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
    /// The reader, off the main actor. Injected for tests.
    var read: @Sendable (pid_t) async -> [AppMenuEntry] = { pid in
        await Task.detached(priority: .userInitiated) {
            AppMenuReader.entries(pid: pid, deadline: Date().addingTimeInterval(1.5))
        }.value
    }
    /// The press, off the main actor too: a menu action that opens a
    /// modal answers late, and JR-Bar's main thread must not wait on it.
    var press: @Sendable (pid_t, [Int]) -> Void = { pid, path in
        Task.detached(priority: .userInitiated) {
            if !AppMenuReader.press(pid: pid, indexPath: path) {
                AppMenuReader.log.notice("menu item press found nothing at \(path, privacy: .public)")
            }
        }
    }

    /// Menu rows shown for a query at most.
    static let limit = 8
    /// Two letters before menus are searched: one letter matches most
    /// of any app's menu.
    static let minimumQuery = 2

    /// The app a read is for.
    struct MenuApp: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    private var target: MenuApp?
    private var loading: Task<[AppMenuEntry], Never>?

    init() {}

    func prepare() {
        loading = nil
        target = nil
        guard trusted(), let app = frontmost(),
              app.pid != ProcessInfo.processInfo.processIdentifier else { return }
        target = app
    }

    func items() -> [PaletteItem] { [] }

    func results(for query: String) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= Self.minimumQuery, let target else { return [] }
        let task: Task<[AppMenuEntry], Never>
        if let loading {
            task = loading
        } else {
            let read = self.read
            task = Task { await read(target.pid) }
            loading = task
        }
        let entries = await task.value
        return Self.items(for: trimmed, entries: entries, app: target, press: press)
    }

    /// The best matches of `query` among `entries`, as rows: the item's
    /// own title counts in full, "File Export" (the path and the title)
    /// at four fifths, so "exp pdf" finds File › Export as PDF….
    static func items(for query: String, entries: [AppMenuEntry],
                      app: MenuApp,
                      press: @escaping @Sendable (pid_t, [Int]) -> Void) -> [PaletteItem] {
        let section = PaletteSection(id: "appMenu", title: "\(app.name) Menus", order: 95)
        let ids = rowIDs(for: entries, app: app)
        let scored = entries.enumerated().compactMap { offset, entry -> (AppMenuEntry, Int, Int)? in
            let title = MenuBarCommands.score(query, entry.title)
            let full = MenuBarCommands.score(query, "\(entry.path) \(entry.title)").map { $0 * 4 / 5 }
            guard let best = [title, full].compactMap({ $0 }).max(),
                  best >= 3 * query.filter({ !$0.isWhitespace }).count else { return nil }
            return (entry, best, offset)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(limit)
            .map { entry, _, offset in
                let path = entry.indexPath
                let pid = app.pid
                return PaletteItem(
                    id: ids[offset],
                    title: entry.title, subtitle: entry.path,
                    icon: .app(pid: pid, bundleID: app.bundleID),
                    tags: entry.shortcut.map { [PaletteTag(text: $0)] } ?? [],
                    kind: "Menu Item", section: section,
                    actions: [PaletteAction(id: "press", title: "Choose", symbol: "filemenu.and.selection") {
                        press(pid, path)
                        return nil
                    }])
            }
    }

    /// One id per entry, in menu order: `menu.<app>.<path>/<title>`, and
    /// for a second item with the same path and title — two "Untitled"
    /// windows in the Window menu — the same with `#2`, `#3`, so every
    /// row the list draws and the selection follows is its own. Read
    /// over every entry, not a query's matches, so an id never changes
    /// with the words typed.
    static func rowIDs(for entries: [AppMenuEntry], app: MenuApp) -> [String] {
        var seen: [String: Int] = [:]
        return entries.map { entry in
            let base = "menu.\(app.bundleID ?? app.name).\(entry.path)/\(entry.title)"
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            return count == 1 ? base : "\(base)#\(count)"
        }
    }
}
