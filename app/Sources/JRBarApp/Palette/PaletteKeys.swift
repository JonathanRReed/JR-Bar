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
              let scalar = chordScalar(keyCode: keyCode, characters: characters),
              // Arrow and function keys arrive as private-use scalars —
              // ⌘← is caret movement, not a verb.
              !(0xF700...0xF8FF).contains(scalar.value),
              !CharacterSet.controlCharacters.contains(scalar) else { return .passThrough }
        let chord = PaletteShortcut(.character(Character(scalar)), modifiers)
        return editingChords.contains(chord) ? .passThrough : .chord(chord)
    }

    /// The character a chord is named by. On a layout whose letters are not
    /// Latin (Cyrillic, Greek, Arabic) ⌘K arrives as that layout's letter,
    /// and the verbs are named by the Latin one on the same key, so the
    /// key's position decides there.
    static func chordScalar(keyCode: UInt16, characters: String?) -> Unicode.Scalar? {
        guard let scalar = characters?.lowercased().unicodeScalars.first else { return nil }
        if scalar.isASCII { return scalar }
        if let latin = latinKeys[Int(keyCode)] { return latin }
        return scalar
    }

    /// The ANSI letters and digits by key code.
    private static let latinKeys: [Int: Unicode.Scalar] = {
        let pairs: [(Int, Character)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
            (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
            (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
            (kVK_ANSI_Z, "z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { code, letter in
            letter.unicodeScalars.first.map { (code, $0) }
        })
    }()

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
