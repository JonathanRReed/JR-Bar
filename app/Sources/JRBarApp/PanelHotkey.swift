import AppKit
import Carbon

/// One of JR-Bar's summon keys — the panel's ⌃⌥J (Settings › General,
/// "Summon the panel") and the shelf's ⌃⌥D — held in the app's one
/// `HotkeyCenter`. Carbon's `RegisterEventHotKey`, behind the center,
/// is the one system service that delivers a key to an accessory app
/// that owns no menu bar menus and is usually not even active; there is
/// no SwiftUI equivalent.
///
/// App-local on purpose: the switch and the chord live in UserDefaults,
/// not the daemon's settings document, because it is this app's panel
/// it summons. The chord is read at every registration, so a rebind on
/// Settings › Shortcuts lands with one `setEnabled(true)`.
@MainActor
final class PanelHotkey {
    static let defaultsKey = "panelHotkeyEnabled"

    /// The registry ids — also the keys their chords persist under.
    nonisolated static let panelID = "panel"
    nonisolated static let shelfID = "shelf"
    nonisolated static let panelDefault = HotkeyChord(keyCode: UInt32(kVK_ANSI_J),
                                                      modifiers: UInt32(controlKey | optionKey))
    nonisolated static let shelfDefault = HotkeyChord(keyCode: UInt32(kVK_ANSI_D),
                                                      modifiers: UInt32(controlKey | optionKey))

    let id: String
    let title: String
    let defaultChord: HotkeyChord
    var center: HotkeyCenter
    /// The chord each registration uses: the rebind persisted for `id`,
    /// the default when there is none, nil when it was cleared.
    /// Injectable so a test never reads the real defaults.
    var chordSource: @MainActor () -> HotkeyChord?

    var onPress: (@MainActor () -> Void)?

    /// The key could not be registered — another app owns it, or
    /// another JR-Bar shortcut does (`conflictOwner` names which). The
    /// Settings toggle reads this to say so instead of pretending the
    /// key works.
    private(set) var registrationFailed = false
    private(set) var conflictOwner: String?

    init(id: String, title: String, defaultChord: HotkeyChord, center: HotkeyCenter = .shared) {
        self.id = id
        self.title = title
        self.defaultChord = defaultChord
        self.center = center
        self.chordSource = { HotkeyChordDefaults.chord(for: id, fallback: defaultChord) }
    }

    /// The Carbon signature named each key before the registry did:
    /// 'jrbr' is the panel, 'jrbs' the shelf. The key code and
    /// modifiers are the default a rebind replaces.
    convenience init(signature: OSType = OSType(0x6A726272),
                     keyCode: UInt32 = UInt32(kVK_ANSI_J),
                     modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        let isShelf = signature == OSType(0x6A726273)
        self.init(id: isShelf ? Self.shelfID : Self.panelID,
                  title: isShelf ? "Open the shelf" : "Show the panel",
                  defaultChord: HotkeyChord(keyCode: keyCode, modifiers: modifiers))
    }

    /// The chord a registration would use now.
    var chord: HotkeyChord? { chordSource() }

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        registrationFailed = false
        conflictOwner = nil
        guard let chord else {
            // Cleared on Settings › Shortcuts: switched on, but no key.
            center.unregister(id)
            return
        }
        let outcome = center.register(id, title: title, chord: chord) { [weak self] in
            self?.onPress?()
        }
        switch outcome {
        case .registered:
            break
        case .refused:
            registrationFailed = true
        case .conflict(let holder):
            registrationFailed = true
            conflictOwner = holder.title
        }
    }

    func unregister() {
        center.unregister(id)
        registrationFailed = false
        conflictOwner = nil
    }

    // Unregistering is the whole point of teardown: the registry would
    // otherwise keep firing a closure whose owner is gone.
    isolated deinit {
        center.unregister(id)
    }
}
