import AppKit
import Carbon

/// The optional ⌃⌥J global hotkey (Settings › General, "Summon the panel
/// with ⌃⌥J"). Carbon's `RegisterEventHotKey` is the one system service
/// that delivers a key to an accessory app that owns no menu bar menus
/// and is usually not even active; there is no SwiftUI equivalent.
///
/// App-local on purpose: the key lives in UserDefaults, not the daemon's
/// settings document, because it is this app's panel it summons.
@MainActor
final class PanelHotkey {
    static let defaultsKey = "panelHotkeyEnabled"

    /// The hot-key signature, 'jrbr' — what identifies ours in the shared
    /// Carbon registry.
    private static let signature = OSType(0x6A726272)

    var onPress: (@MainActor () -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), Self.handlerUPP, 1, &eventType,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey), id,
                            GetEventDispatcherTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private static let handlerUPP: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let hotkey = Unmanaged<PanelHotkey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { hotkey.onPress?() }
        return noErr
    }
}
