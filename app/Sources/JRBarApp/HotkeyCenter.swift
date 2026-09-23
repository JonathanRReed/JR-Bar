import AppKit
import Carbon
import JRBarCore
import Observation

/// One global shortcut: a Carbon key code and Carbon modifier bits, the
/// pair `RegisterEventHotKey` takes. Carbon's constants on purpose —
/// they are what the registrar speaks and what `MenuBarHotkeyBinding`
/// already persists, so a chord moves between the two unchanged.
struct HotkeyChord: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ binding: MenuBarHotkeyBinding) {
        self.init(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    /// The shortcut the way menus draw it: ⌃⌥⇧⌘ then the key.
    var displayString: String {
        MenuBarHotkeyBinding(action: .commandBar, keyCode: keyCode,
                             modifiers: modifiers, enabled: true).displayString
    }

    /// Why a chord cannot be a global shortcut. A global key is taken
    /// from every app on the Mac, so the bar is higher than a menu's:
    /// a bare key or ⇧-key would eat typing, ⌘-key alone is some app's
    /// menu command, and the system's own chords are never ours to take.
    enum Problem: Equatable, Sendable {
        /// No modifier (or only ⇧) on a key that types.
        case needsModifier
        /// ⌘ and nothing else — every app's menu shortcut space.
        case commandAlone
        /// macOS already owns it; the payload names what for.
        case reserved(String)

        var sentence: String {
            switch self {
            case .needsModifier: return "Add ⌃, ⌥ or ⌘ — a bare key would be taken from typing everywhere."
            case .commandAlone: return "Add ⌃, ⌥ or ⇧ — ⌘ alone is every app's menu shortcut."
            case .reserved(let what): return "macOS uses this for \(what)."
            }
        }
    }

    /// Carbon modifier bits the checks read.
    private static let command = UInt32(cmdKey)
    private static let option = UInt32(optionKey)
    private static let control = UInt32(controlKey)
    private static let shift = UInt32(shiftKey)

    /// F1–F20: a function key alone is a fine global shortcut — nothing
    /// types it.
    nonisolated static let functionKeys: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    /// The chords macOS keeps for itself on a default install —
    /// switching apps, Spotlight, input sources, screenshots, Force
    /// Quit, locking the screen. Registering one either fails or
    /// silently steals a system gesture; neither is a shortcut.
    nonisolated static let reserved: [HotkeyChord: String] = [
        HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: command): "switching apps",
        HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: command | shift): "switching apps",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_Grave), modifiers: command): "switching windows",
        HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: command): "Spotlight",
        HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: command | option): "Finder search",
        HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: control): "switching input sources",
        HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: control | option): "switching input sources",
        HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: control | command): "the emoji picker",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_3), modifiers: command | shift): "screenshots",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_4), modifiers: command | shift): "screenshots",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift): "screenshots",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_6), modifiers: command | shift): "screenshots",
        HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: command | option): "Force Quit",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: control | command): "locking the screen",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_F), modifiers: control | command): "full screen",
        HotkeyChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: command | shift): "logging out",
    ]

    /// The one gate every recorded chord goes through before it can be
    /// saved. nil means it may be registered — whether another app
    /// already owns it is only knowable by asking the system.
    nonisolated static func problem(keyCode: UInt32, modifiers: UInt32) -> Problem? {
        let chord = HotkeyChord(keyCode: keyCode, modifiers: modifiers)
        if let what = reserved[chord] { return .reserved(what) }
        if functionKeys.contains(keyCode) { return nil }
        let meaningful = modifiers & (command | option | control)
        if meaningful == 0 { return .needsModifier }
        if meaningful == command && modifiers & shift == 0 { return .commandAlone }
        return nil
    }

    var problem: Problem? { Self.problem(keyCode: keyCode, modifiers: modifiers) }

    /// `keyCode:modifiers` — the compact form the app-local defaults keep.
    var storageString: String { "\(keyCode):\(modifiers)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }
}

/// Every global shortcut JR-Bar holds, in one registry: the panel's
/// ⌃⌥J, the shelf's ⌃⌥D, the Menu Bar utility's ⌘⇧K family and the
/// app actions bound on Settings › Shortcuts. One Carbon handler, one
/// signature, one table from hot-key id to action — so a chord can be
/// checked against everything JR-Bar has already taken before it is
/// registered, and Settings can list them all in one place.
///
/// The registrar seam is `MenuBarHotkeyRegistering`: tests inject a
/// recorder, the app uses real Carbon. Registration never throws — a
/// chord another app owns comes back `.refused`, one this registry
/// already holds comes back `.conflict`, and the caller says so.
@MainActor
@Observable
final class HotkeyCenter {
    /// The app's registry. Tests build their own over a fake registrar.
    static let shared = HotkeyCenter()

    /// A live (or refused) registration, as Settings lists it.
    struct Entry: Equatable, Sendable {
        var id: String
        var title: String
        var chord: HotkeyChord
    }

    enum Outcome: Equatable, Sendable {
        case registered
        /// The system said no — another app owns the chord.
        case refused
        /// This registry already holds the chord for that entry.
        case conflict(Entry)
    }

    /// What is registered now, by id.
    private(set) var entries: [String: Entry] = [:]
    /// What the system refused, by id — kept so Settings can name the
    /// key that is taken instead of pretending it works.
    private(set) var refusals: [String: Entry] = [:]
    /// What lost to another JR-Bar shortcut on the same chord, by id,
    /// with the entry that holds it.
    private(set) var conflicts: [String: (entry: Entry, holder: Entry)] = [:]
    /// True while a shortcut recorder has the keyboard: every
    /// registration is out of Carbon so the chord being typed reaches
    /// the recorder instead of firing its current owner.
    private(set) var suspended = false

    @ObservationIgnored let registrar: any MenuBarHotkeyRegistering
    @ObservationIgnored private var live: [String: (token: MenuBarHotkeyToken, hotKeyID: UInt32)] = [:]
    @ObservationIgnored private var actions: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var idsByHotKeyID: [UInt32: String] = [:]
    @ObservationIgnored private var nextHotKeyID: UInt32 = 1
    @ObservationIgnored private var handlerInstalled = false

    init(registrar: any MenuBarHotkeyRegistering = CarbonHotkeyRegistrar(signature: CarbonHotkeyRegistrar.appSignature)) {
        self.registrar = registrar
    }

    /// The entry already holding `chord`, other than `id` itself.
    func owner(of chord: HotkeyChord, except id: String? = nil) -> Entry? {
        entries.values.first { $0.chord == chord && $0.id != id }
    }

    /// Register (or re-register) `id` on `chord`. An id already here is
    /// replaced — a rebind is one call. A chord another entry holds is a
    /// conflict and changes nothing: the caller decides who keeps it.
    @discardableResult
    func register(_ id: String, title: String, chord: HotkeyChord,
                  action: @escaping @MainActor () -> Void) -> Outcome {
        let entry = Entry(id: id, title: title, chord: chord)
        if let holder = owner(of: chord, except: id) {
            unregister(id)
            conflicts[id] = (entry, holder)
            return .conflict(holder)
        }
        unregister(id)
        actions[id] = action
        if suspended {
            // Parked with the rest; `resume()` makes it live.
            entries[id] = entry
            return .registered
        }
        if attach(entry) {
            entries[id] = entry
            return .registered
        }
        actions[id] = nil
        refusals[id] = entry
        uninstallIfIdle()
        return .refused
    }

    /// Drop `id` — its Carbon registration, its action, its refusal or
    /// lost conflict.
    func unregister(_ id: String) {
        detach(id)
        entries[id] = nil
        refusals[id] = nil
        conflicts[id] = nil
        actions[id] = nil
        uninstallIfIdle()
    }

    /// What Settings says about `id` right now.
    enum Status: Equatable, Sendable {
        case active(HotkeyChord)
        case refused(HotkeyChord)
        case conflict(HotkeyChord, holder: String)
        case inactive
    }

    func status(of id: String) -> Status {
        if let entry = entries[id] { return .active(entry.chord) }
        if let entry = refusals[id] { return .refused(entry.chord) }
        if let lost = conflicts[id] { return .conflict(lost.entry.chord, holder: lost.holder.title) }
        return .inactive
    }

    /// Take every registration out of Carbon while a recorder listens.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for id in Array(live.keys) { detach(id) }
    }

    /// Put them back. A chord another app grabbed meanwhile lands in
    /// `refusals` like any other refusal.
    func resume() {
        guard suspended else { return }
        suspended = false
        for entry in entries.values.sorted(by: { $0.id < $1.id }) where !attach(entry) {
            entries[entry.id] = nil
            actions[entry.id] = nil
            refusals[entry.id] = entry
        }
        uninstallIfIdle()
    }

    /// A registered key fired, by the id Carbon stamped on it.
    func fire(hotKeyID: UInt32) {
        guard let id = idsByHotKeyID[hotKeyID], let action = actions[id] else { return }
        action()
    }

    // MARK: Carbon

    private func attach(_ entry: Entry) -> Bool {
        if !handlerInstalled {
            registrar.onHotKey = { [weak self] hotKeyID in
                Task { @MainActor [weak self] in self?.fire(hotKeyID: hotKeyID) }
            }
            handlerInstalled = true
        }
        let hotKeyID = nextHotKeyID
        nextHotKeyID &+= 1
        guard let token = registrar.register(keyCode: entry.chord.keyCode,
                                             modifiers: entry.chord.modifiers,
                                             hotKeyID: hotKeyID) else { return false }
        live[entry.id] = (token, hotKeyID)
        idsByHotKeyID[hotKeyID] = entry.id
        refusals[entry.id] = nil
        return true
    }

    private func detach(_ id: String) {
        guard let registration = live.removeValue(forKey: id) else { return }
        registrar.unregister(registration.token)
        idsByHotKeyID[registration.hotKeyID] = nil
    }

    /// The handler lives while any registration does: an idle registry
    /// holds nothing on the dispatcher.
    private func uninstallIfIdle() {
        guard handlerInstalled, live.isEmpty, !suspended else { return }
        registrar.onHotKey = nil
        registrar.uninstall()
        handlerInstalled = false
    }
}

/// Where each chord is remembered: app-local defaults, one key per
/// registry id — the same home the panel's on/off switch has always
/// had. Absent means the shipped default; a stored empty string means
/// "unbound" (the recorder's Delete).
enum HotkeyChordDefaults {
    nonisolated static func key(for id: String) -> String { "hotkeyChord.\(id)" }

    /// The chord for `id`: the stored one, nil when it was cleared, the
    /// fallback when nothing was ever stored (or the value is garbage).
    nonisolated static func chord(for id: String, fallback: HotkeyChord?,
                                  defaults: UserDefaults = .standard) -> HotkeyChord? {
        guard let stored = defaults.string(forKey: key(for: id)) else { return fallback }
        if stored.isEmpty { return nil }
        return HotkeyChord(storageString: stored) ?? fallback
    }

    nonisolated static func set(_ chord: HotkeyChord?, for id: String,
                                defaults: UserDefaults = .standard) {
        defaults.set(chord?.storageString ?? "", forKey: key(for: id))
    }
}
