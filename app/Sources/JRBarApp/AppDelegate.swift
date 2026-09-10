import AppKit
import JRBarCore
import JRBarUI
import Observation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: StatusItemController?
    private var screenBar: ScreenBarController?
    private var interaction: ScreenBarInteraction?
    private var alcove: AlcoveFollower?
    private var feed: LEDFeed?
    private var monitor: AgentStateMonitor?
    private var core: CoreModel?
    private var store: PanelStore?
    private var panel: PanelController?
    private var settingsStore: SettingsStore?
    private var settingsWindow: SettingsWindowController?
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
    private var usageStore: UsageCenterStore?
    private var usageWindow: UsageCenterWindowController?
    private var effectsStore: EffectStudioStore?
    private var effectsWindow: EffectStudioWindowController?
    private var deckStore: DeckStore?
    private var controlCenterWindow: ControlCenterWindowController?
    private var rail: DeckRailController?
    private var events: EventCoordinator?
    private var supervisor: CoreSupervisor?
    private var socketWatcher: FileWatcher?
    private var updater: SparkleUpdater?
    private var checkForUpdatesItem: NSMenuItem?
    private var wasLive = false
    private var lastFileProgram: (text: String, source: LEDFeed.Source)?
    private var lastLightsSource: String?
    /// When the last `completed` event arrived: the menu bar's state dot
    /// holds green for `completionDotWindow` after it.
    private var lastCompletionAt: Date?
    private var completionReset: Timer?
    /// The app's remembered facts (hooks stamp, login item, Screen Bar) in
    /// `~/.local/state/jrbar/app-state.json`; user defaults are Sparkle's.
    private let appStateFile = AppStateFile()
    private var appState = AppState()
    /// The user-defaults keys the same facts lived under before the JSON
    /// file; read once to seed the file on a Mac where they did persist.
    private static let showScreenBarKey = "showScreenBar"
    private static let hooksInstalledForKey = "bundledHooksInstalledFor"
    private static let loginItemRegisteredKey = "loginItemRegisteredOnFirstRun"

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadAppState()

        // `JRBAR_LOGIN_ITEM=on|off|status` only touches the login item and
        // exits: scripts/install-agents.sh uses it to hand the Mac between
        // the packaged app (login item) and the dev LaunchAgents.
        if let request = ProcessInfo.processInfo.environment["JRBAR_LOGIN_ITEM"], !request.isEmpty {
            let service = SMAppService.mainApp
            do {
                switch request {
                case "on": try service.register()
                case "off": try service.unregister()
                default: break
                }
                print("login item: \(Self.describe(service.status))")
                exit(0)
            } catch {
                print("login item: \(error.localizedDescription)")
                exit(1)
            }
        }

        // `JRBAR_APPEARANCE=light|dark` pins every window to one appearance
        // (screenshots of both looks without touching the system setting).
        switch ProcessInfo.processInfo.environment["JRBAR_APPEARANCE"]?.lowercased() {
        case "light", "aqua": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark", "darkaqua": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        // `pkill JR-Bar` (or a logout) must still stop the supervised core:
        // turn SIGTERM into an orderly quit so applicationWillTerminate runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source

        let statusItem = StatusItemController()
        let screenBar = ScreenBarController()
        let feed = LEDFeed()
        let monitor = AgentStateMonitor()
        let core = CoreModel()
        let store = PanelStore(core: core)
        let panel = PanelController(store: store)
        let settingsStore = SettingsStore(core: core)
        let settingsWindow = SettingsWindowController(store: settingsStore)
        self.settingsStore = settingsStore
        self.settingsWindow = settingsWindow
        // The menu bar style is the app's own: seed the picker from
        // `app-state.json` and write every choice straight back to it.
        settingsStore.menuBarIconStyle = appState.menuBarIconStyle ?? StatusIconStyle.meters.rawValue
        settingsStore.onSetMenuBarIconStyle = { [weak self] value in
            guard let self else { return }
            self.appState.menuBarIconStyle = value
            self.persistAppState()
            self.refreshIconStyle()
        }
        // Software update: the embedded Sparkle, or a stub that says why not.
        let updater = SparkleUpdater(log: { [weak core] line in core?.appendLocalLog(level: "updater", line) })
        self.updater = updater
        settingsStore.refreshUpdater()
        NotificationCenter.default.addObserver(forName: SparkleUpdater.automaticChecksDidChange, object: nil, queue: .main) { [weak settingsStore] _ in
            MainActor.assumeIsolated { settingsStore?.refreshUpdater() }
        }
        store.onCheckForUpdates = { [weak self] in self?.checkForUpdates(nil) }
        installMainMenu()
        self.statusItem = statusItem
        self.screenBar = screenBar
        self.feed = feed
        self.monitor = monitor
        self.core = core
        self.store = store
        self.panel = panel

        // Status item ↔ panel.
        panel.setAnchorProvider { [weak statusItem] in statusItem?.anchorRect }
        panel.onOpenStateChange = { [weak statusItem] open in statusItem?.setPanelOpen(open) }
        statusItem.onTogglePanel = { [weak panel] in panel?.toggle() }
        statusItem.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onQuit = { NSApp.terminate(nil) }

        // Screen Bar hover and click: hit-tested against the band, never focus-stealing.
        let interaction = ScreenBarInteraction(
            bandRect: { [weak screenBar] in screenBar?.bandScreenRect },
            focus: { [weak store] in store?.screenBarFocus },
            onOpen: { [weak core] session in core?.openSession(session) }
        )
        self.interaction = interaction
        screenBar.onGeometryChange = { [weak interaction] in interaction?.geometryChanged() }
        // Alcove: the band follows the capsule while the setting is on and Alcove is up.
        let alcove = AlcoveFollower()
        alcove.onChange = { [weak self, weak screenBar] capsule in
            screenBar?.capsule = capsule
            self?.lastLightsSource = nil
            self?.refreshLights()
        }
        self.alcove = alcove
        store.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }
        statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }

        // History window (⌘Y).
        let historyStore = HistoryStore(core: core)
        let historyWindow = HistoryWindowController(store: historyStore)
        self.historyStore = historyStore
        self.historyWindow = historyWindow
        store.onOpenHistory = { [weak historyWindow] in historyWindow?.show() }
        statusItem.onOpenHistory = { [weak historyWindow] in historyWindow?.show() }

        // Usage Center (⌘U) and Effect Studio windows.
        let usageStore = UsageCenterStore(core: core)
        let usageWindow = UsageCenterWindowController(store: usageStore)
        self.usageStore = usageStore
        self.usageWindow = usageWindow
        store.onOpenUsageCenter = { [weak usageWindow] in usageWindow?.show() }
        statusItem.onOpenUsageCenter = { [weak usageWindow] in usageWindow?.show() }
        settingsStore.onOpenUsageCenter = { [weak usageWindow] in usageWindow?.show() }
        let effectsStore = EffectStudioStore(core: core)
        let effectsWindow = EffectStudioWindowController(store: effectsStore)
        self.effectsStore = effectsStore
        self.effectsWindow = effectsWindow
        store.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }
        statusItem.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }
        settingsStore.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }

        let deckStore = DeckStore(core: core)
        let controlCenterWindow = ControlCenterWindowController(store: deckStore)
        let rail = DeckRailController(store: deckStore)
        self.deckStore = deckStore
        self.controlCenterWindow = controlCenterWindow
        self.rail = rail
        store.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        statusItem.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        settingsStore.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        deckStore.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }

        // Events → the Mac: sounds, banners, the HUD, the amber pulse, the chime.
        let events = EventCoordinator(core: core, hudAnchor: { [weak screenBar] in screenBar?.bandScreenRect })
        self.events = events
        events.onStatusPulse = { [weak statusItem] on in statusItem?.setEscalationPulse(on) }

        // File feeds: the fallback until the daemon is connected.
        feed.onProgram = { [weak self] text, source in
            guard let self else { return }
            self.lastFileProgram = (text, source)
            self.store?.feedDescription = source.description
            if self.core?.isLive != true { self.applyFileProgram() }
        }
        monitor.onChange = { [weak self] state, detail in
            guard let self else { return }
            self.store?.fallbackState = state
            self.store?.fallbackDetail = detail
            self.refreshAggregate()
        }

        // Daemon protocol: beats the files whenever it is live.
        core.onEvent = { [weak events, weak self] event in
            events?.handle(event)
            if event.kind == "completed" { self?.noteCompletion() }
            // The daemon finished a transcript scan: the panel's sparklines
            // were drawn from a partial answer and can be redrawn now.
            if event.kind == CoreEvent.usageHistoryReadyKind { self?.store?.refreshSparklines(force: true) }
        }
        observeCore()
        watchSocketDirectory(core.socketPath)

        // Core supervision: with JRBAR_CORE_EXEC set, the daemon is our
        // child and we keep it alive. A packaged bundle carries its own
        // daemon under Contents/Helpers and supervises that. Otherwise we
        // connect to whatever listens on the socket (the dev LaunchAgents).
        if let command = ProcessInfo.processInfo.environment["JRBAR_CORE_EXEC"], !command.isEmpty {
            if let supervisor = CoreSupervisor(commandLine: command) {
                attachSupervisor(supervisor, describedAs: "`\(command)`", core: core, store: store)
            }
        } else if let bundled = CoreSupervisor.bundledCore(in: Bundle.main) {
            attachSupervisor(CoreSupervisor(bundled: bundled), describedAs: "the bundled daemon (\(bundled.buildStamp))",
                             core: core, store: store)
            completeFirstRun(with: bundled, core: core)
        }

        let shown = appState.showScreenBar
        statusItem.isScreenBarShown = shown
        store.screenBarShown = shown
        if shown { screenBar.show(); interaction.start() }
        refreshAlcoveFollowing()
        feed.start()
        monitor.start()
        core.start()

        // Developer switches: `JRBAR_OPEN_PANEL=1` opens the panel shortly
        // after launch (screenshots, design passes) without a click;
        // `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on that page
        // (general, agents, usage, devices, lighting, notifications, remote,
        // advanced, or effects); `JRBAR_SCREEN_BAR=on|off` flips the Screen
        // Bar the way the status item's toggle does (screenshots without the
        // band, and a persistence check for the remembered value).
        let environment = ProcessInfo.processInfo.environment
        switch environment["JRBAR_SCREEN_BAR"]?.lowercased() {
        case "on", "1": setScreenBar(shown: true)
        case "off", "0": setScreenBar(shown: false)
        default: break
        }
        if let openPanel = environment["JRBAR_OPEN_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak panel] in
                MainActor.assumeIsolated { panel?.open() }
            }
            // `JRBAR_OPEN_PANEL=why` also hovers the "Why this light" row;
            // `=clear` sends Clear done once the core is live, so the
            // footer's Undo offer can be photographed.
            if openPanel == "why" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak panel] in
                    MainActor.assumeIsolated { panel?.showWhyPopover() }
                }
            }
            if openPanel == "clear" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak store] in
                    MainActor.assumeIsolated { store?.clearCompleted() }
                }
            }
        }
        // `JRBAR_RENDER_ICONS=/dir` writes the status item styles as PNGs
        // (8×) for design review, then carries on.
        if let directory = environment["JRBAR_RENDER_ICONS"], !directory.isEmpty {
            // Once at launch (so a run with no daemon still produces the
            // sheet) and again once the core has answered, with the
            // reader's own providers in the columns.
            StatusItemController.renderStyles(to: directory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak statusItem] in
                MainActor.assumeIsolated {
                    guard let meters = statusItem?.meters, !meters.isEmpty else { return }
                    StatusItemController.renderStyles(to: directory, live: meters)
                    print("status icons: re-rendered with \(meters.count) live meters (\(meters.map(\.readout).joined(separator: ", ")))")
                }
            }
        }
        if environment["JRBAR_OPEN_HISTORY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak historyWindow] in
                MainActor.assumeIsolated { historyWindow?.show() }
            }
        }
        // `JRBAR_OPEN_USAGE=1` opens the Usage Center; `JRBAR_OPEN_EFFECTS=1`
        // (or an effect id) opens the Effect Studio, on that effect.
        if environment["JRBAR_OPEN_USAGE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak usageWindow] in
                MainActor.assumeIsolated { usageWindow?.show() }
            }
        }
        if let effect = environment["JRBAR_OPEN_EFFECTS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak effectsWindow] in
                MainActor.assumeIsolated { effectsWindow?.show(effect: effect == "1" ? nil : effect) }
            }
        }
        // `JRBAR_OPEN_CONTROL_CENTER=1` opens the Control Center;
        // `JRBAR_DECK_RAIL=left|right|top|bottom` asks the core to show the
        // rail on that edge once live (screenshots).
        if let mode = environment["JRBAR_OPEN_CONTROL_CENTER"] {
            // `apply`, `restore` or `clear` also opens that sheet once the
            // core is live, so the sheet's plan request has a socket (screenshots).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak controlCenterWindow, weak deckStore, weak core] in
                MainActor.assumeIsolated {
                    controlCenterWindow?.show()
                    guard ["apply", "restore", "clear"].contains(mode) else { return }
                    _ = Task { @MainActor in
                        for _ in 0..<40 where core?.isLive != true { try? await Task.sleep(for: .milliseconds(250)) }
                        switch mode {
                        case "apply": deckStore?.openApplySheet()
                        case "restore": deckStore?.openRestoreSheet()
                        default: deckStore?.openClearAbsentSheet()
                        }
                    }
                }
            }
        }
        if let edgeName = environment["JRBAR_DECK_RAIL"], let edge = DeckRailEdge(rawValue: edgeName) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak core] in
                MainActor.assumeIsolated {
                    _ = Task { _ = try? await core?.deckRail(edge: edge) }
                }
            }
        }
        if let pageName = environment["JRBAR_OPEN_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak settingsWindow, weak effectsWindow] in
                MainActor.assumeIsolated {
                    if pageName == "effects" { effectsWindow?.show(); return }
                    settingsWindow?.show(page: SettingsStore.Page(rawValue: pageName) ?? .general)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.close()
        interaction?.stop()
        screenBar?.hide()
        events?.reset()
        // The child gets SIGTERM and three seconds before SIGKILL.
        supervisor?.stop(gracePeriod: 3.0)
        core?.stop()
    }

    // MARK: Core supervision

    private func attachSupervisor(_ supervisor: CoreSupervisor, describedAs description: String,
                                  core: CoreModel, store: PanelStore) {
        self.supervisor = supervisor
        supervisor.onOutput = { [weak core] stream, line in
            Task { @MainActor [weak core] in
                core?.appendLocalLog(level: stream == "stderr" ? "core" : (stream == "supervisor" ? "supervisor" : "core"), line)
            }
            NSLog("JR-Bar core[%@]: %@", stream, line)
        }
        supervisor.onStateChange = { [weak self, weak core, weak store] state in
            Task { @MainActor [weak self, weak core, weak store] in
                store?.supervisorState = state
                if case .running = state { core?.retryNow() }
                self?.coreDidChange()
            }
        }
        store.onRestartCore = { [weak supervisor] in supervisor?.restart() }
        store.supervisorState = .idle
        core.appendLocalLog(level: "supervisor", "supervising \(description)")
        supervisor.start()
    }

    /// The first launch of a packaged build points every provider's hooks at
    /// the bundled shim (`jrbar-core agent-monitor install all`, once per
    /// build stamp) and, the very first time, registers the app as a login
    /// item. Personal app: launch at login is on by default and Settings ›
    /// General turns it off.
    private func completeFirstRun(with bundled: CoreSupervisor.BundledCore, core: CoreModel) {
        let stamp = bundled.buildStamp
        if appState.bundledHooksInstalledFor != stamp {
            core.appendLocalLog(level: "supervisor", "first launch of \(stamp): installing provider hooks for \(bundled.hookShim)")
            DispatchQueue.global(qos: .utility).async {
                let result = bundled.run(["agent-monitor", "install", "all"])
                Task { @MainActor [weak self, weak core] in
                    for line in result.output.split(separator: "\n") where !line.isEmpty {
                        core?.appendLocalLog(level: "hooks", String(line))
                    }
                    if result.status == 0 {
                        self?.appState.bundledHooksInstalledFor = stamp
                        self?.persistAppState()
                        core?.appendLocalLog(level: "supervisor", "provider hooks installed for \(stamp)")
                    } else {
                        core?.appendLocalLog(level: "supervisor", "provider hook install exited \(result.status); will retry next launch")
                    }
                    NSLog("JR-Bar hooks: install all exited %d", result.status)
                }
            }
        }
        if !appState.loginItemRegistered {
            do {
                try SMAppService.mainApp.register()
                core.appendLocalLog(level: "supervisor", "launch at login: registered (Settings › General turns it off)")
            } catch {
                core.appendLocalLog(level: "supervisor", "launch at login: \(error.localizedDescription)")
            }
            appState.loginItemRegistered = true
            persistAppState()
        }
        NSLog("JR-Bar login item: %@", Self.describe(SMAppService.mainApp.status))
    }

    // MARK: App state

    /// Reads `app-state.json`, seeding it from the user-defaults keys the
    /// facts used to live under when the file does not exist yet, and logs
    /// what came back so a relaunch can be checked from the console.
    private func loadAppState() {
        let defaults = UserDefaults.standard
        appState = appStateFile.load()
        if !appStateFile.exists {
            var seeded = false
            if let stamp = defaults.string(forKey: Self.hooksInstalledForKey) {
                appState.bundledHooksInstalledFor = stamp; seeded = true
            }
            if defaults.object(forKey: Self.showScreenBarKey) != nil {
                appState.showScreenBar = defaults.bool(forKey: Self.showScreenBarKey); seeded = true
            }
            if defaults.bool(forKey: Self.loginItemRegisteredKey) {
                appState.loginItemRegistered = true; seeded = true
            }
            if seeded { persistAppState() }
        }
        NSLog("JR-Bar app state (%@): hooksInstalledFor=%@ showScreenBar=%d loginItemRegistered=%d; defaults: %@=%@",
              appStateFile.url.path, appState.bundledHooksInstalledFor ?? "nil",
              appState.showScreenBar ? 1 : 0, appState.loginItemRegistered ? 1 : 0,
              SparkleUpdater.automaticChecksDefaultsKey,
              defaults.object(forKey: SparkleUpdater.automaticChecksDefaultsKey).map { "\($0)" } ?? "nil")
    }

    private func persistAppState() {
        do {
            try appStateFile.save(appState)
        } catch {
            core?.appendLocalLog(level: "supervisor", "app state: could not write \(appStateFile.url.path): \(error.localizedDescription)")
            NSLog("JR-Bar app state: could not write %@: %@", appStateFile.url.path, error.localizedDescription)
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval (System Settings › General › Login Items)"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// An accessory app has no menu bar of its own, but the Settings window's
    /// text fields still need the Edit menu's responder chain for ⌘C/⌘V/⌘A.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "History", action: #selector(openHistory(_:)), keyEquivalent: "y"))
        appMenu.addItem(NSMenuItem(title: "Usage Center", action: #selector(openUsageCenter(_:)), keyEquivalent: "u"))
        appMenu.addItem(NSMenuItem(title: "Effect Studio…", action: #selector(openEffects(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Control Center…", action: #selector(openControlCenter(_:)), keyEquivalent: "k"))
        appMenu.addItem(.separator())
        let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        if let updater, !updater.isAvailable { checkForUpdates.toolTip = updater.availability.description }
        checkForUpdatesItem = checkForUpdates
        appMenu.addItem(checkForUpdates)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit JR-Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow?.show()
    }

    // MARK: Software update

    /// "Check for Updates…" from the app menu, the panel or Settings ›
    /// General (`NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)`
    /// reaches this through the responder chain). Sparkle shows its own UI.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let updater, updater.isAvailable else {
            let why = "Software update: \(updater?.availability.description ?? "unavailable")"
            settingsStore?.report(error: why)
            store?.show(toast: why)
            return
        }
        updater.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            return updater?.canCheckForUpdates ?? false
        }
        return true
    }

    @objc private func openUsageCenter(_ sender: Any?) {
        usageWindow?.show()
    }

    @objc private func openControlCenter(_ sender: Any?) {
        controlCenterWindow?.show()
    }

    @objc private func openEffects(_ sender: Any?) {
        effectsWindow?.show()
    }

    @objc private func openHistory(_ sender: Any?) {
        historyWindow?.show()
    }

    // MARK: Screen Bar visibility

    private func setScreenBar(shown: Bool) {
        appState.showScreenBar = shown
        persistAppState()
        statusItem?.isScreenBarShown = shown
        store?.screenBarShown = shown
        if shown { screenBar?.show(); interaction?.start() } else { interaction?.stop(); screenBar?.hide() }
        refreshAlcoveFollowing()
    }

    // MARK: Core observation

    /// Re-arms an observation of the model's facts after every change and
    /// pushes them into the status item and the Screen Bar. Observation
    /// coalesces bursts (the daemon caps at 20 state messages a second) into
    /// one main-queue turn.
    private func observeCore() {
        guard let core else { return }
        withObservationTracking {
            _ = core.connection
            _ = core.state?.generation
            _ = core.state?.aggregate
            _ = core.lights
            _ = core.hello
            _ = core.settings?.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.coreDidChange()
                self?.observeCore()
            }
        }
    }

    private func coreDidChange() {
        guard let core, let statusItem else { return }
        switch core.connection {
        case .connected where core.state != nil:
            statusItem.setCore(description: "connected (\(core.hello?.coreVersion ?? "?"))")
        case .connected:
            statusItem.setCore(description: "connected, waiting for state")
        case .connecting(let attempt):
            statusItem.setCore(description: attempt <= 1 ? "connecting" : "reconnecting (try \(attempt))")
        case .disconnected(let reason):
            statusItem.setCore(description: "disconnected · \(reason)")
        case .idle:
            statusItem.setCore(description: "idle")
        }
        if let supervisor, let store, store.supervisorState != nil {
            switch supervisor.state {
            case .crashed(let failures): statusItem.setCore(description: "crashed \(failures)× · restart from the panel")
            case .backingOff(let failures, let delay): statusItem.setCore(description: "exited (\(failures)×), restarting in \(String(format: "%.1f", delay)) s")
            default: break
            }
        }
        let live = core.isLive
        if wasLive, !live { events?.reset() }
        wasLive = live
        refreshAggregate()
        refreshIconStyle()
        refreshLights()
        refreshAlcoveFollowing()
    }

    /// `screen_bar_follow_alcove` (default on) while the bar is shown.
    private func refreshAlcoveFollowing() {
        guard let alcove else { return }
        let document = core?.settings.map { SettingsDocument($0.document) }
        let wanted = document?.bool(SettingsPath("screen_bar_follow_alcove")) ?? true
        alcove.enabled = wanted && appState.showScreenBar
    }

    private func refreshAggregate() {
        guard let store, let statusItem else { return }
        statusItem.update(state: store.aggregate, detail: store.headerCounts)
    }

    /// `menu_bar_icon_style` plus what each style shows: the meters (one
    /// per provider shown in the panel, in that order), the ring's primary
    /// window and the label's aggregate counts.
    private func refreshIconStyle() {
        guard let core, let statusItem else { return }
        let document = core.settings.map { SettingsDocument($0.document) }
        // The style is the app's own (`app-state.json`). The daemon answers
        // a write of this key with `ok` and then keeps its value — the
        // Python settings dataclass has no field for it — so its copy is
        // frozen at the old `glyph` default and is not read here; unset
        // means the app's default, the meters.
        statusItem.iconStyle = StatusIconStyle(setting: appState.menuBarIconStyle)
        let preferred = document?.strings("usage_graph_providers") ?? []
        let usage = core.isLive ? core.usage : []
        let primary = preferred.lazy.compactMap { id in usage.first { $0.id == id } }.first ?? usage.first
        let window = primary?.windows.first { $0.name.lowercased() == "5h" } ?? primary?.windows.first
        // A window with no reading draws no ring at all: an empty ring is
        // a ring at zero, and this window was never measured.
        statusItem.ringFraction = window.flatMap { $0.usedPct }.map { $0 / 100 }
        refreshMeters(preferred: preferred, usage: usage)
        if core.isLive, let aggregate = core.state?.aggregate {
            let failed = core.sessions.filter { SessionActivity.reduce($0) == .failed }.count
            statusItem.labelText = StatusIconRenderer.label(active: aggregate.active, needsYou: aggregate.needsYou, ready: aggregate.ready, failed: failed)
        } else {
            statusItem.labelText = nil
        }
        // The state is the source of truth for the stage-2 pulse (an app
        // launched mid-escalation never saw the event).
        if core.isLive, let state = core.state {
            let ceiling = EventPolicy.escalationCeiling(document?.string("escalation_tier"))
            let stage = min(state.escalation?.stageNumber ?? 0, ceiling)
            let asksOpen = !state.asks.isEmpty || state.mainSessions.contains { $0.ask != nil }
            statusItem.setEscalationPulse(stage >= 2 && asksOpen)
        } else {
            statusItem.setEscalationPulse(false)
        }
    }

    /// The meter strip: one cell per provider the panel shows (Settings ›
    /// Usage, "Show in the panel", in that order), each metered by its
    /// primary window — the 5 h one when the provider has it, else the
    /// first it reports. Providers that report no window at all (signed
    /// out, disabled) are left out rather than drawn empty. Past
    /// `maxMeters` the rest become "+n".
    private func refreshMeters(preferred: [String], usage: [CoreProviderUsage]) {
        guard let statusItem else { return }
        let shown = Self.meteredProviders(preferred: preferred, usage: usage)
        let cap = StatusIconRenderer.maxMeters
        statusItem.meters = shown.prefix(cap).map { provider in
            let window = UsageCenterStore.primaryWindow(of: provider)
            return StatusItemController.meter(for: provider.id,
                                              fraction: window.flatMap { $0.usedPct }.map { $0 / 100 },
                                              approximate: provider.isDerived)
        }
        statusItem.meterOverflow = max(0, shown.count - cap)
        statusItem.dotState = dotState()
    }

    /// The providers the strip meters, in the panel's order: the ones
    /// named by `usage_graph_providers` first, then anything else the
    /// daemon reports, each of which must have a window to meter.
    static func meteredProviders(preferred: [String], usage: [CoreProviderUsage]) -> [CoreProviderUsage] {
        let metered = usage.filter { !$0.windows.isEmpty }
        guard !preferred.isEmpty else { return metered }
        var seen = Set<String>()
        var result: [CoreProviderUsage] = []
        for id in preferred {
            guard let provider = metered.first(where: { $0.id == id }), seen.insert(provider.id).inserted else { continue }
            result.append(provider)
        }
        return result
    }

    /// The dot at the left of the strip: an open ask beats a failure,
    /// a failure beats work, work beats a fresh completion, and a
    /// completion holds for `completionDotWindow` before the dot goes quiet
    /// again.
    ///
    /// A failure ranks BELOW an open ask deliberately: an unanswered ask is
    /// costing you time right now and one keystroke ends it, where a
    /// failure has already stopped and will wait. It ranks above work for
    /// the same reason in reverse. Before this there was no failed state at
    /// all here -- a run that crashed showed the working dot if anything
    /// else was running, and the quiet hollow dot if nothing was.
    static let completionDotWindow: TimeInterval = 6

    private func dotState() -> StatusDotState {
        guard let core, core.isLive, let state = core.state else { return .idle }
        if !state.asks.isEmpty || state.mainSessions.contains(where: { $0.ask != nil }) { return .ask }
        if core.sessions.contains(where: { SessionActivity.reduce($0) == .failed }) { return .error }
        if state.aggregate.active > 0 || core.sessions.contains(where: { SessionActivity.reduce($0) == .working }) { return .working }
        if let at = lastCompletionAt, Date().timeIntervalSince(at) < Self.completionDotWindow { return .done }
        return .idle
    }

    /// The last `completed` event, for the green dot. A timer puts the dot
    /// back to quiet when the window runs out (no state may arrive in that
    /// time to do it for us).
    private func noteCompletion() {
        lastCompletionAt = Date()
        completionReset?.invalidate()
        completionReset = Timer.scheduledTimer(withTimeInterval: Self.completionDotWindow + 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIconStyle() }
        }
        refreshIconStyle()
    }

    private func refreshLights() {
        guard let core, let screenBar else { return }
        if core.isLive, let surface = core.lights?.screenBar, !surface.program.isEmpty {
            screenBar.apply(programText: surface.program, anchorEpoch: surface.anchor)
            let why = surface.why.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""
            let description = "core" + why + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "") + lightsSuffix(screenBar)
            if description != lastLightsSource {
                lastLightsSource = description
                statusItem?.setFeed(description: description)
            }
        } else if !core.isLive {
            applyFileProgram()
        }
    }

    /// " · keyframes (40 + 40 frames) · Alcove 213 pt": how the band moves
    /// and whether it is following a capsule, for the status menu's lights line.
    private func lightsSuffix(_ screenBar: ScreenBarController) -> String {
        var suffix = " · " + screenBar.motionDescription
        if let capsule = screenBar.capsule { suffix += " · Alcove \(Int(capsule.width.rounded())) pt" }
        return suffix
    }

    /// Puts the last file-feed program back on the bar (startup, or the
    /// daemon went away).
    private func applyFileProgram() {
        guard let screenBar, let last = lastFileProgram else { return }
        screenBar.apply(programText: last.text)
        let description = last.source.description + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "") + lightsSuffix(screenBar)
        if description != lastLightsSource {
            lastLightsSource = description
            statusItem?.setFeed(description: description)
        }
    }

    // MARK: Socket directory watch

    /// The daemon may start after us: when its directory changes, retry at
    /// once instead of waiting out the backoff.
    private func watchSocketDirectory(_ socketPath: String) {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: directory) else { return }
        socketWatcher = FileWatcher(path: directory, mask: [.write, .link, .attrib]) { [weak self] _ in
            self?.core?.retryNow()
        }
        socketWatcher?.start()
    }
}
