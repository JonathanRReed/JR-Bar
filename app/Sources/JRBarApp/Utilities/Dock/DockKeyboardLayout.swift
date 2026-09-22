import AppKit
import Carbon.HIToolbox

/// Keycode → the character printed on the user's key, through the
/// current keyboard layout's `uchr` table — the switcher's type-ahead
/// and ⌘-verbs read keys by what they spell, not by where they sit.
/// On Dvorak the key under the left ring finger types "o", on AZERTY
/// the top-left letter is "a"; the old US-only table spelled both
/// wrong.
///
/// The layout data is copied on the main thread (Text Input Sources are
/// main-thread API) at start and whenever the input source changes; the
/// event tap only ever reads the copy, under a lock.
final class DockKeyboardLayout: @unchecked Sendable {
    static let shared = DockKeyboardLayout()

    private let lock = NSLock()
    nonisolated(unsafe) private var layout: Data?
    private var observer: NSObjectProtocol?

    /// Re-read the current layout now and on every input-source switch.
    @MainActor
    func startWatching() {
        refresh()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    @MainActor
    func refresh() {
        let data = Self.currentLayoutData()
        lock.lock(); layout = data; lock.unlock()
    }

    /// The layout the next keystroke translates through — nil falls
    /// back to the US table.
    func set(layout data: Data?) {
        lock.lock(); layout = data; lock.unlock()
    }

    /// What `keyCode` types with `shift` (and `command`, for the verbs:
    /// "Dvorak – QWERTY ⌘" swaps to QWERTY under command, and the
    /// layout itself says so). Option is always stripped — ⌥ is the
    /// chord being held, not part of the letter. nil for keys that type
    /// nothing printable (arrows, Return, Esc).
    func character(for keyCode: Int64, shift: Bool = false, command: Bool = false) -> String? {
        lock.lock(); let data = layout; lock.unlock()
        if let data, let char = Self.translate(keyCode: UInt16(truncatingIfNeeded: keyCode),
                                               shift: shift, command: command, layout: data) {
            return char
        }
        return Self.usFallback[keyCode].map { shift ? $0.uppercased() : $0 }
    }

    // MARK: Pure

    /// One `UCKeyTranslate` through `layout` (an `uchr` blob). Dead keys
    /// are resolved to their spacing form rather than held as state — a
    /// type-ahead buffer has no composition phase.
    static func translate(keyCode: UInt16, shift: Bool, command: Bool, layout: Data) -> String? {
        var modifiers: UInt32 = 0
        if shift { modifiers |= UInt32(shiftKey >> 8) & 0xFF }
        if command { modifiers |= UInt32(cmdKey >> 8) & 0xFF }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  keyCode, UInt16(kUCKeyActionDown), modifiers,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        return isPrintable(text) ? text : nil
    }

    /// Letters, digits, punctuation, symbols and the space — never a
    /// control character or the private-use range function keys map to.
    static func isPrintable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            if scalar == " " { return true }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if (0xE000...0xF8FF).contains(scalar.value) { return false }
            return CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    /// The current keyboard layout's `uchr` data — the ASCII-capable
    /// fallback when the current source is an input method with none.
    @MainActor
    static func currentLayoutData() -> Data? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue() else { continue }
            if let data = layoutData(of: source) { return data }
        }
        return nil
    }

    /// A named installed layout's data (`com.apple.keylayout.Dvorak`) —
    /// the tests' seam, and nothing else asks for one.
    @MainActor
    static func layoutData(id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
                as? [TISInputSource], let source = list.first else { return nil }
        return layoutData(of: source)
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The US-QWERTY table the tap used before layouts were read — kept
    /// only for the moment no layout can be (an input method with no
    /// ASCII-capable fallback).
    nonisolated static let usFallback: [Int64: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
        35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
        13: "w", 7: "x", 16: "y", 6: "z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 29: "0", 49: " ",
    ]
}
