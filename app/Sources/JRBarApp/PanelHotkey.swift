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

    /// The panel hot-key's signature, 'jrbr' — what identifies ours in
    /// the shared Carbon registry. The shelf's is 'jrbs'.
    private let signature: OSType
    private let keyCode: UInt32
    private let modifiers: UInt32
    /// Carbon ids namespaced per signature — the panel is 1, shelf 1.
    private let hotKeyID: UInt32

    var onPress: (@MainActor () -> Void)?

    /// `RegisterEventHotKey` said no — another app owns the key. The
    /// Settings toggle reads this to say so instead of pretending the
    /// key works.
    private(set) var registrationFailed = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// ⌃⌥J for the panel by default; the shelf's summon takes its own
    /// signature and key (⌃⌥D — "drop") through the same registry.
    init(signature: OSType = OSType(0x6A726272),
         keyCode: UInt32 = UInt32(kVK_ANSI_J),
         modifiers: UInt32 = UInt32(controlKey | optionKey),
         hotKeyID: UInt32 = 1) {
        self.signature = signature
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyID = hotKeyID
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), Self.handlerUPP, 1, &eventType,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            registrationFailed = true
            return
        }
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let keyStatus = RegisterEventHotKey(keyCode, modifiers, id,
                                            GetEventDispatcherTarget(), 0, &hotKey)
        if keyStatus != noErr {
            // The key is taken (or registration otherwise failed): drop the
            // handler we just installed and remember the refusal.
            unregister()
            registrationFailed = true
        }
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
        registrationFailed = false
    }

    // Unregistering is the whole point of teardown: a live Carbon handler
    // holds a dangling self pointer once the object is gone.
    isolated deinit {
        unregister()
    }

    /// Is this (signature, id) the pair we registered? Two PanelHotkeys
    /// share the dispatcher — the claim check is what keeps ⌃⌥J and ⌃⌥D
    /// from firing each other's press.
    nonisolated func owns(_ id: EventHotKeyID) -> Bool {
        id.signature == signature && id.id == hotKeyID
    }

    /// The pressed key's (signature, id) as Carbon stamped it on the
    /// event — nil when the event isn't carrying one.
    nonisolated static func hotKeyID(from event: EventRef) -> EventHotKeyID? {
        var id = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &id)
        return status == noErr ? id : nil
    }

    private static let handlerUPP: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let hotkey = Unmanaged<PanelHotkey>.fromOpaque(userData).takeUnretainedValue()
        // Carbon fans a hot-key press out to every handler on the
        // dispatcher: claim only the pair this instance registered and
        // let anything else continue down the chain — answering `noErr`
        // on a foreign event would swallow the other hotkey's press.
        guard let pressed = hotKeyID(from: event), hotkey.owns(pressed)
        else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated { hotkey.onPress?() }
        return noErr
    }
}
