import AppKit
import Carbon
import JRBarCore

/// Where an `AppCommand` lands. The router holds the app's hands as
/// closures the delegate wires once — the panel, the windows, the core's
/// quiet and open verbs, the Screen Bar, the toys, the menu bar — so a
/// link and a shortcut run the same code, and a command that cannot run
/// now is refused out loud (a toast on the panel) rather than silently
/// dropped.
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
    /// The Overview, open or not, brought forward on its Graph pane.
    var openOverviewGraph: (() -> Void)?
    /// Accepted callbacks run before another Quiet request can enter.
    /// Each handler returns nil on success or the refusal to show.
    var quiet: ((_ mode: String?, _ seconds: Int, _ onApplied: @escaping @MainActor (Date?) -> Void) async -> String?)?
    var endQuiet: ((_ onApplied: @escaping @MainActor (Date?) -> Void) async -> String?)?
    var setScreenBar: ((Bool?) -> Void)?
    /// A burst in the colours the tint names (`AppCommand.confettiProvider`).
    var fireConfetti: ((AppCommand.ConfettiTint) -> Void)?
    var menuBar: ((AppCommand.MenuBarVerb) -> String?)?
    var openSession: ((String) -> String?)?
    var revealAsk: (() -> String?)?
    var toggleShelf: (() -> String?)?
    var useShelfKeyboard: (() -> String?)?
    /// The tank opens, or comes forward when it already is; it never
    /// closes, so a second link does what the first did.
    var openAquarium: (() -> String?)?
    /// Said where the person will see it — the delegate points it at
    /// the panel's toast.
    var onRefused: ((String) -> Void)?
    /// Deep work's hands: the live sessions (the snapshot at the start,
    /// the summary at the end) and where the closing line is said.
    var sessionsNow: (() -> [CoreSession])?
    /// The closing line: on the panel (Overview one click off) and in
    /// Notification Center, unless a test listens instead.
    lazy var onDeepWorkSummary: (String) -> Void = { [weak self] line in
        let notices = LaunchNotices.shared
        notices.say(.init(key: "deep-work", text: line, actionTitle: "Overview") { [weak self] in
            self?.openWindow?(.overview)
        })
        notices.deliverBanner("deep-work", "Deep work", line)
    }

    /// The stretch in progress: when it began, how long it was meant to
    /// run, every session's state then, and the scheduled end.
    private var deepWork: (started: Date, seconds: Int, before: [String: SessionActivity], end: DispatchWorkItem)?
    /// Tests stand in for the clock and the scheduler.
    var now: () -> Date = Date.init
    /// On the wall clock, not the uptime clock: the daemon's quiet override
    /// expires by the wall clock, and uptime stands still while the Mac
    /// sleeps, so an uptime timer would end a stretch hours late. This is
    /// the same rule as the shelf timers'.
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: work)
    }

    /// Run one command.
    @discardableResult
    func perform(_ command: AppCommand) async -> Outcome {
        let refusal = await run(command)
        if let refusal {
            onRefused?(refusal)
            return .refused(refusal)
        }
        return .done
    }

    /// What the person said to a link's question.
    enum LinkAnswer: Equatable, Sendable {
        case allow
        /// Allow, and stop asking about links of this kind.
        case allowAlways
        case cancel
    }

    /// Asks about one risky link; the delegate's default is an alert with
    /// Cancel as its default button, and tests answer for it.
    lazy var confirmLink: (_ sentence: String) -> LinkAnswer = { Self.alertAnswer($0) }
    /// Where "don't ask again" is kept, one key per kind of link.
    var linkTrust: UserDefaults = .standard
    nonisolated static let linkTrustPrefix = "linkTrust."

    private func trusted(_ key: String) -> Bool { linkTrust.bool(forKey: Self.linkTrustPrefix + key) }

    /// Forgets every "don't ask again", so risky links ask once more.
    func forgetTrustedLinks() {
        for key in linkTrust.dictionaryRepresentation().keys where key.hasPrefix(Self.linkTrustPrefix) {
            linkTrust.removeObject(forKey: key)
        }
    }

    var hasTrustedLinks: Bool {
        linkTrust.dictionaryRepresentation().keys.contains { $0.hasPrefix(Self.linkTrustPrefix) }
    }

    /// A `jrbar://` link: parsed whole or refused whole. A link comes
    /// from outside the app, so the few commands that are hard to undo
    /// ask first (`AppCommand.linkConfirmation`).
    @discardableResult
    func open(_ url: URL) async -> Outcome {
        guard let command = AppCommand.parse(url) else {
            let text = "JR-Bar has no link \(String(url.absoluteString.prefix(80)))"
            onRefused?(text)
            return .refused(text)
        }
        if let ask = command.linkConfirmation, !trusted(ask.trustKey) {
            switch confirmLink(ask.sentence) {
            case .cancel:
                let text = "Link cancelled"
                onRefused?(text)
                return .refused(text)
            case .allowAlways:
                linkTrust.set(true, forKey: Self.linkTrustPrefix + ask.trustKey)
            case .allow:
                break
            }
        }
        return await perform(command)
    }

    private static func alertAnswer(_ sentence: String) -> LinkAnswer {
        let alert = NSAlert()
        alert.messageText = "A link asks JR-Bar to \(sentence)"
        alert.informativeText = "It came from outside JR-Bar, such as a web page or another app. Only go on if you asked for it."
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let allow = alert.addButton(withTitle: "Allow")
        allow.keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for links like this"
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return .cancel }
        return alert.suppressionButton?.state == .on ? .allowAlways : .allow
    }

    private static let notReady = "JR-Bar is still starting."

    private func run(_ command: AppCommand) async -> String? {
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
        case .overviewGraph:
            guard let openOverviewGraph else { return Self.notReady }
            openOverviewGraph()
        case .aquarium:
            guard let openAquarium else { return Self.notReady }
            return openAquarium()
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
            return await quiet(mode, seconds) { [weak self] _ in self?.abandonDeepWork() }
        case .endQuiet:
            guard let endQuiet else { return Self.notReady }
            return await endQuiet { [weak self] _ in self?.finishDeepWork(early: true) }
        case .deepWork(let seconds):
            guard let quiet else { return Self.notReady }
            return await quiet("asks_only", seconds) { [weak self] until in
                self?.beginDeepWork(seconds: seconds, until: until)
            }
        case .screenBar(let on):
            guard let setScreenBar else { return Self.notReady }
            setScreenBar(on)
        case .confetti(let tint):
            guard let fireConfetti else { return Self.notReady }
            fireConfetti(tint)
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
        case .shelfKeyboard:
            guard let useShelfKeyboard else { return Self.notReady }
            return useShelfKeyboard()
        }
        return nil
    }

    // MARK: Deep work

    var isInDeepWork: Bool { deepWork != nil }

    func manualQuietApplied(seconds: Int) {
        if seconds <= 0 { finishDeepWork(early: true) }
        else { abandonDeepWork() }
    }

    private func beginDeepWork(seconds: Int, until: Date?) {
        guard let until else { return }
        let started = now()
        let remaining = max(0, until.timeIntervalSince(started))
        deepWork?.end.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishDeepWork(early: false) }
        }
        let planned = min(seconds, Int(saturating: remaining.rounded(.up)))
        deepWork = (started, planned, DeepWork.snapshot(sessionsNow?() ?? []), end)
        schedule(remaining, end)
    }

    /// The stretch's closing line — at its end, or early when quiet is
    /// ended by hand.
    private func finishDeepWork(early: Bool) {
        guard let stretch = deepWork else { return }
        stretch.end.cancel()
        deepWork = nil
        // Never longer than the stretch was meant to be: a Mac that slept
        // through the end, or a quiet ended by hand after it lapsed, still
        // reads as the planned length. An early end keeps its real time.
        let elapsed = min(Int(now().timeIntervalSince(stretch.started)), stretch.seconds)
        onDeepWorkSummary(DeepWork.summary(before: stretch.before, after: sessionsNow?() ?? [],
                                            elapsedSeconds: elapsed, early: early))
    }

    /// Another quiet took over: the stretch ends without a word.
    private func abandonDeepWork() {
        deepWork?.end.cancel()
        deepWork = nil
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
        AppShortcutAction(id: "action.shelfKeyboard", title: "Use Shelf with keyboard", command: .shelfKeyboard),
        AppShortcutAction(id: "action.quietHour", title: "Quiet for an hour",
                          command: .quiet(mode: nil, seconds: 3600)),
        AppShortcutAction(id: "action.endQuiet", title: "End quiet", command: .endQuiet),
        AppShortcutAction(id: "action.deepWork", title: "Deep work for 25 minutes",
                          command: .deepWork(seconds: DeepWork.defaultSeconds)),
        AppShortcutAction(id: "action.awakeHour", title: "Keep awake for an hour",
                          command: .keepAwake(seconds: 3600)),
        AppShortcutAction(id: "action.screenBar", title: "Show or hide the Screen Bar",
                          command: .screenBar(on: nil)),
        AppShortcutAction(id: "action.overview", title: "Open Overview", command: .window(.overview)),
        AppShortcutAction(id: "action.confetti", title: "Fire confetti", command: .confetti()),
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
            _ = Task { await self?.router.perform(command) }
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
