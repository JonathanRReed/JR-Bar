import AppKit
import SwiftUI

/// The verbs the panel's More menu and the status item's right-click
/// menu share: one list, one order, one set of words and keys, so the
/// two menus never drift apart. The panel's key monitor reads the same
/// keys, so a key a menu shows is a key that works while the panel is
/// key.
enum AppMenuVerb: String, CaseIterable, Identifiable, Sendable {
    case commandPalette
    case history
    /// History's Events tab: the journal, where Event Replay lives now.
    case events
    case overview
    case usageCenter
    case effects
    /// The Creator Micro 2's window (it was "Control Center", ⌘K).
    case creatorMicro
    case whatsNew
    case checkForUpdates
    case settings
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: return "Command Palette…"
        case .history: return "History…"
        case .events: return "Events…"
        case .overview: return "Overview…"
        case .usageCenter: return "Usage Center…"
        case .effects: return "Effect Studio…"
        case .creatorMicro: return "Creator Micro…"
        case .whatsNew: return "What's New…"
        case .checkForUpdates: return "Check for Updates…"
        case .settings: return "Settings…"
        case .quit: return "Quit JR-Bar"
        }
    }

    /// The key, always with ⌘; `shift` adds ⇧. No two verbs share a
    /// character, so the panel matches on the character alone and ⌘K
    /// opens the palette as ⇧⌘K does.
    var key: (character: Character, shift: Bool)? {
        switch self {
        case .commandPalette: return ("k", true)
        case .history: return ("y", false)
        case .events: return ("r", false)
        case .overview: return ("o", false)
        case .usageCenter: return ("u", false)
        case .settings: return (",", false)
        case .quit: return ("q", false)
        case .effects, .creatorMicro, .whatsNew, .checkForUpdates: return nil
        }
    }

    /// The verb a ⌘-key names, whatever else is held.
    static func verb(forKey characters: String?) -> AppMenuVerb? {
        guard let characters, characters.count == 1, let character = characters.lowercased().first else { return nil }
        return allCases.first { $0.key?.character == character }
    }

    /// The key as SwiftUI's `.keyboardShortcut` takes it.
    var shortcut: KeyboardShortcut? {
        key.map { KeyboardShortcut(KeyEquivalent($0.character), modifiers: $0.shift ? [.command, .shift] : .command) }
    }

    /// An AppKit menu item for the verb, its key set; the caller names
    /// the action and the target.
    func menuItem(action: Selector?, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key.map { String($0.character) } ?? "")
        if let key { item.keyEquivalentModifierMask = key.shift ? [.command, .shift] : .command }
        item.target = target
        item.representedObject = rawValue
        return item
    }
}

enum AppMenuCatalog {
    /// Both menus' verbs, section by section, top to bottom. Creator
    /// Micro is listed once a pad has been seen (`PanelStore.hasCreatorMicro`).
    static func sections(creatorMicro: Bool) -> [[AppMenuVerb]] {
        [
            [.commandPalette],
            [.history, .events, .overview, .usageCenter, .effects] + (creatorMicro ? [.creatorMicro] : []),
            [.whatsNew, .checkForUpdates, .settings],
            [.quit],
        ]
    }
}
