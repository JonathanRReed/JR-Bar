import AppKit
import Carbon
import JRBarCore

/// `MenuBarHotkeyAction` and `MenuBarHotkeyBinding` live in
/// `JRBarCore/MenuBarActionsModel.swift` so `MenuBarSettings` can carry
/// them; the Carbon/NSEvent helpers are app-side because Core does not
/// link AppKit or HIToolbox.
extension MenuBarHotkeyBinding {
    /// NSEvent modifier flags → Carbon bits.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    /// Carbon bits → NSEvent modifier flags.
    nonisolated static func eventModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// The shortcut the way menus draw it: ⌃⌥⇧⌘ then the key name.
    nonisolated var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + MenuBarHotkeys.keyName(for: keyCode)
    }
}

/// The registration seam: everything Carbon is behind this protocol,
/// so `MenuBarHotkeys` is testable with a recorder and the real object
/// is the only file-level dependency on `RegisterEventHotKey`.
protocol MenuBarHotkeyRegistering: AnyObject {
    /// Register keyCode+modifiers under `hotKeyID`; nil means the
    /// system refused (another app owns the key).
    func register(keyCode: UInt32, modifiers: UInt32,
                  hotKeyID: UInt32) -> MenuBarHotkeyToken?
    /// Drop one registration.
    func unregister(_ token: MenuBarHotkeyToken)
    /// The dispatcher: a registered hot key fired, reported by the
    /// `hotKeyID` it was registered under. Called on Carbon's event
    /// thread — hop before touching actor state.
    var onHotKey: ((UInt32) -> Void)? { get set }
    /// The handler is installed; unregister everything and drop it.
    func uninstall()
}

/// One live registration. Opaque to `MenuBarHotkeys` — the real
/// registrar stores the `EventHotKeyRef`, a test's fake stores
/// nothing and still round-trips.
final class MenuBarHotkeyToken {
    let ref: EventHotKeyRef?
    init(_ ref: EventHotKeyRef? = nil) { self.ref = ref }
}

/// The Carbon half, `PanelHotkey`'s pattern generalized to N bindings:
/// one event handler on the dispatcher target, one `EventHotKeyID` per
/// binding (signature 'jrmb', id = binding index + 1), each
/// `RegisterEventHotKey` answered or refused by the system.
final class CarbonHotkeyRegistrar: MenuBarHotkeyRegistering {
    /// 'jrmb' — what identifies ours in the shared Carbon registry.
    let signature = OSType(0x6A726D62)

    var onHotKey: ((UInt32) -> Void)?
    private var handler: EventHandlerRef?

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), Self.handlerUPP, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(keyCode: UInt32, modifiers: UInt32,
                  hotKeyID: UInt32) -> MenuBarHotkeyToken? {
        installHandlerIfNeeded()
        guard handler != nil else { return nil }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        guard RegisterEventHotKey(keyCode, modifiers, id,
                                  GetEventDispatcherTarget(), 0, &ref) == noErr,
              let ref else { return nil }
        return MenuBarHotkeyToken(ref)
    }

    func unregister(_ token: MenuBarHotkeyToken) {
        if let ref = token.ref { UnregisterEventHotKey(ref) }
    }

    /// Every registration out and the handler gone — teardown is the
    /// whole point: a live Carbon handler holds a dangling self once
    /// the object is released.
    func uninstall() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    deinit { uninstall() }

    private static let handlerUPP: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return noErr }
        let registrar = Unmanaged<CarbonHotkeyRegistrar>
            .fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard hotKeyID.signature == registrar.signature else {
            return OSStatus(eventNotHandledErr)
        }
        registrar.onHotKey?(hotKeyID.id)
        return noErr
    }
}

/// The Menu Bar utility's global hotkeys. `MenuBarHotkeys` owns the
/// binding list and the dispatch; the registrar protocol is the seam
/// that keeps Carbon out of tests.
///
/// Wiring (the maintainer's):
///   * keep one instance on the utility, call `start()` when the
///     utility starts and `stop()` on `MenuBarUtility.stop()`;
///   * persist `bindings` wherever the settings grow a hotkey field —
///     the struct is Codable for exactly that;
///   * route `onAction` to the utility (`toggleReveal` → the chevron's
///     toggle — a true toggle, reveal or re-hide — `commandBar` →
///     `MenuBarCommandBar.toggle()`, the profile pair →
///     `MenuBarProfiles` apply with wrap-around).
@MainActor
final class MenuBarHotkeys {
    var bindings: [MenuBarHotkeyBinding]
    var onAction: @MainActor (MenuBarHotkeyAction) -> Void = { _ in }
    /// Injected for tests; the default is real Carbon.
    var registrar: any MenuBarHotkeyRegistering = CarbonHotkeyRegistrar()

    /// Actions whose registration the system refused — the settings
    /// surface can say "⌘⇧K is taken" instead of lying.
    private(set) var failedActions: Set<MenuBarHotkeyAction> = []
    private var tokens: [MenuBarHotkeyToken] = []
    private(set) var started = false

    /// The shipping set, all enabled — the maintainer can gate any of
    /// them behind settings before calling `start()`.
    nonisolated static let standard: [MenuBarHotkeyBinding] = [
        MenuBarHotkeyBinding(action: .commandBar, keyCode: UInt32(kVK_ANSI_K),
                             modifiers: UInt32(cmdKey | shiftKey), enabled: true),
        MenuBarHotkeyBinding(action: .toggleReveal, keyCode: UInt32(kVK_ANSI_B),
                             modifiers: UInt32(cmdKey | optionKey), enabled: false),
        MenuBarHotkeyBinding(action: .revealAlwaysHidden, keyCode: UInt32(kVK_ANSI_B),
                             modifiers: UInt32(cmdKey | optionKey | shiftKey), enabled: false),
        MenuBarHotkeyBinding(action: .hideAll, keyCode: UInt32(kVK_ANSI_H),
                             modifiers: UInt32(cmdKey | optionKey | shiftKey), enabled: false),
        MenuBarHotkeyBinding(action: .showAll, keyCode: UInt32(kVK_ANSI_H),
                             modifiers: UInt32(cmdKey | optionKey), enabled: false),
        MenuBarHotkeyBinding(action: .nextProfile, keyCode: UInt32(kVK_RightArrow),
                             modifiers: UInt32(cmdKey | optionKey | controlKey), enabled: false),
        MenuBarHotkeyBinding(action: .previousProfile, keyCode: UInt32(kVK_LeftArrow),
                             modifiers: UInt32(cmdKey | optionKey | controlKey), enabled: false),
    ]

    init(bindings: [MenuBarHotkeyBinding] = MenuBarHotkeys.standard) {
        self.bindings = bindings
    }

    // MARK: Pure helpers

    /// Binding pairs that would fight: two enabled bindings on the
    /// same key+modifiers. The system would refuse the second anyway —
    /// this lets the UI say so before it ever registers.
    nonisolated static func conflicts(
        in bindings: [MenuBarHotkeyBinding]
    ) -> [(MenuBarHotkeyAction, MenuBarHotkeyAction)] {
        var pairs: [(MenuBarHotkeyAction, MenuBarHotkeyAction)] = []
        let enabled = bindings.filter(\.enabled)
        for i in enabled.indices {
            for j in enabled.indices where j > i {
                if enabled[i].keyCode == enabled[j].keyCode,
                   enabled[i].modifiers == enabled[j].modifiers {
                    pairs.append((enabled[i].action, enabled[j].action))
                }
            }
        }
        return pairs
    }

    /// The glyph for a Carbon key code. Letters and digits and the
    /// common named keys; anything else falls back to its code.
    nonisolated static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    nonisolated static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    // MARK: Registration

    /// Register every enabled binding. Conflicting pairs lose both —
    /// an ambiguous key is worse than a dead one. Refusals land in
    /// `failedActions`, never thrown: a taken key must not break start.
    func start() {
        guard !started else { return }
        started = true
        let conflicted = Set(Self.conflicts(in: bindings).flatMap { [$0.0, $0.1] })
        registrar.onHotKey = { [weak self] hotKeyID in
            Task { @MainActor [weak self] in self?.fire(hotKeyID: hotKeyID) }
        }
        for (index, binding) in bindings.enumerated() {
            guard binding.enabled, !conflicted.contains(binding.action) else { continue }
            if let token = registrar.register(keyCode: binding.keyCode,
                                              modifiers: binding.modifiers,
                                              hotKeyID: UInt32(index + 1)) {
                tokens.append(token)
            } else {
                failedActions.insert(binding.action)
            }
        }
    }

    /// Everything out. Safe to call twice.
    func stop() {
        for token in tokens { registrar.unregister(token) }
        tokens = []
        registrar.onHotKey = nil
        registrar.uninstall()
        failedActions = []
        started = false
    }

    isolated deinit {
        for token in tokens { registrar.unregister(token) }
        registrar.uninstall()
    }

    /// Re-register after a bindings edit — stop/start, no half-states.
    func apply() {
        let wasStarted = started
        stop()
        if wasStarted { start() }
    }

    /// A registered key fired: hotKeyID is binding index + 1.
    private func fire(hotKeyID: UInt32) {
        let index = Int(hotKeyID) - 1
        guard bindings.indices.contains(index) else { return }
        onAction(bindings[index].action)
    }
}
