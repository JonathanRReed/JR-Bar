import AppKit
import Carbon
import JRBarCore

/// Where an `AppCommand` lands. The router holds the app's hands as
/// closures the delegate wires once — the panel, the windows, the core's
/// quiet and open verbs, the Screen Bar, the toys, the menu bar — so a
/// link, a shortcut and a Shortcuts action run the same code, and a
/// command that cannot run now is refused out loud (a toast on the
/// panel) rather than silently dropped.
@MainActor
final class AppCommandRouter {
    static let shared = AppCommandRouter()

    enum Outcome: Equatable, Sendable {
        case done
        case refused(String)
    }

    var toggles: SystemTogglesStore = .shared
    var showPanel: ((_ toggle: Bool) -> Void)?
    /// A `SettingsStore.Page` raw value, or nil for wherever it was.
    var openSettings: ((String?) -> Void)?
    var openWindow: ((AppCommand.AppWindow) -> Void)?
    /// Each answers nil when done, or the sentence saying why not.
    var quiet: ((_ mode: String?, _ seconds: Int) -> String?)?
    var endQuiet: (() -> String?)?
    var setScreenBar: ((Bool?) -> Void)?
    var fireConfetti: (() -> Void)?
    var menuBar: ((AppCommand.MenuBarVerb) -> String?)?
    var openSession: ((String) -> String?)?
    var revealAsk: (() -> String?)?
    var toggleShelf: (() -> String?)?
    /// Said where the person will see it — the delegate points it at
    /// the panel's toast.
    var onRefused: ((String) -> Void)?

    /// Run one command.
    @discardableResult
    func perform(_ command: AppCommand) -> Outcome {
        let refusal = run(command)
        if let refusal {
            onRefused?(refusal)
            return .refused(refusal)
        }
        return .done
    }

    /// A `jrbar://` link: parsed whole or refused whole.
    @discardableResult
    func open(_ url: URL) -> Outcome {
        guard let command = AppCommand.parse(url) else {
            let text = "JR-Bar has no link \(String(url.absoluteString.prefix(80)))"
            onRefused?(text)
            return .refused(text)
        }
        return perform(command)
    }

    private static let notReady = "JR-Bar is still starting."

    private func run(_ command: AppCommand) -> String? {
        switch command {
        case .panel(let toggle):
            guard let showPanel else { return Self.notReady }
            showPanel(toggle)
        case .settings(let page):
            guard let openSettings else { return Self.notReady }
            openSettings(page)
        case .window(let window):
            guard let openWindow else { return Self.notReady }
            openWindow(window)
        case .toggle(let toggle, let on):
            if let on {
                toggles.set(toggle, on: on)
            } else {
                toggles.apply(toggle)
            }
        case .keepAwake(let seconds):
            toggles.holdAwake(seconds: seconds)
        case .quiet(let mode, let seconds):
            guard let quiet else { return Self.notReady }
            return quiet(mode, seconds)
        case .endQuiet:
            guard let endQuiet else { return Self.notReady }
            return endQuiet()
        case .screenBar(let on):
            guard let setScreenBar else { return Self.notReady }
            setScreenBar(on)
        case .confetti:
            guard let fireConfetti else { return Self.notReady }
            fireConfetti()
        case .menuBar(let verb):
            guard let menuBar else { return Self.notReady }
            return menuBar(verb)
        case .openSession(let id):
            guard let openSession else { return Self.notReady }
            return openSession(id)
        case .revealAsk:
            guard let revealAsk else { return Self.notReady }
            return revealAsk()
        case .shelf:
            guard let toggleShelf else { return Self.notReady }
            return toggleShelf()
        }
        return nil
    }
}

/// One app action a key can be bound to on Settings › Shortcuts.
struct AppShortcutAction: Identifiable, Equatable, Sendable {
    /// The registry id, and the key its chord persists under.
    let id: String
    let title: String
    let command: AppCommand
}

/// The actions Settings › Shortcuts offers beyond the summon keys and
/// the menu bar's own — every chip on the strip (One Switch's "a hotkey
/// for every switch"), the quiet presets, keep-awake, the Screen Bar.
/// None has a key until the person records one — except "Show the
/// waiting ask", which adopts the key the daemon's retired registry
/// held for `reveal_current_ask`, so nothing bound before is lost.
enum AppShortcutCatalog {
    nonisolated static let revealAskID = "action.revealAsk"

    nonisolated static let actions: [AppShortcutAction] = [
        AppShortcutAction(id: revealAskID, title: "Show the waiting ask", command: .revealAsk),
        AppShortcutAction(id: "action.quietHour", title: "Quiet for an hour",
                          command: .quiet(mode: nil, seconds: 3600)),
        AppShortcutAction(id: "action.endQuiet", title: "End quiet", command: .endQuiet),
        AppShortcutAction(id: "action.awakeHour", title: "Keep awake for an hour",
                          command: .keepAwake(seconds: 3600)),
        AppShortcutAction(id: "action.screenBar", title: "Show or hide the Screen Bar",
                          command: .screenBar(on: nil)),
        AppShortcutAction(id: "action.overview", title: "Open Overview", command: .window(.overview)),
        AppShortcutAction(id: "action.confetti", title: "Fire confetti", command: .confetti),
    ]

    /// Every chip, by its registry id.
    nonisolated static func toggleID(_ toggle: SystemToggle) -> String { "toggle.\(toggle.rawValue)" }

    nonisolated static let toggleActions: [AppShortcutAction] = SystemToggle.allCases.map {
        AppShortcutAction(id: toggleID($0), title: $0.longTitle, command: .toggle($0, on: nil))
    }

    nonisolated static var all: [AppShortcutAction] { actions + toggleActions }

    nonisolated static func action(id: String) -> AppShortcutAction? {
        all.first { $0.id == id }
    }

    /// The chord the daemon's `global_action_shortcuts.reveal_current_ask`
    /// held — `{key_code, key_label, modifiers: ["control", …]}` — as a
    /// Carbon chord; nil when absent or malformed.
    nonisolated static func legacyRevealAskChord(from shortcuts: JSONValue?) -> HotkeyChord? {
        guard let entry = shortcuts?["reveal_current_ask"],
              let keyCode = entry["key_code"]?.intValue, (0...127).contains(keyCode),
              case .array(let names)? = entry["modifiers"] else { return nil }
        var modifiers: UInt32 = 0
        for name in names {
            switch name.stringValue {
            case "command": modifiers |= UInt32(cmdKey)
            case "option": modifiers |= UInt32(optionKey)
            case "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        let chord = HotkeyChord(keyCode: UInt32(keyCode), modifiers: modifiers)
        return chord.problem == nil ? chord : nil
    }
}

/// The bound app actions, registered through the one `HotkeyCenter`
/// and run through the router. Chords persist beside the panel's
/// (`HotkeyChordDefaults`), one key per action.
@MainActor
final class AppHotkeys {
    static let shared = AppHotkeys()

    var center: HotkeyCenter = .shared
    var router: AppCommandRouter = .shared
    var defaults: UserDefaults = .standard
    /// The daemon's settings have been read once for the retired
    /// registry's reveal key — adopted or not, it is never read again.
    private(set) var legacySettled = false

    /// Register every action that has a key.
    func start() {
        for action in AppShortcutCatalog.all {
            register(action)
        }
    }

    func chord(for id: String) -> HotkeyChord? {
        HotkeyChordDefaults.chord(for: id, fallback: nil, defaults: defaults)
    }

    /// The recorder's write: persist, then register (or drop) it.
    func setChord(_ chord: HotkeyChord?, for id: String) {
        guard let action = AppShortcutCatalog.action(id: id) else { return }
        HotkeyChordDefaults.set(chord, for: id, defaults: defaults)
        register(action)
    }

    private func register(_ action: AppShortcutAction) {
        guard let chord = chord(for: action.id) else {
            center.unregister(action.id)
            return
        }
        let command = action.command
        center.register(action.id, title: action.title, chord: chord) { [weak self] in
            self?.router.perform(command)
        }
    }

    /// The daemon's retired hotkey registry bound one action, "reveal the
    /// current ask". The first settings document that carries a key for
    /// it seeds "Show the waiting ask" — once, and only while the person
    /// has never set that row here.
    func adoptLegacy(shortcuts: JSONValue?) {
        guard !legacySettled else { return }
        legacySettled = true
        guard defaults.string(forKey: HotkeyChordDefaults.key(for: AppShortcutCatalog.revealAskID)) == nil,
              let chord = AppShortcutCatalog.legacyRevealAskChord(from: shortcuts),
              center.owner(of: chord, except: AppShortcutCatalog.revealAskID) == nil else { return }
        setChord(chord, for: AppShortcutCatalog.revealAskID)
    }
}
