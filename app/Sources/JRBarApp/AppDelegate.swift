import AppKit
import JRBarCore
import JRBarUI
import Observation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var screenBar: ScreenBarController?
    private var interaction: ScreenBarInteraction?
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
    private var wasLive = false
    private var lastFileProgram: (text: String, source: LEDFeed.Source)?
    private var lastLightsSource: String?
    private static let showScreenBarKey = "showScreenBar"
    /// The packaged build whose `agent-monitor install all` last succeeded.
    private static let hooksInstalledForKey = "bundledHooksInstalledFor"
    /// Set once the first packaged launch has registered the login item.
    private static let loginItemRegisteredKey = "loginItemRegisteredOnFirstRun"

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.showScreenBarKey: true])

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
        core.onEvent = { [weak events] event in events?.handle(event) }
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

        let shown = defaults.bool(forKey: Self.showScreenBarKey)
        statusItem.isScreenBarShown = shown
        store.screenBarShown = shown
        if shown { screenBar.show(); interaction.start() }
        feed.start()
        monitor.start()
        core.start()

        // Developer switches: `JRBAR_OPEN_PANEL=1` opens the panel shortly
        // after launch (screenshots, design passes) without a click;
        // `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on that page
        // (general, agents, usage, devices, lighting, notifications, remote,
        // advanced, or effects).
        let environment = ProcessInfo.processInfo.environment
        if let openPanel = environment["JRBAR_OPEN_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak panel] in
                MainActor.assumeIsolated { panel?.open() }
            }
            // `JRBAR_OPEN_PANEL=why` also hovers the "Why this light" row.
            if openPanel == "why" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak panel] in
                    MainActor.assumeIsolated { panel?.showWhyPopover() }
                }
            }
        }
        // `JRBAR_RENDER_ICONS=/dir` writes the status item styles as PNGs
        // (8×) for design review, then carries on.
        if let directory = environment["JRBAR_RENDER_ICONS"], !directory.isEmpty {
            StatusItemController.renderStyles(to: directory)
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
        let defaults = UserDefaults.standard
        let stamp = bundled.buildStamp
        if defaults.string(forKey: Self.hooksInstalledForKey) != stamp {
            core.appendLocalLog(level: "supervisor", "first launch of \(stamp): installing provider hooks for \(bundled.hookShim)")
            DispatchQueue.global(qos: .utility).async {
                let result = bundled.run(["agent-monitor", "install", "all"])
                Task { @MainActor [weak core] in
                    for line in result.output.split(separator: "\n") where !line.isEmpty {
                        core?.appendLocalLog(level: "hooks", String(line))
                    }
                    if result.status == 0 {
                        UserDefaults.standard.set(stamp, forKey: Self.hooksInstalledForKey)
                        core?.appendLocalLog(level: "supervisor", "provider hooks installed for \(stamp)")
                    } else {
                        core?.appendLocalLog(level: "supervisor", "provider hook install exited \(result.status); will retry next launch")
                    }
                    NSLog("JR-Bar hooks: install all exited %d", result.status)
                }
            }
        }
        if !defaults.bool(forKey: Self.loginItemRegisteredKey) {
            do {
                try SMAppService.mainApp.register()
                core.appendLocalLog(level: "supervisor", "launch at login: registered (Settings › General turns it off)")
            } catch {
                core.appendLocalLog(level: "supervisor", "launch at login: \(error.localizedDescription)")
            }
            defaults.set(true, forKey: Self.loginItemRegisteredKey)
        }
        NSLog("JR-Bar login item: %@", Self.describe(SMAppService.mainApp.status))
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
        UserDefaults.standard.set(shown, forKey: Self.showScreenBarKey)
        statusItem?.isScreenBarShown = shown
        store?.screenBarShown = shown
        if shown { screenBar?.show(); interaction?.start() } else { interaction?.stop(); screenBar?.hide() }
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
    }

    private func refreshAggregate() {
        guard let store, let statusItem else { return }
        statusItem.update(state: store.aggregate, detail: store.headerCounts)
    }

    /// `menu_bar_icon_style` plus what the ring and the label show: the
    /// primary provider's 5 h window and the aggregate counts.
    private func refreshIconStyle() {
        guard let core, let statusItem else { return }
        let document = core.settings.map { SettingsDocument($0.document) }
        statusItem.iconStyle = StatusIconStyle(setting: document?.string("menu_bar_icon_style"))
        let preferred = document?.strings("usage_graph_providers") ?? []
        let usage = core.isLive ? core.usage : []
        let primary = preferred.lazy.compactMap { id in usage.first { $0.id == id } }.first ?? usage.first
        let window = primary?.windows.first { $0.name.lowercased() == "5h" } ?? primary?.windows.first
        statusItem.ringFraction = window.map { $0.usedPct / 100 }
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

    private func refreshLights() {
        guard let core, let screenBar else { return }
        if core.isLive, let surface = core.lights?.screenBar, !surface.program.isEmpty {
            screenBar.apply(programText: surface.program, anchorEpoch: surface.anchor)
            let why = surface.why.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""
            let description = "core" + why + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "")
            if description != lastLightsSource {
                lastLightsSource = description
                statusItem?.setFeed(description: description)
            }
        } else if !core.isLive {
            applyFileProgram()
        }
    }

    /// Puts the last file-feed program back on the bar (startup, or the
    /// daemon went away).
    private func applyFileProgram() {
        guard let screenBar, let last = lastFileProgram else { return }
        screenBar.apply(programText: last.text)
        let description = last.source.description + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "")
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
