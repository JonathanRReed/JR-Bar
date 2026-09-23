import AppKit
import Carbon.HIToolbox

/// What a key press means to the palette.
enum PaletteKeyCommand: Equatable {
    case up
    case down
    case pageUp
    case pageDown
    /// Return (or the keypad's Enter) with no modifiers.
    case submit
    /// ⎋.
    case cancel
    /// A modified chord a verb may claim — ⌘Return, ⌘K, ⌘⇧H.
    case chord(PaletteShortcut)
    /// Everything else goes to the search field: letters, ⌫, ←/→, and
    /// the text-editing chords (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z).
    case passThrough
}

/// The palette's key map, pure: a key code, the characters and the
/// modifiers in, a command out. The controller routes every key-down
/// through it from one local monitor, so arrows, Return and ⌘K behave
/// the same whether the search field or the action panel's filter has
/// focus — and so the map is testable without synthesising events.
enum PaletteKeys {
    /// Chords that always belong to the text field. No verb may take
    /// them: ⌘C in a search field copies, whatever the row says.
    static let editingChords: Set<PaletteShortcut> = [
        .command("a"), .command("c"), .command("v"), .command("x"), .command("z"),
        .commandShift("z"),
    ]

    static func command(keyCode: UInt16, characters: String?,
                        modifiers flags: NSEvent.ModifierFlags) -> PaletteKeyCommand {
        let modifiers = paletteModifiers(flags)
        switch Int(keyCode) {
        case kVK_UpArrow:
            return modifiers.isEmpty ? .up : .passThrough
        case kVK_DownArrow:
            return modifiers.isEmpty ? .down : .passThrough
        case kVK_PageUp:
            return .pageUp
        case kVK_PageDown:
            return .pageDown
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return modifiers.isEmpty ? .submit : .chord(PaletteShortcut(.returnKey, modifiers))
        case kVK_Escape:
            return .cancel
        case kVK_Delete, kVK_ForwardDelete:
            // Plain ⌫ edits the query; ⌘⌫ is a verb's (Dismiss, Clear).
            return modifiers.contains(.command)
                ? .chord(PaletteShortcut(.delete, modifiers)) : .passThrough
        case kVK_ANSI_P where modifiers == .control:
            return .up
        case kVK_ANSI_N where modifiers == .control:
            return .down
        default:
            break
        }
        // A chord needs ⌘ or ⌃; ⇧ and ⌥ alone type characters.
        guard modifiers.contains(.command) || modifiers.contains(.control),
              let scalar = characters?.lowercased().unicodeScalars.first,
              // Arrow and function keys arrive as private-use scalars —
              // ⌘← is caret movement, not a verb.
              !(0xF700...0xF8FF).contains(scalar.value),
              !CharacterSet.controlCharacters.contains(scalar) else { return .passThrough }
        let chord = PaletteShortcut(.character(Character(scalar)), modifiers)
        return editingChords.contains(chord) ? .passThrough : .chord(chord)
    }

    /// The four modifiers a chord is made of; Caps Lock, Fn and the
    /// numeric-pad bit arrows carry are not part of it.
    static func paletteModifiers(_ flags: NSEvent.ModifierFlags) -> PaletteShortcut.Modifiers {
        var modifiers: PaletteShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
